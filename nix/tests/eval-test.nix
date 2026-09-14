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

  phase1Sys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      ({ config, ... }: {
        nixpkgs.hostPlatform = "x86_64-linux";

        my.secrets.declarations = [
          (config.my.secrets.mkUserSecret {
            name = "strict-secret";
            files.key = { };
            files.pub = { secret = false; mode = "0444"; };
            script = "echo test > $out/key; echo pub > $out/pub";
          })
          # Duplicate generator name: last declaration wins (and warns via trace).
          {
            dup = {
              share = false;
              files.a = { neededFor = "services"; };
              runtimeInputs = [ ];
              script = "echo a > $out/a";
            };
          }
          {
            dup = {
              share = false;
              files.b = { neededFor = "services"; };
              runtimeInputs = [ ];
              script = "echo b > $out/b";
            };
          }
        ];
        my.secrets.requireGenerators = [ "strict-secret" ];
      })
    ];
  };

  reqMissingSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.requireGenerators = [ "ghost-generator" ];
      }
    ];
  };

  emptyTagsSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.discover = {
          enable = true;
          dir = ./fixtures/discover;
          includeTags = [ ];
        };
      }
    ];
  };

  badDirSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.discover = {
          enable = true;
          dir = /definitely/not/here;
          includeTags = [ "tag-top" ];
        };
      }
    ];
  };

  gens = nixosSystem.config.clan.core.vars.generators;
  discoverGens = discoverSys.config.clan.core.vars.generators;
  getPath = nixosSystem.config.my.secrets.getPath;
  phase1Gens = phase1Sys.config.clan.core.vars.generators;
  strictGetPath = phase1Sys.config.my.secrets.getPathStrict;
  strictGetValue = phase1Sys.config.my.secrets.getValueStrict;
  expectPathStrict = gen: file: expected:
    let actual = strictGetPath gen file;
    in if actual == expected then actual else throw ("getPathStrict mismatch for " + gen + "/" + file + ": got " + (toString actual) + ", want " + expected);
  expectThrow = label: v:
    if (builtins.tryEval v).success
    then throw label + ": expected an evaluation failure, but it succeeded"
    else "throws as expected";

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
  echo "PH1 strict valid: ${expectPathStrict "strict-secret" "key" "/run/secrets-for-users/vars/strict-secret/key"}"
  echo "PH1 strict miss generator: ${expectThrow "getPathStrict unknown generator" (strictGetPath "no-such-gen" "key")}"
  echo "PH1 strict miss file: ${expectThrow "getPathStrict unknown file" (strictGetPath "strict-secret" "no-such-file")}"
  echo "PH1 strict value miss: ${expectThrow "getValueStrict unknown" (strictGetValue "no-such-gen" "key")}"
  echo "PH1 dup last-wins: ${if phase1Gens.dup.files ? b && !(phase1Gens.dup.files ? a) then "last-wins" else throw ("dup merge: expected only file b, files are " + lib.concatStringsSep "," (builtins.attrNames phase1Gens.dup.files))}"
  echo "PH1 requireGenerators miss: ${expectThrow "requireGenerators ghost" reqMissingSys.config.system.build.toplevel.drvPath}"
  echo "PH1 empty includeTags: ${expectThrow "discover empty includeTags" emptyTagsSys.config.system.build.toplevel.drvPath}"
  echo "PH1 missing dir: ${expectThrow "discover missing dir" badDirSys.config.system.build.toplevel.drvPath}"
  touch $out
''
