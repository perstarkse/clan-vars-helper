# secrets-parts: Vars-native secrets helpers for Clan

This repository provides a reusable Flake Parts module exposing a small helper API (`my.secrets.*`) to define Clan vars generators for shared, machine, and user secrets. It also ships a tiny helper to expose a user secret into a user-owned location at boot and emits a JSON manifest for each generator for external tooling.

## Features

- Flake Parts module export for easy reuse across repos and machines
- `my.secrets.mkSharedSecret` / `mkMachineSecret` / `mkUserSecret`
- Auto-manifest emission at `/run/secrets[-for-users]/<name>/manifest.json`
- Optional discovery from `vars/generators` by tags
- One-shot service to copy a secret into a user location (`my.secrets.exposeUserSecret`)
- Path helpers to reference deployed secret file paths directly in Nix configs

## Repository layout

```
secrets-parts/
  flake.nix
  src/
    secrets/
      manifest.nix
      lib.nix
      expose-user.nix
      module.nix
```

## Consume from another flake

```nix
{
  description = "My infra with vars-native secrets via flake-parts module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-parts.url = "github:hercules-ci/flake-parts";
    secrets-parts.url = "github:your-org/secrets-parts"; # this repo
    # Ensure secrets-parts uses your nixpkgs pin
    secrets-parts.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, secrets-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      imports = [
        secrets-parts.modules.my-secrets
      ];

      perSystem = { pkgs, system, ... }: { };

      flake.nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ({ config, ... }: {
            # Optionally import shared secrets from your repo
            imports = [ ./vars/shared-secrets.nix ];

            # Enable discovery from vars/generators by tags
            my.secrets.discover = {
              enable = true;
              dir = ./vars/generators;
              includeTags = [ "shared" ];
            };

            # Add machine-only secrets
            my.secrets.declarations = [
              (config.my.secrets.mkMachineSecret {
                name = "jwt-signing-key";
                files = {
                  private = { description = "JWT private key"; mode = "0400"; };
                  public  = { description = "JWT public key"; secret = false; mode = "0444"; };
                };
                runtimeInputs = [ pkgs.openssl ];
                script = ''
                  openssl genrsa -out "$out/private" 4096
                  openssl rsa -in "$out/private" -pubout -out "$out/public"
                '';
                meta = {
                  description = "Per-machine JWT keypair";
                  tags = [ "jwt" "crypto" ];
                  owners = [ "security@org.example" ];
                  rotateAfterDays = 180;
                };
                validation = { version = 2; };
              })
            ];

            # Optional: expose a shared user secret to alice
            my.secrets.exposeUserSecret = {
              enable = true;
              secretName = "openai-api-key";
              file = "key";
              user = "alice";
              dest = "/home/alice/.config/openai/key";
              mode = "0400";
            };

            # Example: use deployed file path in another module option
            services.my-service.settings.pass_file =
              config.my.secrets.paths."openai-api-key".key.path;
          })
        ];
      };
    };
}
```

## API

- `my.secrets.mkSharedSecret { ... }`: creates a shared generator (`share = true`), default `neededFor = "services"`.
- `my.secrets.mkMachineSecret { ... }`: creates a machine-local generator; `validation.hostname` is injected; default `neededFor = "services"`.
- `my.secrets.mkUserSecret { ... }`: creates a user-scoped generator; default `neededFor = "users"`.
- `my.secrets.declarations`: list of generator attrsets to merge into `clan.core.vars.generators`.
- `my.secrets.discover`: discover generators by tags from a directory of `*.nix` that each return a generator attrset or a list of them.
- `my.secrets.exposeUserSecret`: copy a secret file to a user-owned destination at boot.
- `my.secrets.paths`: nested attrset exposing runtime paths: `<generator>.<file>.path`.
- `my.secrets.pathsFlat`: flat attrset exposing runtime paths: `"<generator>.<file>".path`.
- `my.secrets.getPath`: function `name -> file -> path or null`.

Each constructor wraps your user `script` and appends a post-step that emits a `manifest.json` describing generated files and metadata. The manifest includes dynamic fields such as `derivation.generatedAt`, `derivation.hostname`, and absolute runtime paths.

### Example: simple shared secret

```nix
config.my.secrets.declarations = [
  (config.my.secrets.mkSharedSecret {
    name = "openai-api-key";
    files = {
      key = { description = "OpenAI API Key"; mode = "0400"; };
    };
    prompts = {
      key = {
        description = "OpenAI API Key";
        persist = true; # stores secret in password-store
        display.label = "OpenAI API Key";
        type = "hidden";
      };
    };
    script = ''
      # If you used persist=true above, the value will be in "$prompts/key"
      cp "$prompts/key" "$out/key"
    '';
    meta = { tags = [ "shared" "ai" ]; };
  })
];

# Consuming this secret path elsewhere in config
let path1 = config.my.secrets.paths."openai-api-key".key.path;
    path2 = config.my.secrets.pathsFlat."openai-api-key.key".path;
    path3 = config.my.secrets.getPath "openai-api-key" "key";
in {
  services.foo.env.SECRET_FILE = path1;
}
```

## Manifest

- Path: `/run/secrets/<name>/manifest.json` or `/run/secrets-for-users/<name>/manifest.json` if any file has `neededFor = "users"` or default for user secrets.
- Contents: name, scope, share, store settings, `derivation` info (`hostname`, `generatedAt`, `dependencies`), and `files` with final deploy paths.

## Notes

- This module only populates `clan.core.vars.generators`; it does not ship a CLI.
- For metadata-driven rotation, add a stable hash to `validation` as needed, e.g.:

```nix
validation = {
  version = 1;
  # metaHash = builtins.hashString "sha256" (builtins.toJSON meta);
};
```

## Dev shell

```
$ nix develop
$ nix fmt
```

## License

MIT
