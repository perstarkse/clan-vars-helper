{ self, inputs, ... }: {
  perSystem = { config, pkgs, ... }: {
    checks = {
      formatting = config.treefmt.build.check self;
      vm-module-eval = import ../tests/eval-test.nix {
        inherit pkgs self;
        lib = inputs.nixpkgs.lib;
      };
    };
  };
}
