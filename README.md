# secrets-parts: Vars-native secrets helpers for Clan

This repository provides a reusable Flake Parts/NixOS module exposing a small helper API (`my.secrets.*`) to define Clan vars generators for shared, machine, and user secrets. It also ships:

- A tiny helper to expose a deployed user secret into a user-owned location at boot
- A JSON manifest emitted for each generator for external tooling
- Optional ACL automation to grant users read access to root-owned secret files without duplication

### What you get

- **Module export**: drop-in `nixosModules.default` for easy reuse
- **Constructors**: `my.secrets.mkSharedSecret`, `mkMachineSecret`, `mkUserSecret`
- **Auto manifest**: `/run/secrets[-for-users]/vars/<name>/manifest.json`
- **Optional discovery**: import raw declarations from `vars/generators` by tags
- **Expose to users**: `my.secrets.exposeUserSecrets` (preferred) or `exposeUserSecret`
- **Path helpers**: reference deployed secret file paths directly from Nix
- **Prompt types**: per-file `promptType = "hidden" | "multiline-hidden"`
- **Non-secret values**: convenient accessors for files with `secret = false`
- **ACL helpers**: per-file `additionalReaders` or manual `allowReadAccess`
- **Rotation watchers**: `my.secrets.mkRestartOnRotation` / `mkTryRestartOnRotation` codify the two proven rotation shapes (restart vs try-restart)

---

## Quick start

Add this flake as an input and import the module on your host. Then define a simple secret using a constructor.

```nix
{
  inputs.secrets-helper.url = "github:perstarkse/clan-vars-secrets-helper";
  inputs.secrets-helper.inputs.nixpkgs.follows = "nixpkgs";
  inputs.secrets-helper.inputs.flake-parts.follows = "flake-parts";

  outputs = inputs@{ self, nixpkgs, secrets-helper, ... }:
    {
      nixosConfigurations.host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          secrets-helper.nixosModules.default

          ({ config, pkgs, ... }: {
            my.secrets.declarations = [
              (config.my.secrets.mkUserSecret {
                name = "openai-api-key";
                files.key = { mode = "0400"; neededFor = "users"; };
                prompts.key = {
                  description = "OpenAI API key";
                  type = "hidden";
                  persist = true;
                };
                script = ''
                  cp "$prompts/key" "$out/key"
                '';
              })
            ];

            # Example: wire the runtime file path into another module.
            # getPath returns null on miss (typo, undiscovered generator),
            # which fails late downstream — prefer getPathStrict for
            # environmentFile/allowReadAccess so misses fail at eval.
            services.my-service.settings.pass_file =
              config.my.secrets.getPathStrict "openai-api-key" "key";
          })
        ];
      };
    };
}
```

---

## Usage patterns

Choose the style that fits your workflow. You can mix them.

- **Inline with constructors (consuming module)**

  Define secrets where they are used with `mkUserSecret`/`mkMachineSecret`/`mkSharedSecret`.

  ```nix
  my.secrets.declarations = [
    (config.my.secrets.mkUserSecret {
      name = "surrealdb-credentials";
      files.credentials = { mode = "0400"; neededFor = "users"; };
      prompts.credentials = {
        description = "Content of the SurrealDB credentials environment file";
        type = "hidden";
        persist = true;
      };
      script = ''
        cp "$prompts/credentials" "$out/credentials"
      '';
      meta = { tags = [ "service" "surrealdb" ]; };
    })
  ];
  ```

  - Pros: simplest wiring; sane defaults; auto manifest and prompt shaping
  - Tags in `meta.tags`: metadata only (do not affect inclusion)

- **Aggregated module (e.g., `nixosModules.apiKeys`)**

  Group related secrets via constructors and import that module where needed.

  - Pros: clear ownership, reuse across machines, per-secret `runtimeInputs`
  - Tags: metadata only unless you add selection logic yourself

- **Discovery by tags (raw declarations)**

  Place raw generator attrsets in a folder (default `vars/generators`) and enable discovery:

  ```nix
  my.secrets.discover = {
    enable = true;
    dir = ./vars/generators;
    includeTags = [ "service" "surrealdb" ];
  };
  ```

  Example `vars/generators/surrealdb.nix`:

  ```nix
  {
    meta = { tags = [ "oumuamua" "service" "surrealdb" ]; };

    "surrealdb-credentials" = {
      files.credentials = { mode = "0400"; neededFor = "users"; };
      prompts.credentials = {
        description = "Content of the SurrealDB credentials environment file";
        type = "hidden";
        persist = true;
      };
      script = ''
        cp "$prompts/credentials" "$out/credentials"
      '';
    };
  }
  ```

  Notes:

  - Tags in `meta.tags` may be at the top level or inside a generator; both are recognized for filtering
  - Discovery strips `meta` before merging into `clan.core.vars.generators` to match Clan’s schema
  - Raw declarations use your exact `script` and do not get constructor wrapping (no automatic manifest/prompt defaults) unless you implement it

---

## Architecture and runtime model

- **Constructors wrap raw declarations**: inject defaults, generate prompts, add `jq` to `PATH`, and append a read-only machine-readable manifest file to each generator’s files.
- **Runtime layout**: deployed files live under `/run/secrets/vars/<name>/<file>` for `services` and `/run/secrets-for-users/vars/<name>/<file>` for `users`.
- **Manifests**: a JSON file `/run/secrets[-for-users]/vars/<name>/manifest.json` is written by the wrapped script after your `script` runs. Paths in the manifest include the `vars` segment to reflect runtime layout.
- **Values**: files declared with `secret = false` expose their contents as strings under Clan’s canonical location, mirrored by helper accessors.
- **ACLs**: per-file user read access can be granted without duplication via `additionalReaders` or manual `allowReadAccess` items; implemented with systemd triggers and `setfacl`.
- **Expose-to-user**: optional systemd units copy a user-scoped secret file into a user-owned destination.

---

## Full API reference

### Constructors

- `my.secrets.mkSharedSecret { ... }`
  - Scope: shared (`share = true`)
  - Default `defaultNeededFor = "services"`
- `my.secrets.mkMachineSecret { ... }`
  - Scope: machine (`share = false`)
  - Injects `validation.hostname = config.networking.hostName`
  - Default `defaultNeededFor = "services"`
- `my.secrets.mkUserSecret { ... }`
  - Scope: user
  - Default `defaultNeededFor = "users"`

Common arguments for all three constructors:

- **name** (string, required): generator name
- **files** (attrs: fileName → fileSpec, required)
  - `deploy` (bool, default true): include in deployment store
  - `secret` (bool, default true): mark as secret in manifest
  - `owner` (string, default "root")
  - `group` (string, default "root")
  - `mode` (string, default "0400")
  - `neededFor` ("services" | "users", default from constructor)
  - `description` (string | null, default null)
  - `promptType` ("hidden" | "multiline-hidden", default "hidden")
  - `additionalReaders` (list of strings, default `[]`): grant user read ACLs to the deployed file
- **prompts** (attrs, default auto-generated)
  - Clan-core flat format: `prompts.<file> = { description, type, persist }` (no `input` wrapper)
  - Auto: `prompts.<file> = { description = "${name} (${file})"; type = promptType; persist = false; }`
  - Provide a subset to override (deep-merged per file: overriding one key inherits the auto `type`/`persist`)
- **requiredPrompts** (list of strings, default `[]`): fail the generator loudly (`exit 1`) when any `$prompts/<file>` is missing or empty — use instead of silent prompt-less fallbacks (never ship shared-constant fallback secrets)
- **script** (bash string, required): writes outputs into `$out/<file>`
- **runtimeInputs** (list of pkgs, default `[ ]` plus `jq`)
- **dependencies** (list of derivations, default `[ ]`)
- **validation** (attrs, default `{ }`)
- **meta** (attrs, default `{ }`)
- **defaultNeededFor** ("services" | "users"): overrides constructor default across files that omit `neededFor`

Returns: an attrset keyed by `name`, suitable for inclusion in `my.secrets.declarations`.

Behavior injected by constructors:

- Adds a read-only file `manifest.json` to the generator outputs with `secret = false`, `mode = "0400"`
- Wraps your `script` to emit `manifest.json` containing derivation metadata and resolved runtime paths
- Adds `jq` to `PATH` for manifest processing
- Captures per-file `additionalReaders` into internal metadata for the ACL subsystem (reserved `validation._acl_additionalReaders` key — never set it yourself)

### Module options

- **`my.secrets.declarations`** (list of attrs, default `[]`)
  - Merge these into `clan.core.vars.generators`
- **`my.secrets.discover`** (submodule)
  - `enable` (bool, default false)
  - `dir` (path, default `./../../vars/generators` relative to this module)
  - `includeTags` (list of strings, default `[]`; required non-empty when `enable` is true — empty would silently include everything)
  - `excludeTags` (list of strings, default `[]`)
- **`my.secrets.requireGenerators`** (list of strings, default `[]`)
  - Generator names that must exist in `clan.core.vars.generators` after merge; missing entries fail evaluation (fail closed on undiscovered generators)
- **`my.secrets.exposeUserSecret`** (single entry; legacy)
  - Deprecated in favor of `exposeUserSecrets`
- **`my.secrets.exposeUserSecrets`** (list of submodules)
  - `enable` (bool, default false)
  - `secretName` (string)
  - `file` (string)
  - `user` (string)
  - `dest` (string, default: `/var/lib/user-secrets/<user>/<secret>/<file>`)
  - `mode` (string, default `0400`)
  - `group` (string, default primary group of the user)
- **Paths helpers (read-only)**
  - `my.secrets.paths.<gen>.<file>.path`
  - `my.secrets.pathsFlat."<gen>.<file>".path`
  - `my.secrets.getPath "<gen>" "<file>" -> path | null` (null on miss — prefer `getPathStrict`, which throws at eval with available-names hint)
  - `my.secrets.mkRestartOnRotation { service, secretName, file }` / `my.secrets.mkTryRestartOnRotation { ... }` (read-only fns returning `{ paths, services }` fragments to merge into your module config)
- **Value helpers (read-only; only for `secret = false`)**
  - `my.secrets.values.<gen>.<file>.value`
  - `my.secrets.valuesFlat."<gen>.<file>".value`
  - `my.secrets.getValue "<gen>" "<file>" -> string | null` (null on miss — `getValueStrict` throws at eval instead)
- **ACLs**
  - `my.secrets.allowReadAccess = [ { path = "/abs/path"; readers = [ "alice" "svc" ]; } ... ]`
  - `my.secrets.revokeStaleAcls` (bool, default false): also emit `setfacl -x` revoker units for empty-`readers` entries. Opt in per machine only after auditing that all readers live in this config — a revoker for a generator whose readers are declared elsewhere would strip live ACLs.

---

## ACL read access (no duplication)

Grant per-user read access to root-owned deployed files without duplicating secrets or managing groups.

- **Per-file (preferred with constructors)**

  ```nix
  my.secrets.declarations = [
    (config.my.secrets.mkSharedSecret {
      name = "api-key-aws-access";
      files.aws_access_key_id = {
        mode = "0400";
        neededFor = "users"; # deploys under /run/secrets-for-users/vars/...
        additionalReaders = [ "alice" ]; # grant read ACL to these users
      };
      prompts.aws_access_key_id = {
        description = "AWS access key ID";
        persist = true;
        type = "hidden";
      };
      script = ''
        cp "$prompts/aws_access_key_id" "$out/aws_access_key_id"
      '';
      meta.tags = [ "aws" "api-key" "dev" "shell" ];
    })
  ];
  ```

  This generates systemd path/service units that apply `setfacl u:<user>:r` to the deployed file whenever it appears or changes.

- **Manual (arbitrary files)**

  ```nix
  my.secrets.allowReadAccess = [
    { path = config.my.secrets.getPathStrict "api-key-openrouter" "api_key"; readers = [ "alice" ]; } # strict: unknown secrets fail at eval, not as silently dropped ACLs
  ];
  ```

- **Triggers and behavior**

  - Trigger on content modifications and on parent directory changes, not on "exists" at boot (avoids start-limit loops)
  - Reapply ACL unconditionally; idempotent
  - Path units coalesce storms (`TriggerLimitIntervalSec = 30s`, `TriggerLimitBurst = 10`, systemd ≥249); point manual `allowReadAccess` targets at per-service files, not busy shared dirs

- **Important note about sops-nix and tmpfs**

  - When any ACL target is under `/run/secrets-for-users`, this module enables `sops.useTmpfs = true` by default (if `sops-nix` is present), switching its storage to tmpfs so ACLs work
  - tmpfs can swap to disk; review swap configuration and consider enabling swap encryption

- **Requirements**
  - Filesystem ACL support (typically enabled on ext4/xfs)
  - `pkgs.acl` is pulled into the system when ACLs are requested

---

## Expose user secrets (copy into user-owned locations)

Copy a user-scoped deployed secret file from `/run/secrets-for-users/vars/<name>/<file>` into a user-owned destination on change.

- **Multiple entries (preferred)**

  ```nix
  my.secrets.exposeUserSecrets = [
    {
      enable = true;
      secretName = "surrealdb-credentials";
      file = "credentials";
      user = "surrealdb";
      dest = "/var/lib/surrealdb/credentials.env";
      mode = "0400";
    }
    {
      enable = true;
      secretName = "user-ssh-key";
      file = "key";
      user = "alice";
      dest = "/home/${config.my.mainUser.name}/.ssh/id_ed25519";
      mode = "0400";
    }
  ];
  ```

- **Notes**
  - Triggers on file content modifications and on the source directory change
  - Only updates destination if content changed
  - Ensures destination directory exists with secure ownership and permissions
  - Destinations are confined to `/home/` and `/var/lib/` (eval error otherwise); `mode` must be one of `0400`, `0440`, `0600`. Absent source fails loud (`exit 1` → `Restart=on-failure` retries until clan deploys); start limits match the ACL units (`300s`/`60`).

---

## Paths and values helpers

- Use in other module options without hardcoding paths:
  - `config.my.secrets.paths."<gen>"."<file>".path`
  - `config.my.secrets.getPath "<gen>" "<file>"` (null on miss) or `config.my.secrets.getPathStrict "<gen>" "<file>"` (throws on miss — use for `environmentFile`/`allowReadAccess`)
- To read non-secret values (`secret = false`) as strings:
  - `config.clan.core.vars.generators.<gen>.files.<file>.value` (canonical per Clan)
  - `config.my.secrets.values.<gen>.<file>.value` (convenience)

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

# Convenience helpers (equivalent)
config.my.secrets.getValue "example" "public"
config.my.secrets.values.example.public.value
config.my.secrets.valuesFlat."example.public".value
```

### Rotation: restart vs try-restart

Clan deploys secrets; systemd owns service lifecycle. `restartTriggers` on
`/run/secrets` paths are inert strings that never fire — watch the deployed
file with a path unit and (try-)restart the service instead. Two shapes cover
production (no third mechanism):

- **restart** (e.g. vaultwarden): the service must always run with fresh
  secrets; a rotated file restarts it even if it was stopped.
- **try-restart** (e.g. wireguard tunnels): rotated files re-apply to active
  units; manually-down units stay down and read fresh files on next start
  (handy when units are per-tunnel and some are intentionally off).

```nix
systemd.paths = (config.my.secrets.mkRestartOnRotation {
  service = "vaultwarden";
  secretName = "vaultwarden";
  file = "env";
}).paths;
systemd.services = (config.my.secrets.mkRestartOnRotation {
  service = "vaultwarden";
  secretName = "vaultwarden";
  file = "env";
}).services;
```

### Rotation/offboarding runbook

- **Rotate a secret**: update the generator (or re-run prompts), deploy;
  the rotation watcher (or expose-user/ACL path unit) picks up the new file
  and restarts/copies. Verify the deployed file under
  `/run/secrets[-for-users]/vars/<name>/` changed.
- **Offboard a reader**: remove the name from `additionalReaders` /
  `allowReadAccess`. With `revokeStaleAcls = true` an empty-`readers` entry
  emits a `setfacl -x` revoker; otherwise remove the ACL manually with
  `setfacl -x <path>` on each host that granted it.
- **Remove an exposed copy**: delete the `exposeUserSecrets` entry, deploy,
  then delete the `dest` file on the host (no automatic cleanup — copies are
  never removed by the helper).
- **Shared (`share = true`) generators** are fleet-valid credentials: one
  host's store compromise affects all consumers. Rotate on every machine
  that discovers the generator, not just the one you touched.

---

## Manifest

- Path: `/run/secrets/vars/<name>/manifest.json` or `/run/secrets-for-users/vars/<name>/manifest.json` when any file has `neededFor = "users"`
- Contents: name, scope, share, store settings, `derivation` info (`hostname`, `generatedAt`, `dependencies`), and `files` with final deploy paths

Minimal shape (illustrative):

```json
{
  "name": "openai-api-key",
  "scope": "user",
  "share": false,
  "neededFor": "users",
  "store": { "secretStore": "…", "publicStore": "…" },
  "meta": {},
  "validation": {
    "hostname": "host"
  },
  "derivation": {
    "dependencies": [],
    "hostname": "host",
    "generatedAt": "2024-01-01T00:00:00Z"
  },
  "files": [
    {
      "name": "key",
      "secret": true,
      "owner": "root",
      "group": "root",
      "mode": "0400",
      "neededFor": "users",
      "description": null,
      "path": "/run/secrets-for-users/vars/openai-api-key/key"
    },
    {
      "name": "manifest.json",
      "secret": false,
      "owner": "root",
      "group": "root",
      "mode": "0400",
      "neededFor": "users",
      "description": "Machine-readable secret manifest",
      "path": "/run/secrets-for-users/vars/openai-api-key/manifest.json"
    }
  ]
}
```

## Production without manifests

The fleet runs with `generateManifest = false` (no `manifest.json` is
deployed). To debug a secret on the target host, inspect the deployed files
directly under `/run/secrets/vars/<name>/` (or `/run/secrets-for-users/vars/<name>/`
for `users`-scoped files) and compare with the generator source in
`vars/generators/`. Whether manifests should be re-enabled or stay off is an
open decision; the cost argument for keeping them off has not been recorded.

---

## Consume from another flake

```nix
{
  description = "My infra with vars-native secrets via flake-parts module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    # This repo
    secrets-helper.url = "github:perstarkse/clan-vars-secrets-helper";
    secrets-helper.inputs.nixpkgs.follows = "nixpkgs";
    secrets-helper.inputs.flake-parts.follows = "flake-parts";
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, secrets-helper, ... }:
  flake-parts.lib.mkFlake { inherit inputs; } {
    systems = [ "x86_64-linux" "aarch64-linux" ];

    perSystem = { pkgs, system, ... }: { };

    flake.nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        # Import the module (exported as `default`)
        secrets-helper.nixosModules.default

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

          # Multiple exposures (preferred)
          my.secrets.exposeUserSecrets = [
            {
              enable = true;
              secretName = "surrealdb-credentials";
              file = "credentials";
              user = "surrealdb";
              dest = "/var/lib/surrealdb/credentials.env";
              mode = "0400";
            }
            {
              enable = true;
              secretName = "user-ssh-key";
              file = "key";
              user = config.my.mainUser.name;
              dest = "/home/${config.my.mainUser.name}/.ssh/id_ed25519";
              mode = "0400";
            }
            {
              enable = true;
              secretName = "user-age-key";
              file = "key";
              user = config.my.mainUser.name;
              dest = "/home/${config.my.mainUser.name}/.config/sops/age/keys.txt";
              mode = "0400";
            }
          ];

          # Example: use deployed file path in another module option
          services.my-service.settings.pass_file =
            config.my.secrets.paths."openai-api-key".key.path;
        })
      ];
    };
  };
}
```

---

## Example: multiline secret prompt

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

---

## Notes

- This module only populates `clan.core.vars.generators`; it does not ship a CLI
- For metadata-driven rotation, add a stable hash to `validation` as needed, e.g.:

  ```nix
  validation = {
    version = 1;
    # metaHash = builtins.hashString "sha256" (builtins.toJSON meta);
  };
  ```

---

## Dev shell

```
nix develop
nix fmt
```

## License

MIT
