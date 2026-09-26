# Operations & Reliability Review — clan-vars-helper (`my.secrets.*`)

Scope: production operations of the flake-parts module wrapping `clan.core.vars.generators`,
as deployed in `/mnt/sdb/repos/infra` on charon, makemake, ariel, io, sedna.
Helper sources read: `README.md`, `CHANGELOG.md` (Unreleased), `nix/nixos/module.nix`,
`nix/nixos/acl.nix`, `nix/nixos/expose-user.nix`, `nix/nixos/manifest.nix`, `nix/nixos/lib.nix`.
Infra evidence: `modules/system/vaultwarden.nix`, `modules/system/wireguard-tunnels.nix`,
`vars/generators/ntfy.nix`, `vars/generators/air-exhaust-mqtt.nix`,
`machines/*/configuration.nix` discover blocks, `modules/system/shared.nix`,
`tests/io-predeploy.nix` + `tests/lib/secrets-stub.nix`.

## TL;DR

The helper gets the big operational idea right: one generator definition, clan deploys it,
consumers reference it by `getPath`, and rotation is observed with `systemd.path` units.
The failure modes are all at the edges: (1) rotation/restart is every consumer's own
hand-rolled job with no shared primitive, (2) the `systemd.path` + `oneshot` units the
helper *does* own have restart/trigger settings that invite missed events or tight loops,
(3) `share = true` multi-machine consistency depends on tag discipline with no deploy-time
guard in this repo, and (4) fleet-wide `generateManifest = false` removes the one
machine-readable observability surface the README sells, with no replacement documented.

## What is done well (keep)

- **Path-by-reference, not path-by-convention.** `getPath` (`nix/nixos/module.nix`)
  centralises the `/run/secrets[-for-users]/vars/<gen>/<file>` layout. Infra uses it
  pervasively (`vaultwarden.nix:environmentFile`, `wireguard-tunnels.nix`,
  `mosquitto.nix`, machine configs). One layout change = one repo change.
- **Rotation pattern is documented by example, correctly.** `vaultwarden.nix`
  states `restartTriggers` on `/run/secrets` paths are inert and shows the working
  alternative: `systemd.paths.<name>` with `PathChanged` → `try-restart` service.
  `wireguard-tunnels.nix` extends it per-tunnel with `try-restart` (not `restart`, so
  manually-down tunnels stay down). This is the right split given clan owns secret
  delivery and systemd owns service lifecycle.
- **The air-exhaust comment is operational gold.** `vars/generators/air-exhaust-mqtt.nix`
  documents that clan runs the generator with a fresh empty `$out`, that any execution
  regenerates *all* files, and what deliberate rotation looks like. Every multi-file
  generator should carry this paragraph.
- **Expose-copy is idempotent.** `expose-user.nix` `cmp -s` before `install` avoids
  churning mtimes on every trigger. Correct for a copy-into-homedir bridge.
- **ACL apply is idempotent.** `acl.nix` re-applies `setfacl` unconditionally and says so.
  Correct: clan redeploys replace the file and drop the ACL, so re-apply-on-any-trigger
  is the right semantics.

## Findings (severity-ranked)

### P1 — Rotation responsibility is split with no shared primitive; each consumer re-invents it

- Evidence: `vaultwarden.nix:86-99` (hand `systemd.paths` + restart service),
  `wireguard-tunnels.nix` (per-tunnel mapAttrs' path+restart pair), `surrealdb`/`mosquitto`
  equivalents. Helper offers `getPath` but no `mkRotationWatcher { secretName, file, service }`.
- Impact: N consumers × slightly different `PathChanged` vs `PathModified`, `Unit` wiring,
  restart vs try-restart choices. A new service author copies the nearest example, which may
  be the wrong one (vaultwarden wants restart; wireguard wants try-restart; a socket-activated
  service may want neither).
- Recommendation: add one helper constructor for the two shapes already proven in prod
  (`restartServiceOnRotation`, `tryRestartServiceOnRotation`), or document the decision tree
  (when `restart` vs `try-restart` vs reload) next to `getPath` in the README. Do not add a
  third mechanism; codify the two that exist.

### P1 — `share = true` consistency rests entirely on tag lists; a missed tag silently deploys nowhere

- Evidence: `air-exhaust-mqtt.nix` header (io-only inline declaration previously never reached
  charon, so `clan machines update` deployed secrets to io only); per-machine
  `includeTags` in `charon/configuration.nix:338`, `io/configuration.nix:265`,
  `makemake/configuration.nix:115`; `ntfy` shared across charon/makemake/io.
- Impact: adding a file or a consumer machine without updating every relevant `includeTags`
  list yields a missing `/run/secrets…` file at runtime, not an eval error. `getPath`
  returns a string regardless (it is pure path arithmetic in `module.nix`), so the
  misconfiguration is invisible until the unit fails.
- Recommendation: keep the infra-side `secrets-discovery-check.py` discipline, but add a
  helper-side eval-time assertion option (e.g. `my.secrets.requireGenerators = [...]`)
  that fails `nixos-rebuild` when an expected generator is absent from
  `config.clan.core.vars.generators`. Opt-in per machine; no tag-schema change.

### P2 — Expose-unit `StartLimitBurst = 100 / 10s` + `Restart=on-failure` can tight-loop on a persistently failing copy

- Evidence: `nix/nixos/expose-user.nix:mkServiceUnit` (`StartLimitIntervalSec = 10`,
  `StartLimitBurst = 100`, `Restart = "on-failure"`, `RestartSec = 1`); the script itself
  can fail (`install -d` on a read-only `/home`, `id -gn <user>` for a not-yet-created user
  at boot, `set -euo pipefail` + missing src).
- Impact: ~10 restarts/sec for 10s before start-limit engages, per entry, at exactly the
  moment the machine is booting. Compare ACL units in `acl.nix` (`300s / 60 burst`) — the
  two subsystems disagree by 30× on what a sane loop looks like.
- Recommendation: align expose units with the ACL values (or stricter: `Restart=on-failure`
  only, no path-triggered re-fire storm), and add `ConditionUserExists`-style guard or
  documentOrdering after `systemd-homed`/`users.target` when `dest` is under `/home`.

### P2 — Expose-unit `ConditionPathExists` + `PathModified`/`PathChanged` pair can miss the first deploy

- Evidence: `expose-user.nix:mkPathUnit` watches `srcFile` (PathModified) and `srcDir`
  (PathChanged); `mkServiceUnit` sets `ConditionPathExists = srcFile`.
- Impact: if the `.path` unit fires on directory creation before clan finishes writing the
  file, the service is skipped by the condition and there is no guaranteed re-fire when the
  file content lands (depends on whether clan's deploy generates a second inotify event on
  the watched dir — true for atomic rename, not guaranteed for all store layouts). The
  script's `else echo "Warning…"` branch then logs and exits 0, so nothing retries.
- Recommendation: drop `ConditionPathExists` in favour of the script's existing
  `[ -s srcFile ]` guard with non-zero exit on absent source (so `Restart=on-failure`
  retries), or add `TriggerLimitIntervalSec` + documented expectation that clan deploy
  always produces a second event. Either way, make "source not there yet" loud, not a warning.

### P2 — ACL units watch the parent dir (`PathChanged = dirOf path`); busy dirs risk spurious storms

- Evidence: `acl.nix:mkUnitsForItem` sets both `PathModified = item.path` and
  `PathChanged = builtins.dirOf item.path`. For `/run/secrets-for-users/vars/<gen>/<file>`
  the parent is per-generator (small), but manual `allowReadAccess` entries can point
  anywhere (e.g. a file directly under a busy directory).
- Impact: every sibling change re-runs `setfacl`. Idempotent but noisy; combined with
  `StartLimitBurst = 60 / 300s` a hot directory can suppress legitimate re-applies.
- Recommendation: document that manual ACL targets should be per-service files/dirs, not
  busy shared dirs; consider `TriggerLimitIntervalSec`/`TriggerLimitBurst` on the `.path`
  units (systemd ≥249) to coalesce storms instead of relying on service start-limit.

### P3 — `generateManifest = false` fleet-wide removes the observability the README centres

- Evidence: `modules/system/shared.nix:143` sets `generateManifest = lib.mkDefault false`
  on every machine; README "Manifest" section and `manifest.nix` describe
  `/run/secrets…/manifest.json` as *the* machine-readable surface (name, scope, store,
  `generatedAt`, per-file paths).
- Impact: on-host debugging (`cat …/manifest.json` to confirm which store/hostname
  produced a secret, when it was generated) does not work in prod. Nothing in the README
  says the fleet disables it or what replaces it (`clan vars get`? journal?).
- Recommendation: either re-enable manifests (they are `secret = false`, `0400`, one small
  JSON per generator — state the cost argument if the disable was deliberate), or add a
  "Production without manifests" README section naming the replacement debug path.
  Current state: docs promise X, fleet runs not-X.

### P3 — README/runtime-layout section omits the `vars/` path segment in one place, manifests disagree

- Evidence: README "Manifest" bullet says `/run/secrets/<name>/manifest.json`, while
  `manifest.nix` post-step and `module.nix:runtimePath` both emit
  `/run/secrets[-for-users]/vars/<name>/<file>`, and the README's own JSON example shows
  the `vars/` segment. A reader wiring monitoring/alerting from the bullet alone watches a
  path that never exists.
- Recommendation: one-line doc fix; add an eval assertion or test pinning `runtimePath`
  output so docs and code cannot drift again.

### P3 — Mixed `neededFor` within one shared generator splits one secret across two stores

- Evidence: `air-exhaust-mqtt.nix`: five files default `services`, one file
  (`charon-ro.env`) overrides `neededFor = "users"`. Same generator → files land under
  both `/run/secrets/vars/…` (io mosquitto) and `/run/secrets-for-users/vars/…` (charon widget).
- Impact: works, and the comment explains why — but rotation now means two deploy paths,
  two ACL/expose mechanisms, and a reader that must know which file lives where. `getPath`
  hides this (correct per-file), but nothing warns when a generator spans stores.
- Recommendation: keep supporting it (the use case is real), but log/trace it: e.g. manifest
  already records per-file `neededFor`; when manifests are disabled there is no trace. At
  minimum document "one generator, two stores" as a supported-but-noteworthy pattern.

### P4 — `getPath` never fails: typo'd generator/file names eval cleanly, break at runtime

- Evidence: `module.nix:getPathFun` returns `null` (via `or null`) for unknown names; string
  interpolation of `null` fails, but assignment to `environmentFile`/`passwordFile`-style
  options may accept it and fail only when the unit starts.
- Impact: the most common authoring error (wrong file key after renaming a generator) is
  caught latest.
- Recommendation: add opt-in strict mode (`my.secrets.assertPaths = true`) that turns
  unknown lookups into eval errors. Default off to preserve `lib.mkIf`-style conditional
  composition; enable on the machines that can afford it.

### P4 — Tests stub the helper out, so helper behaviour is untested where it matters

- Evidence: `tests/io-predeploy.nix:28-39` replaces `vars-helper` with `secrets-stub.nix`
  (`getPathDefault = …"/etc/test-secrets/…"`, `mkMachineSecretDefault = spec: spec`).
  Helper's own `nix/tests/eval-test.nix` covers one constructor shape only.
- Impact: rotation wiring, ACL units, expose copies, and `share` semantics are never
  exercised in infra CI; regressions surface on hardware.
- Recommendation: (infra-side) at least one VM test using the real helper module with a
  tiny generator, asserting the deployed path exists and a rotation watcher fires. This is
  an infra-test gap more than a helper bug, but the helper could lower the cost with a
  minimal `tests/` example machine.

## Open questions (for maintainer / infra owner)

1. Was `generateManifest = false` a size/store-path decision, a `secretStore = sops` hygiene
   call, or a leftover? The answer determines whether P3-manifest is "re-enable" or "document".
2. Who owns service restarts on rotation — helper (new primitive) or each consumer module?
   P1-rotation asks for a decision, not just code.
3. Is `share = true` + per-machine `includeTags` the long-term topology, or should shared
   generators move to a single declaring module imported by all consumers (the air-exhaust
   comment's alternative)? The current answer is "tags + discovery-check", which works but
   keeps the silent-miss failure mode.
4. What is the boot-order contract for `dest` under `/home` (expose units)? `after =
   local-fs.target` only; homed/impermanence interplay is untested per this review.
5. Should manual `allowReadAccess` to `readers = ["root"]` (wireguard) exist at all —
   root already reads `0400 root:root`? Harmless but suggests the API is used as
   documentation in at least one place; worth a comment so nobody copies it as required.

## Suggested next steps (smallest useful order)

1. Fix the README `vars/` path bullet (P3, minutes) + pin `runtimePath` in eval-test.
2. Document "no manifests in prod → debug via …" or re-enable manifests (P3, decision + hour).
3. Align expose-unit start-limit/restart with ACL units; make absent-source loud (P2s, small).
4. Add `mkRotationWatcher` or document restart-vs-try-restart decision tree (P1, half-day).
5. Add opt-in `requireGenerators`/`assertPaths` eval guards (P1/P4, half-day, high leverage).
