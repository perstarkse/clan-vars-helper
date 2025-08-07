{
  description = "Vars-native secrets helpers for Clan (flake-parts module)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { pkgs, system, ... }: {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.jq
            pkgs.nixpkgs-fmt
            pkgs.git
          ];
        };
      };

      flake = {
        nixosModules.default = import ./src/secrets/module.nix;
      };

      flake.modules.my-secrets = { lib, ... }@args:
        let
          module = import ./src/secrets/module.nix;
        in
        {
          flake = {
            nixosModules.default = module;
          };
        };
    };
} 