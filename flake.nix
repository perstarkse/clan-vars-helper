{
  description = "Vars-native secrets helpers for Clan (flake-parts module)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];

      perSystem = { pkgs, system, ... }: {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.jq
            pkgs.nixpkgs-fmt
            pkgs.git
          ];
        };
      };

      flake.modules.my-secrets = { lib, ... }@args:
        let
          module = import ./src/secrets/module.nix;
        in
        {
          flake = {
            nixosModules.default = module;
            darwinModules.default = module;
            lib = {
              inherit lib;
            };
          };
        };
    };
} 