{ pkgs, lib, self, ... }:
let
  nixosSystem = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      ({ lib, ... }: {
        # Declare dummy clan options that this helper module reads/writes
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
      })
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
        ];
      })
    ];
  };
in
pkgs.runCommand "nixos-eval-test" { } ''
  echo "Evaluating NixOS Module..."
  echo "Resolved neededFor: ${nixosSystem.config.clan.core.vars.generators.test-secret.files.key.neededFor}"
  touch $out
''
