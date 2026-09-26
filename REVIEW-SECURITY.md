# Security & secrets-lifecycle review — clan-vars-helper (`my.secrets.*`)

Scope: `nix/nixos/{module,lib,manifest,acl,expose-user}.nix` + `README.md`, informed by
production use in `/mnt/sdb/repos/infra` (fleet `shared.nix`, per-machine `discover.includeTags`,
`vars/generators/*`, inline `mkMachineSecret` in `vaultwarden.nix`, `allowReadAccess` in
`ntfy/heartbeat/wireguard-tunnels`, `exposeUserSecrets` for `user-ssh-key`/`user-age-key`/`air-exhaust-mqtt`).
No code changed by this review.

## Verdict

The module gets the big things right (0400 root-owned defaults, no secret values in the Nix store,
`umask 077` in generator scripts, idempotent ACL application). The residual risk concentrates in
**credential-copy sprawl** (`expose-user.nix`), **revocation gaps** (ACLs/copies never removed),
**fail-open null paths** (`getPath` → `null`), and **metadata leakage** (manifest + `_acl_*` in
validation). Highest-priority fixes are S1–S3.

## Severity-ranked findings

### S1 — High: `expose-user.nix` shell interpolates `user`/`dest`/`mode` without escaping (command injection / path traversal)

- Evidence: `nix/nixos/expose-user.nix:35` (`destDir = "$(dirname '${destPath}')"` — `destPath`
  single-quoted into shell, breaks on `'` in path), `:54` (`group="$(id -gn ${es.user})"`),
  `:56` (`install -d -m 0700 -o ${es.user} -g "$group" "${destDir}"`),
  `:60` (`install -m ${es.mode or "0400"} -o ${es.user} -g "$group" "${srcFile}" "${destPath}"`).
  `user`/`dest`/`mode` are free-form strings from consuming modules, not `escapeShellArg`-ed.
- Production exposure: `../infra/machines/charon/configuration.nix:327-335` and
  `../infra/modules/system/shared.nix:146-160` pass `config.my.mainUser.name` and interpolated
  home paths as `user`/`dest`. Today those values are trusted, so exploitability is low — but any
  future dynamic `user`/`dest` (per-service users, derived names) inherits root-executed injection.
- Fix: `escapeShellArg` all interpolations; validate `dest` is absolute and under an allowlist
  (`/home/`, `/var/lib/user-secrets/`); reject `mode` outside `0400|0440|0600`.

### S1 — High: ACL grants and exposed copies are never revoked (stale access outlives config)

- Evidence: `nix/nixos/acl.nix:93-99` applies `setfacl -m u:<user>:r` when the file exists and does
  nothing on removal; `nix/nixos/expose-user.nix:53-62` copies on change but never deletes `dest`.
  No `setfacl -x` path, no `clean`/`ExecStop`, no `mkIf`-driven tombstone.
- Production exposure: `../infra` grants per-machine `allowReadAccess` (charon `:341-368`,
  shared `:162-179`, heartbeat, ntfy, wireguard-tunnels) and copies `user-ssh-key`/`user-age-key`
  into home dirs. Removing a reader (offboarding, service rename) leaves the ACL/copy readable
  until manual cleanup or rotation. For SSH/age keys this is a persistent-authentication risk.
- Fix: on empty `readers`, emit a revoker unit (`setfacl -x`); on `exposeUserSecrets` entry removal,
  optionally remove `dest` (opt-in `removeOnDisable`) and document rotation runbook.

### S1 — High: identical hardcoded ntfy fallback password hashes in production generator

- Evidence: `../infra/vars/generators/ntfy.nix:62-65` — all four `fallback_*_hash` values are the
  identical bcrypt string `$2b$10$QqZS0iP8PwNX1ddWX7ynCeLKM72wyx1PQYUt8sOd08mXQIQwe8U9G`;
  `:151`,`:168` write fallbacks into `$out/env` when prompts are absent.
- Note: this file lives in `../infra`, not in this repo, so the fix belongs there; flagged here
  because the helper's `$prompts`-absent fallback pattern (`manifest.nix` mktemp-empty-dir,
  `lib.nix` auto-prompt only with explicit `promptType`) makes "generator ran without prompt"
  a silent, normal path rather than an error.
- Fix (infra side): generate per-deployment random passwords when prompts are absent; never ship a
  shared constant hash. Helper side: consider `requiredPrompts` option that fails the generator
  loudly when `$prompts/<file>` is missing instead of falling through.

### S2 — Medium: `getPath` returns `null` on miss — consumers fail open or mis-wire

- Evidence: `nix/nixos/module.nix` `getPathFun` (`f.path or null`). Consumers do
  `environmentFile = config.my.secrets.getPath "vaultwarden" "env"` (`vaultwarden.nix:80`),
  `tokenFile`/`passwordFile` across charon/makemake/io/sedna, and
  `path = config.my.secrets.getPath ...` inside `allowReadAccess` (charon `:341+`, shared `:162+`).
- Consequence: an undiscovered generator (tag typo, missing `includeTags` — the exact
  air-exhaust precedent documented in `air-exhaust-mqtt.nix:1-9`) yields `null`, which either
  breaks eval late, produces `allowReadAccess` entries filtered silently
  (`acl.nix:51` filters `""` but `null` `path` passes `builtins.isString` check as false → silently
  dropped, so the service starts **without** its intended ACL), or sets `environmentFile = null`
  (service starts without secrets). Silent ACL-drop is fail-open.
- Fix: add `getPathStrict` (throw on miss) and use it for `environmentFile`/`allowReadAccess`;
  or assert at eval that every `allowReadAccess.path != null`.

### S2 — Medium: `_acl_additionalReaders` smuggles reader lists through Clan `validation` (metadata leak)

- Evidence: `nix/nixos/lib.nix:122` (`_acl_additionalReaders = builtins.toJSON additionalReadersByFile`),
  read back via `builtins.fromJSON` in `nix/nixos/acl.nix:17-18`.
- Consequence: usernames/service-names plus generator→file mapping are persisted in Clan's
  validation/vars metadata path, which — unlike `/run/secrets` — is not necessarily 0400
  root-only (Clan vars stores include git-backed public store). An attacker with repo/store
  read access learns who can read what without touching the host. Only `vaultwarden.nix:128`
  uses `additionalReaders` in prod today, so exposure is currently small, but the channel is
  structural.
- Fix: keep ACL intent in a module-local option (outside `clan.core.vars.generators.validation`)
  instead of piggybacking Clan's persisted schema; document that `validation` content may be stored.

### S2 — Medium: `manifest.json` is `secret = false` with store/host metadata (info disclosure)

- Evidence: `nix/nixos/lib.nix:15-23` (`"manifest.json"` with `secret = false`, `mode 0400`);
  `nix/nixos/manifest.nix:29-30` embeds `secretStore`/`publicStore`, `:derivation.hostname`,
  `meta`, `validation`, per-file paths.
- Consequence: `secret = false` routes the file toward Clan's public/non-secret handling
  (potentially git-committed), publishing hostnames, store backend names, generator/file inventory,
  and `meta` (which in prod includes descriptions/owners/tags). Useful for debugging, valuable for
  reconnaissance.
- Mitigating fact: prod disables manifests fleet-wide
  (`../infra/modules/system/shared.nix:143` `generateManifest = lib.mkDefault false`), so current
  exposure is low — but that also means the manifest code path (README's headline feature) is
  **untested in production**, and any machine overriding `generateManifest = true` silently opts
  into the leak.
- Fix: default manifest to minimal fields (name + file list), gate `meta`/`validation`/`store`
  behind an option (`manifestVerbosity`), or reconsider `secret = false` for manifests carrying
  host/store metadata.

### S2 — Medium: `sops.useTmpfs` flipped as a side effect (`acl.nix:58,151`)

- Evidence: `nix/nixos/acl.nix:58` (`enableSopsTmpfs`), `:151`
  (`sops.useTmpfs = lib.mkIf enableSopsTmpfs (lib.mkDefault true)`).
- Consequence: enabling an ACL under `/run/secrets-for-users` silently changes global sops-nix
  storage to tmpfs. README discloses the swap-to-disk caveat, but a per-file ACL decision should
  not implicitly reconfigure host-wide secret storage with only `mkDefault` overridability.
- Fix: warn (`warnings = [...]`) when auto-enabling; document swap-encryption requirement next to
  the option, not only in README.

### S3 — Low: systemd trigger surface is broader than the secret (sibling-triggered runs)

- Evidence: `nix/nixos/acl.nix:76-79` (`PathChanged = dirOf item.path`), similar pattern in
  `nix/nixos/expose-user.nix` path units. `acl.nix` burst allowance 60/300s; expose units
  100/10s with `Restart = on-failure`.
- Consequence: any sibling file creation/rename in `/run/secrets*/vars/<name>/` fires the unit;
  combined with `Restart=on-failure`, a persistently failing `setfacl`/`install` loops with
  elevated cadence. Benign in steady state, noisy under rotation of multi-file generators
  (e.g. `air-exhaust-mqtt` with 6 files, `ntfy` with 5).
- Fix: prefer `PathModified` on the file + `PathChanged` only where atomic-replace is proven;
  lower `StartLimitBurst`, add `RestartSteps`/`RestartMaxDelaySec`.

### S3 — Low: `share = true` has no blast-radius guardrail

- Evidence: `nix/nixos/lib.nix` `mkSharedSecret` forces `share = true`; prod shares ntfy (5 files),
  air-exhaust-mqtt (6 files), surrealdb-credentials across machines.
- Consequence: one host's vars-store compromise yields fleet-valid credentials by design. No
  finding of wrongdoing — but neither the module nor README names rotation/impact expectations
  for shared generators.
- Fix: document per-generator rotation procedure + blast radius in `meta` convention; consider a
  warning when a shared generator mixes `services` and `users` scopes (as air-exhaust does).

### S3 — Low: `discover` import executes arbitrary Nix from a directory

- Evidence: `nix/nixos/module.nix` `importFile` (`import (dir + "/${f}")`, function-or-attrs).
- Consequence: any `*.nix` dropped in `vars/generators` runs at eval with full Nix power. In prod
  the dir is in-repo (`shared.nix:142` pins `../../vars/generators`), so trust equals repo write
  access — acceptable, but worth naming: generator dir writability == full config compromise.
- Fix: one-line doc note; no code change needed.

## What prod does right (keep)

- Fleet `generateManifest = false` (`shared.nix:143`) currently avoids the S2 manifest leak.
- `secrets-discovery-check.py` (fail-closed undiscovered-generator check) directly mitigates the
  S2 null-path class at the tag level.
- `0400`/`root:root` defaults, `umask 077` in scripts, idempotent `setfacl`, `cmp`-before-copy,
  and `0400` on `manifest.json` are all sound defaults.

## Suggested fix order

1. S1 shell escaping (`escapeShellArg` + `dest` validation) — small, root-executed.
2. S1 revocation (ACL `-x` units, `removeOnDisable` for copies) — closes offboarding gap.
3. S1 ntfy fallback hashes (infra repo) + helper `requiredPrompts` — kills shared-secret constant.
4. S2 `getPathStrict`/eval assertions — converts silent fail-open into loud eval failure.
5. S2 move ACL intent out of Clan `validation`; S2 manifest minimal-by-default; S2 tmpfs warning.

## Review method

Read all six helper sources and README; sampled `../infra` fleet wiring (`shared.nix`,
`machines/charon/configuration.nix:320-370`, `vaultwarden.nix:115-140`, `ntfy.nix:70-95`,
`heartbeat.nix:495-515`, `vars/generators/ntfy.nix:60-170`, `vars/generators/` listing).
No test runner in this repo beyond `nix/tests/eval-test.nix`; no code executed.
`git status --porcelain` shows only pre-existing untracked `CHANGELOG.md`, `result*` symlinks;
no staged files touched by this review.
