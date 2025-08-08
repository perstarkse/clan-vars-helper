# secrets-parts: Vars-native secrets helpers for Clan

This repository provides a reusable Flake Parts module exposing a small helper API (`my.secrets.*`) to define Clan vars generators for shared, machine, and user secrets. It also ships a tiny helper to expose a user secret into a user-owned location at boot and emits a JSON manifest for each generator for external tooling.

## Features

- Flake Parts/NixOS module export for easy reuse across repos and machines
- `my.secrets.mkSharedSecret` / `mkMachineSecret` / `mkUserSecret`
- Auto-manifest emission at `/run/secrets[-for-users]/<name>/manifest.json`
- Optional discovery from `vars/generators` by tags
- One-shot service to copy a secret into a user location (`my.secrets.exposeUserSecret`)
- Path helpers to reference deployed secret file paths directly in Nix configs
- Per-file prompt type with multiline support: `hidden` (default) or `multiline-hidden`
- Value helpers for non-secrets: `my.secrets.values`, `valuesFlat`, `getValue` (mirrors `clan.core.vars.generators.<gen>.files.<file>.value`)

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

# This repo
secrets-helper.url = "github:perstarkse/clan-vars-secrets-helper";
secrets-helper.inputs.nixpkgs.follows = "nixpkgs";
secrets-helper.inputs.flake-parts.follows = "flake-parts";
};

outputs = inputs@{ self, nixpkgs, flake-parts, secrets-helper, ... }:
flake-parts.lib.mkFlake { inherit inputs; } {
systems = [ "x86_64-linux" "aarch64-linux" ];

imports = [
# If you use flake-parts in your top-level; not required for NixOS-only usage
];

perSystem = { pkgs, system, ... }: { };

flake.nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
system = "x86_64-linux";
modules = [
# Import the module explicitly by name
secrets-helper.nixosModules.secrets-helper

({ config, pkgs, ... }: {
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

### Constructors

- `my.secrets.mkSharedSecret { ... }` → shared generator (`share = true`), default `neededFor = "services"`.
- `my.secrets.mkMachineSecret { ... }` → machine-local generator; `validation.hostname` is injected; default `neededFor = "services"`.
- `my.secrets.mkUserSecret { ... }` → user-scoped generator; default `neededFor = "users"`.

Common arguments for all three constructors:

- `name` (str, required): generator name.
- `files` (attrs of fileName → fileSpec, required): generated files.
- fileSpec fields:
- `deploy` (bool, default true): include in deployment store.
- `secret` (bool, default true): mark as secret in manifest.
- `owner` (str, default "root"): file owner on target.
- `group` (str, default "root"): file group on target.
- `mode` (str, default "0400"): octal mode.
- `neededFor` ("services" | "users", defaults to constructor’s default): affects runtime path prefix.
- `description` (str | null, default null): human-friendly description.
- `promptType` ("hidden" | "multiline-hidden", default "hidden"): input prompt type for Clan; enables multiline secrets.
- `prompts` (attrs, default auto-generated): per-file prompt overrides. Auto-generated as:
- `prompts.<file>.input = { description = "${name} (${file})"; type = <promptType>; persist = false; }`.
- Provide your own `prompts` to override any subset.
- `script` (bash string, required): writes outputs into `$out/<file>`.
- `runtimeInputs` (list of pkgs, default `[]` + `jq`): added to PATH for `script`.
- `dependencies` (list of derivations, default `[]`): extra build-time deps.
- `validation` (attrs, default `{}`): embedded into manifest; `mkMachineSecret` augments with `hostname`.
- `meta` (attrs, default `{}`): free-form metadata; included in manifest.
- `defaultNeededFor` ("services" | "users", optional): overrides constructor default for files that omit `neededFor`.

The constructor returns an attrset keyed by `name` suitable for inclusion in `my.secrets.declarations`.

### Module options

- `my.secrets.declarations` (list of attrs, default `[]`):
Merge these into `clan.core.vars.generators`.
- `my.secrets.discover` (submodule):
- `enable` (bool, default false)
- `dir` (path, default `./vars/generators`)
- `includeTags` (list of str, default `[]`)
- `excludeTags` (list of str, default `[]`)
- `my.secrets.paths` (read-only attrset): nested paths `<generator>.<file>.path` to deployed files.
- `my.secrets.pathsFlat` (read-only attrset): flat paths `"<generator>.<file>".path`.
- `my.secrets.getPath` (read-only function): `name -> file -> path or null`.
- `my.secrets.values` (read-only attrset): nested values `<generator>.<file>.value` (string or null; only for non-secret files).
- `my.secrets.valuesFlat` (read-only attrset): flat values `"<generator>.<file>".value` (string or null; only for non-secret files).
- `my.secrets.getValue` (read-only function): `name -> file -> value (string) or null` (only for non-secret files).

### Example: multiline secret prompt

```nix
config.my.secrets.declarations = [
(config.my.secrets.mkMachineSecret {
name = "surrealdb-credentials";
files = {
user = { };
password = { promptType = "multiline-hidden"; };
};
script = ''
      echo -n "p" > "$out/user"
      cat > "$out/password" <<'EOF'
very
secret
multi
line
EOF
    '';
})
];
```

### Non-secret values (.value)

For files declared with `secret = false`, Clan exposes the file content as a string value at:

- `config.clan.core.vars.generators.<name>.files.<file>.value`

This is the canonical location per Clan docs (see: `clan.core.vars.generators.files.<name>.value`). Refer to the documentation: [clan.core.vars.generators.files.value](https://docs.clan.lol/reference/clan.core/vars/#clan.core.vars.generators.files.value).

This module also provides convenience accessors that mirror that value (optional sugar):

- `config.my.secrets.values.<name>.<file>.value`
- `config.my.secrets.valuesFlat."<name>.<file>".value`
- `config.my.secrets.getValue "<name>" "<file>"`

Example:

```nix
# Define a non-secret value and read it
my.secrets.declarations = [
(config.my.secrets.mkSharedSecret {
name = "example";
files.public = { secret = false; mode = "0444"; };
script = ''
      echo -n "hello" > "$out/public"
    '';
})
];

# Canonical per Clan
let v = config.clan.core.vars.generators.example.files.public.value; in v

# Convenience helpers (equivalent)
config.my.secrets.getValue "example" "public"
config.my.secrets.values.example.public.value
config.my.secrets.valuesFlat."example.public".value
```

## Manifest

- Path: `/run/secrets/<name>/manifest.json` or `/run/secrets-for-users/<name>/manifest.json` if any file has `neededFor = "users"` (or via user-secret constructors).
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
