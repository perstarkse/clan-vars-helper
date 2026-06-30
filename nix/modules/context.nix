{ inputs, ... }: {
  systems = [ "x86_64-linux" "aarch64-linux" ];

  perSystem = { system, ... }: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      config = { };
      overlays = [
        (_: prev: {
          # Ensure cspell is exposed at the top level for git-hooks.nix
          cspell = prev.cspell or prev.nodePackages.cspell or null;
        })
      ];
    };
  };
}
