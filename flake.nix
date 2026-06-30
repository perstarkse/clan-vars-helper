{
  description = "Vars-native secrets helpers for Clan (flake-parts module)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    git-hooks-nix.url = "github:cachix/git-hooks.nix";
    git-hooks-nix.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks-nix.flakeModule
        inputs.treefmt-nix.flakeModule
        ./nix/modules/context.nix
        ./nix/modules/packages.nix
        ./nix/modules/checks.nix
        ./nix/modules/formatter.nix
        ./nix/modules/dev-shell.nix
      ];

      flake = {
        nixosModules = {
          default = import ./nix/nixos/module.nix;
        };
        homeModules = {
          default = import ./nix/home/module.nix;
        };
      };
    };
}
