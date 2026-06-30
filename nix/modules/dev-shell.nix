{
  perSystem = { config, pkgs, ... }: {
    pre-commit = {
      settings.hooks = {
        treefmt.enable = true;
        deadnix.enable = true;
        statix.enable = true;
      };
    };

    devShells.default = pkgs.mkShell {
      shellHook = config.pre-commit.devShell.shellHook or "";
      packages = [
        pkgs.jq
        pkgs.git
        config.treefmt.build.wrapper
      ];
    };
  };
}
