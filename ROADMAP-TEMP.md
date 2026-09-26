# TEMPORARY Roadmap — clan-vars-helper review follow-ups

> **Status: draft, temporary.** Created 2026-09-14 from `REVIEW-SECURITY.md`,
> `REVIEW-MODULE-DESIGN.md`, `REVIEW-OPERATIONS.md` (all in this directory).
> Not a committed plan: delete this file or promote items to real issues.
> Baseline evidence: `nix flake check` exits 0, "all checks passed!"
> (formatting + `vm-module-eval`) on 2026-09-14 with no source changes.

## How to verify anything below (project contract)

Helper repo gate (this repo — run from here):

```bash
nix flake check            # formatting + vm-module-eval; must exit 0
nix fmt                    # single formatting entrypoint if treefmt fails
```

Consumer validation (from `../infra`, per its `.agent/project.json`):

```bash
nix flake metadata --no-write-lock-file                                     # fast
nix eval --raw .#nixosConfigurations.charon.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.ariel.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.io.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.makemake.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.sedna.config.system.build.toplevel.drvPath
nix flake check                                                             # full
```

Rules: do not claim verification without exit-code evidence; record the exit
code with each check. Keep `git status --porcelain` clean of everything except
intended files; never commit `result*` symlinks.

## Phase 0 — Docs + pinned behavior (no behavior change, do first)

| # | Issue (source) | Suggestion | Pre-deployment test | Done when |
|---|---|---|---|---|
| R0.1 | README "Manifest" bullet omits `vars/` path segment (P3) | One-line doc fix to `/run/secrets[-for-users]/vars/<name>/<file>` | `nix flake check` exit 0; grep README for `vars/` path | Bullet matches `runtimePath` in `module.nix:75-77` |
| R0.2 | `extractTags` top-vs-inner precedence, not union; disagrees with `secrets-discovery-check.py` (F3.1) | Union top-level + inner tags; align check script to same rule | New eval-test cases: top/inner/both/empty tag files → expected sets; `nix flake check` exit 0; run `python3 lib/secrets-discovery-check.py` in `../infra` exit 0 | Both implementations union; tests pin it |
| R0.3 | `runtimePath` triplicated (`module.nix`, `acl.nix`, `expose-user.nix`, jq in `manifest.nix`) (F5) | Extract one shared `runtimePath` lib; assert equality in eval-test | `nix flake check` exit 0; eval-test asserts `getPath` output for services + users scopes | Single definition imported by all four sites |
| R0.4 | Manifest decision unrecorded; fleet runs `generateManifest=false` (F4/P3) | Record decision: re-enable manifests or bless no-manifest + document replacement debug path (`clan vars get`? journal?) | Docs-only; `nix flake check` exit 0 | README "Production without manifests" section exists or re-enable ticket filed with cost argument |

## Phase 1 — Fail closed on lookups and discovery (high leverage, small diff)

| # | Issue (source) | Suggestion | Pre-deployment test | Done when |
|---|---|---|---|---|
| R1.1 | `getPath`/`getValue` return `null` on miss → broken strings / silently dropped ACLs (S2/F2/P4) | **No lenient variant kept** (owner waived compat): `getPath`/`getValue` themselves throw with available-names hint | Eval-test: lookup on missing gen/file fails eval (assert `builtins.tryEval` fails); valid lookup returns path; `nix flake check` exit 0 | `getPath`/`getValue` strict, tested, no `*Strict` alias left behind |
| R1.2 | Shared generator missed tag deploys nowhere, invisible until runtime (P1) | Opt-in `my.secrets.requireGenerators = [...]` eval assertion: fail `nixos-rebuild` when expected generator absent from `clan.core.vars.generators` | Eval-test: required-but-absent → eval failure; present → success; `nix flake check` exit 0 | Option exists, tested, at least one `../infra` machine opts in (infra-side change) |
| R1.3 | Empty `includeTags` = include-all; duplicate generator names last-wins silently; typo'd `discover.dir` = silent empty (F3.3–F3.5/F6) | Require non-empty `includeTags` when `enable`; `trace` on duplicate generator names; assert `dir` exists when `enable` | Eval-test table: empty-tags-enabled fails, duplicates warn, bad dir fails; `nix flake check` exit 0 | All three guards tested; existing `../infra` machines still eval (5× `toplevel.drvPath` exit 0) |

## Phase 2 — Harden root-executed shell + units (S1/P2)

| # | Issue (source) | Suggestion | Pre-deployment test | Done when |
|---|---|---|---|---|
| R2.1 | `expose-user.nix` interpolates `user`/`dest`/`mode` unescaped (S1/F9) | `escapeShellArg` all interpolations; validate `dest` absolute + under allowlist (`/home/`, `/var/lib/user-secrets/`); reject `mode` outside `0400\|0440\|0600`; sanitize/hash unit names like `acl.nix` | Eval-test builds units with adversarial `user`/`dest` (e.g. `"a';id;#"`); inspect rendered script contains quoted form; `nix flake check` exit 0 | Adversarial inputs render inert; invalid `mode`/relative `dest` fail eval |
| R2.2 | Expose units `StartLimitBurst=100/10s` + `Restart=on-failure` tight-loop; `ConditionPathExists` can miss first deploy (P2) | Align with ACL values (`60/300s` or stricter); make absent-source loud (non-zero exit → retry) instead of warning-exit-0; document boot-order contract for `dest` under `/home` | Eval-test asserts unit fields (`StartLimitIntervalSec/Burst`, no `ConditionPathExists` or documented second-event expectation); `nix flake check` exit 0 | Limits aligned, absent-source retries, contract documented |
| R2.3 | ACL `PathChanged = dirOf path` storms on busy dirs (P2/S3) | Document manual targets must be per-service files; consider `TriggerLimitIntervalSec/Burst` (systemd ≥249) to coalesce | Eval-test unit-count unchanged; `nix flake check` exit 0 | Docs + optional trigger limits; no behavior regression on generator-dir targets |

## Phase 3 — Lifecycle: revocation + rotation (closes real gaps)

| # | Issue (source) | Suggestion | Pre-deployment test | Done when |
|---|---|---|---|---|
| R3.1 | ACL grants / exposed copies never revoked on config removal (S1) | Empty-`readers` emits revoker unit (`setfacl -x`); opt-in `removeOnDisable` for copies; document rotation/offboarding runbook | Eval-test: empty-readers entry produces revoker unit with `-x`; removal-flag produces `ExecStop`/cleanup; `nix flake check` exit 0 | Revocation path tested; runbook in README |
| R3.2 | Rotation restart hand-rolled per consumer (P1) | Add `mkRotationWatcher` / try-restart constructors codifying the two proven shapes (vaultwarden restart vs wireguard try-restart), or document restart-vs-try-restart decision tree next to `getPath` | New helper used by one example consumer in eval-test; `nix flake check` exit 0; `../infra` 5× eval exit 0 after adopting (infra-side) | Primitive exists or decision tree documented; no third mechanism added |
| R3.3 | Silent prompt-less runs; hardcoded ntfy fallback hashes (S1, infra file) | Helper: `requiredPrompts` option failing generator loudly when `$prompts/<file>` missing. Infra-side (separate repo): per-deployment random passwords, never shared constant | Eval-test: required-prompt-missing → generator script fails (shell-level test or assertion on rendered script); infra fix verified by rotating one host and diffing outputs | Loud failure tested here; ntfy fix tracked in `../infra` (not closable from this repo) |

## Phase 4 — Metadata hygiene

| # | Issue (source) | Suggestion | Pre-deployment test | Done when |
|---|---|---|---|---|
| R4.1 | `_acl_additionalReaders` JSON sidecar in Clan `validation` (F1/S2) | Promote ACL intent to sibling option (e.g. `my.secrets.acl.<gen>.<file>.readers` resolved post-merge); fallback: assert no user-supplied key + document rotation semantics | Eval-test: user-supplied `_acl_additionalReaders` rejected or namespaced; round-trip readers→units asserted; `nix flake check` exit 0 | No structured data in `validation`, or hack asserted + rotation implication documented |
| R4.2 | Manifest `secret=false` info disclosure + unconditional `jq` cost (S2/F4) | Minimal manifest by default (name + file list); gate `meta`/`validation`/`store` behind `manifestVerbosity`. **jq deliberately kept in every closure**: dropping it only from the no-manifest branch would change generator inputs on the input bump and risk re-generation (accidental rotation) fleet-wide | Eval-test: default manifest lacks `meta`/`validation`; `generateManifest=false` output still carries `jq` in `runtimeInputs` (asserted present, not absent); `nix flake check` exit 0 | Verbosity gate tested; jq-kept asserted |
| R4.3 | `sops.useTmpfs` flipped as ACL side effect (S2) | Document swap-encryption requirement at the option + README. **No `warnings = [...]`**: it self-triggered infinite eval recursion (warnings force full config eval → re-reads `needsUsersAcl` from clan generators); documented in `acl.nix` why | Eval-test: ACL-under-users-run auto-enables `sops.useTmpfs` (asserted true); `nix flake check` exit 0 | Side effect asserted + documented at option, not only README |

## Phase 5 — Types + test suite (locks in the above)

| # | Issue (source) | Suggestion | Pre-deployment test | Done when |
|---|---|---|---|---|
| R5.1 | `types.raw` / `listOf attrs` / `listOf attrs` home entries erase API boundary (F6/F7/F9) | Submodule types for `wrappedHomeBinaries` + expose entries (default `dest` as `null`, not `""`); assertions on `declarations` shape; default `useSystemdRun=true` or warn when `false` with secret path (document store-visibility tradeoff of plain mode) | Eval-test: malformed entry fails with helpful message; `nix flake check` exit 0 | Typed seams + at least one assertion per seam |
| R5.2 | Single happy-path eval-test (F10) | Promote README patterns to assertion table: prompts shape, manifest on/off, discovery filtering, path/value helpers incl. miss, `_acl` round-trip, `stripMeta`, duplicate merge, ACL/expose unit counts | `nix flake check` exit 0 with expanded table green | Every Phase 0–4 behavior has ≥1 eval assertion; suite fails if any finding regresses |
| R5.3 | Infra VM tests stub the helper out (P4, infra-side) | One `../infra` VM test using the real helper with a tiny generator: assert deployed path exists + rotation watcher fires | `nix flake check` in `../infra` exit 0 (infra-side) | Tracked in `../infra`; not closable here |

## Validation-complete checklist (whole roadmap)

Evidence recorded 2026-09-15 (helper-side session, commits on `main`):
`8bb963e` (Ph0), `2d2c094` (Ph1, since superseded: lenient `getPath` removed,
no `*Strict` alias kept), `f973bbe` (Ph2), `2cec53e` (Ph3), `621ae94` (Ph4,
since amended: jq kept for rotation safety, warning replaced by docs),
`cfb1143`+`3cc7278` (Ph5). Helper gate green at HEAD:
`nix flake check` exit 0 (eval + treefmt + pre-commit). Infra 5x
`toplevel.drvPath` exit 0 (charon, ariel, io, makemake, sedna);
`nix flake metadata --no-write-lock-file` exit 0.

Rotation-safety rule applied throughout: no change may alter existing
generator closures/inputs on the input bump (that risks re-generation =
accidental rotation). Concretely: jq kept unconditionally; strict getPath
changes eval only (misses previously produced broken/null downstream, never
valid secrets); manifest-verbosity changes only the rendered script text of
manifest-enabled generators (fleet runs `generateManifest=false`).

- [x] Each closed item cites its pre-deployment commands **with exit codes** (no evidence-free claims).
- [x] `nix flake check` in this repo exits 0 on the final tree.
- [x] `../infra` fast + 5x machine eval exit 0; full `nix flake check` not run — no infra-side changes made this session (infra pins the published input, not this checkout).
- [x] `git status --porcelain` shows only intended files; `result*` symlinks untouched/uncommitted (untracked, confirmed via `git ls-files` in both repos).
- [ ] R3.3-infra and R5.3 either done infra-side or filed as `../infra` issues with links.
- [ ] This TEMP file deleted or replaced by real tracked issues.
