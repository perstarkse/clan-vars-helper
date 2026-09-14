{ pkgs, lib, self, ... }:
let
  # Declare dummy clan options that this helper module reads/writes
  clanStub = { lib, ... }: {
    options.clan.core.vars = {
      generators = lib.mkOption {
        type = lib.types.attrsOf lib.types.attrs;
        default = { };
      };
      settings = {
        secretStore = lib.mkOption {
          type = lib.types.str;
          default = "sops";
        };
        publicStore = lib.mkOption {
          type = lib.types.str;
          default = "git";
        };
      };
    };
  };

  nixosSystem = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      ({ config, ... }: {
        nixpkgs.hostPlatform = "x86_64-linux";

        # Configure the mock settings
        clan.core.vars.settings.secretStore = "sops";
        clan.core.vars.settings.publicStore = "git";

        # Test options and constructors
        my.secrets.declarations = [
          (config.my.secrets.mkUserSecret {
            name = "test-secret";
            files.key = { };
            script = "echo test > $out/key";
          })
          (config.my.secrets.mkMachineSecret {
            name = "test-svc";
            files.svc = { };
            script = "echo test > $out/svc";
          })
        ];
      })
    ];
  };

  discoverSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";

        my.secrets.discover = {
          enable = true;
          dir = ./fixtures/discover;
          includeTags = [ "tag-top" "tag-inner" "tag-both-inner" ];
        };
      }
    ];
  };

  gens = nixosSystem.config.clan.core.vars.generators;
  discoverGens = discoverSys.config.clan.core.vars.generators;
  getPath = nixosSystem.config.my.secrets.getPath;

  expectPath = gen: file: expected:
    let actual = getPath gen file;
    in if actual == expected then actual else throw "getPath ${gen}/${file}: got ${toString actual}, want ${expected}";
  expectPresent = set: name:
    if set ? ${name} then "present" else throw "${name} missing from clan.core.vars.generators";
  expectAbsent = set: name:
    if set ? ${name} then throw "${name} should not be in clan.core.vars.generators" else "absent";
in
pkgs.runCommand "nixos-eval-test" { } ''
  echo "Evaluating NixOS Module..."
  echo "Resolved neededFor: ${gens.test-secret.files.key.neededFor}"
  # runtimePath pins (shared runtime-path.nix): users vs services scopes
  echo "users path: ${expectPath "test-secret" "key" "/run/secrets-for-users/vars/test-secret/key"}"
  echo "services path: ${expectPath "test-svc" "svc" "/run/secrets/vars/test-svc/svc"}"
  # discovery tag union: top-level-only, inner-only, both (union), untagged
  echo "gen-top: ${expectPresent discoverGens "gen-top"}"
  echo "gen-inner: ${expectPresent discoverGens "gen-inner"}"
  echo "gen-both: ${expectPresent discoverGens "gen-both"}"
  echo "gen-untagged: ${expectAbsent discoverGens "gen-untagged"}"
  # stripMeta: no meta leaks into clan.core.vars.generators
  echo "meta stripped (gen-top): ${expectAbsent discoverGens.gen-top "meta"}"
  echo "meta stripped (gen-inner): ${expectAbsent discoverGens.gen-inner "meta"}"
  touch $out
''
