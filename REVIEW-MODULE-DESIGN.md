# Review: Nix module design & developer UX (`my.secrets.*`)

Scope: flake-parts module in this repo (`nix/nixos/*`, `nix/home/*`, `nix/tests/*`,
`README.md`, `CHANGELOG.md`) as used by production fleet in
`/mnt/sdb/repos/infra` (5 machines, `vars/generators/*.nix` + inline
`my.secrets.declarations`, fleet-wide `modules/system/shared.nix` wiring).
Read-only review; no code changed.

## TL;DR

The module solves a real ergonomic gap over raw `clan.core.vars.generators`:
constructors with sane defaults, prompt auto-generation, tag discovery,
`getPath`/`getValue` dereferencing, ACL + expose-user automation, and a
home-manager wrapper. Production has converged on a subset of it:
**discovery + `getPath` + `allowReadAccess`**, with **`generateManifest = false`
fleet-wide** and the home wrapper used exactly once. That divergence is the
most important design signal: the manifest-first README describes a product
the fleet deliberately disables, while the tag-routing layer the fleet
depends on is the least specified and least tested part.

Highest-severity items: (1) `validation._acl_additionalReaders` JSON sidecar
is a load-bearing hack with collision/rotation semantics nobody documents;
(2) `getPath`/`getValue` fail soft to `null`, turning typos into broken
strings at service runtime; (3) discovery tag semantics are loose,
order-dependent, and invisible to `nix` until eval; (4) `types.raw`
everywhere plus `listOf attrs` declarations forfeit the type-checking this
kind of helper exists to provide; (5) the single eval test covers one happy
path and none of the above.

## What is done well

- **Constructors match clan's real scopes.** `mkSharedSecret` / `mkMachineSecret` /
  `mkUserSecret` (`nix/nixos/lib.nix:127-138`) encode `share` and
  `defaultNeededFor` once, instead of every call site repeating them. The
  `mkMachineSecret` hostname pin (`lib.nix:135`) is the correct way to scope
  per-machine secrets.
- **Prompt fix is correct and documented.** `CHANGELOG.md` honestly records the
  `stripNonClan` / `input`-wrapper incidents; current flat-format
  `prompts.<file> = { description, type, persist }` handling
  (`lib.nix:61-79`) matches clan-core and the `promptType`-gated
  auto-generation avoids the old stale-prompt leak for `openssl`-style
  generators.
- **Internal attrs are actually stripped.** `promptType`/`description` removal
  before export (`lib.nix:82`), `__defaultNeededFor` sentinel cleanup
  (`lib.nix:84-99`), and `stripMeta` before merging into clan
  (`module.nix:48-56,71`) show care about not polluting clan's schema.
- **Runtime-path model is centralized.** One `runtimePath` definition exists in
  `module.nix:75-77` (mirrored in `acl.nix:7-9`, see finding F5) and both
  nested + flat accessors plus function forms are offered, which fits
  wireguard-tunnels' dynamic `getPath "wireguard-tunnels-${name}" "wg.conf"`
  usage well.
- **Production guardrail was built outside the helper, correctly.**
  `infra/lib/secrets-discovery-check.py` failing closed on undiscovered
  generators is the right response to the air-exhaust precedent, and keeping
  it one-directional (static generator tags vs. dynamic/interpolated consumer
  tags) is a mature scope decision documented in the script header.
- **Legacy compat is handled, not left to rot.** `exposeUserSecret` (singular)
  is kept as deprecated alongside `exposeUserSecrets` (`expose-user.nix:33-76`),
  and the home wrapper keeps a plain (non-systemd) path so `useSystemdRun =
  false` remains usable without a user systemd.

## Findings (severity-ranked)

### F1 — High: `validation._acl_additionalReaders` smuggles structured data through clan's scalar-leaf validation as JSON
Evidence: `nix/nixos/lib.nix:121-123`, `nix/nixos/acl.nix:17-35`.

Every constructor unconditionally injects
`validation._acl_additionalReaders = builtins.toJSON additionalReadersByFile`,
even when empty (`{}` → `"{}"`), and the ACL subsystem `builtins.fromJSON`s it
back per generator. It works only because clan constrains `validation` leaves
to scalars; a map would be rejected, so JSON-in-a-string is the escape hatch.
Consequences:

- Any consumer-supplied `validation._acl_additionalReaders` key is silently
  overwritten by the `//` merge — no assertion, no warning.
- The JSON string participates in clan's `validation` hashing/rotation
  decisions (unconfirmed — clan-core behavior is external to this repo), so
  adding a reader may or may not rotate the secret; neither outcome is
  documented in `README.md`'s ACL section.
- `acl.nix` assumes the JSON parses to `fname -> [readers]` and does
  `readersByFile.${fname} or [ ]` with no shape check; a hand-written
  generator with a malformed value fails eval opaquely inside `fromJSON`.

Recommendation: either promote ACL intent to a first-class sibling option
(e.g. `my.secrets.acl.<gen>.<file>.readers`, resolved post-merge in
`acl.nix` without touching `validation`), or at minimum assert absence of a
user-supplied `_acl_additionalReaders` key and document the rotation
implication explicitly. The current comment ("to satisfy Clan scalar-leaf
constraint") names the cause but not the contract.

### F2 — High: `getPath` / `getValue` return `null` on miss, producing broken service strings instead of eval errors
Evidence: `nix/nixos/module.nix:106-111`, `module.nix:139-145`; production
dependence in `infra/modules/system/wireguard-tunnels.nix:21-22`,
`infra/machines/charon/configuration.nix:344-364`,
`infra/modules/system/shared.nix:165-177`.

On unknown generator/file the helpers return `null`. Interpolated into
`ExecStart`, `environmentFile`, `passwordFile`, `htpasswdFile`, etc., `null`
either fails with a remote `cannot coerce null to string` or — worse via
`toString` paths — silently bakes a wrong path. There is no
`assertGenExists` / `requirePath` variant, no `traceVerbose` on miss, and the
README ("`-> path | null`") normalizes the soft failure. The stub in
`infra/tests/lib/secrets-stub.nix:13-22` replaces `getPath` with an injectable
default, so infra tests never exercise miss behavior either.

Recommendation: keep `getPath` (compat), add `getPathStrict` (throw with
`available generators/files` hint) and migrate internal/first-party modules
to it; or add a `my.secrets.strictPaths :: bool` (default `true` for new
consumers) that throws in `getPathFun`. At minimum document the `null`
footgun next to every `getPath` example in the README.

### F3 — High: discovery tag semantics are the fleet's deploy gate but are loose, shallow, and eval-invisible
Evidence: `nix/nixos/module.nix:19-72`, `module.nix:160-163,193-197`;
consumers `inframachines/{charon,io,makemake,ariel,sedna}/configuration.nix`
`includeTags`, `infra/vars/generators/*.nix` `meta.tags`,
`infra/lib/secrets-discovery-check.py`.

Specific issues:

1. **Top-level-vs-inner precedence, not union.** `extractTags`
   (`module.nix:34-46`) returns top-level tags *if non-empty, else* inner
   tags. A file with both (e.g. README's `surrealdb.nix` example shape) silently
   drops the inner set. Union would match the documented "both are
   recognized" claim and the check script's union behavior — currently the two
   implementations disagree.
2. **Depth-1 `stripMeta` only** (`module.nix:48-56`). `meta` nested deeper
   than one level inside a generator object passes through to clan. Probably
   harmless today, but the "ensure merged declarations do not leak meta"
   comment over-promises.
3. **Empty `includeTags` means include-all** (`module.nix:66`), so a machine
   that sets `discover.enable = true` and forgets `includeTags` silently
   deploys the whole directory. Fail-closed (require non-empty `includeTags`
   when enabled) would match the fleet's intent.
4. **Merge is last-wins with no conflict detection**
   (`module.nix:199`: `foldl' acc // decl`). Two files declaring the same
   generator name silently overwrite; combined with tag filtering, which file
   wins depends on `readDir` order + include/exclude sets. At least `trace`
   on duplicate generator names.
5. **`defaultDiscoverDir = ./../../vars/generators` (`module.nix:19`) points
   at a path that does not exist in this repo.** It only resolves when the
   *consuming* flake overrides `discover.dir` (infra does via
   `shared.nix:142`). A fresh consumer following the README's "default
   `vars/generators`" will eval-fail or silently discover nothing depending on
   `pathExists` (`module.nix:194`). The default should either be removed
   (require `dir` when `enable`) or documented as "must override".
6. **Raw discovery path skips every constructor invariant** (README admits
   this; production lives there). Discovered generators get no `jq`, no
   manifest, no prompt defaults, no `additionalReaders` capture — so the two
   declaration styles have different feature surfaces with the same merge
   target. `ntfy.nix`-style hand-rolled `$prompts` guards vs. constructor
   `$prompts` setup is the visible seam.

The external check script mitigates (3)–(5) partially but parses tags with
regexes independent of `extractTags`, so the two can drift (see (1)).

### F4 — High: `generateManifest = false` fleet-wide contradicts the manifest-first README; dead code ships to every machine
Evidence: `nix/nixos/module.nix:184-189`, `nix/nixos/lib.nix:84-118`,
`nix/nixos/manifest.nix`; `infra/modules/system/shared.nix:140-143`
(`generateManifest = lib.mkDefault false`), per-machine `generateManifest =
false` (e.g. charon `configuration.nix` secrets block).

The README leads with manifests (auto file, JSON shape, `generateManifest`
only mentioned as an option), yet production disables them everywhere. That
means: every `mk*Secret` call still threads `filesSpec`, `settings`,
`hostName`, `validation`, `meta` through `wrapScript`, `runtimeInputsAll`
still adds `pkgs.jq` unconditionally (`lib.nix:90` — outside the
`generateManifest` branch), and the `manifest.json` file entry is the only
thing toggled. Cost without benefit on all five machines: larger closures,
`jq` in every generator PATH, and wrapper complexity (`lib.nix:92-118`)
exercised only for its no-op branch. It also means the manifest path
(`manifest.nix:1-72`) is untested in production — the one eval test never
toggles it, and no test asserts the `false` branch output equals the raw
script plus prompts shim.

Recommendation: move `pkgs.jq` inside the manifest branch, and either (a)
document the fleet's no-manifest posture as supported/deprecated with a
migration note, or (b) decide manifests are the product and help infra
re-enable them. Either way the README's emphasis should match reality.

### F5 — Medium: `runtimePath` is duplicated between `module.nix` and `acl.nix`; `expose-user.nix` hardcodes a third copy
Evidence: `nix/nixos/module.nix:75-77`, `nix/nixos/acl.nix:7-9`,
`nix/nixos/expose-user.nix:30-35,44-48`, `nix/nixos/manifest.nix:55-58`
(jq-side path reconstruction).

Three spellings of `/run/secrets[-for-users]/vars/<name>/<file>` must agree.
Today they do, but `expose-user.nix` bakes `srcDir`/`srcFile` strings instead
of taking the helper, and `manifest.nix` reconstructs the path in `jq`. A
future `neededFor` rename or third scope breaks them independently with no
shared assertion. Factor one `runtimePath` lib (imported by all four) and
assert equality in the eval test.

### F6 — Medium: `types.raw` + `listOf attrs` erase the API boundary the module exists to enforce
Evidence: `nix/nixos/module.nix:149-182` (all `types.raw`), `declarations ::
listOf attrs`, `discover.dir :: types.path`.

`mk*Secret`, `paths`, `pathsFlat`, `getPath`, `values`, `getValue` are all
`types.raw`/`readOnly`; `declarations` accepts any attrset list. Misspelled
constructor args (`runtimeInput` vs `runtimeInputs`), wrong `files` shapes, or
a declaration returning a function instead of an attrset all fail deep inside
clan eval or at deploy time. The `discover.dir :: types.path` + `pathExists`
guard (`module.nix:194`) further converts a typo'd path into silent
empty-discovery rather than an error. For a helper whose value-add is
"encode invariants once", the option types encode almost none of them.
Recommend: `mkOption type = types.functionTo ...` is awkward in NixOS
options, but `declarations` can at least be `listOf (attrsOf ...)`-checked via
`assertions`, and `discover` can assert `dir` exists when `enable`.

### F7 — Medium: home-manager `wrappedHomeBinaries` is a second product with a different trust model, used once, specified loosely
Evidence: `nix/home/secrets-wrapper.nix:1-98`, `nix/home/module.nix:1-3`,
`infra/machines/ariel/configuration.nix:109-121`,
`infra/modules/home/options.nix:7-12`.

Issues: `wrappedHomeBinaries :: listOf attrs` (`secrets-wrapper.nix:81-84`)
with no per-entry submodule — `name`/`command` are `inherit`d positionally
and fail with unhelpful `attribute missing` errors; `useSystemdRun = false`
(default) embeds `cat ${secretPath}` / `. ${environmentFile}` directly in a
store script (`secrets-wrapper.nix:50-58`), i.e. secrets readable by any local
user that can read the wrapper derivation, whereas `useSystemdRun = true`
correctly uses `LoadCredential`. The secure mode is opt-in and used once
(ariel `mods` wrapper); the insecure default is undocumented as such. The
`osConfig.my.secrets or {}` passthrough (`options.nix:11`) is intentionally
permissive, so HM eval never checks that `secretPath` came from a real
`getPath`. Recommend: submodule type with `assert` on `LoadCredential` paths,
document the `plain` mode's store-visibility tradeoff, default
`useSystemdRun` to `true` or warn when `false` with a secret path.

### F8 — Medium: prompt auto-generation + `recursiveUpdate` merge order can surprise
Evidence: `nix/nixos/lib.nix:64-79`.

`promptsFinal = recursiveUpdate promptsAutoClean prompts` means explicit
`prompts` win (good), but `recursiveUpdate` deep-merges per-file attrsets:
a caller overriding only `prompts.key.description` inherits the auto
`type`/`persist` silently. Combined with the `promptType`-gating rule
(only explicit `promptType` gets an auto entry), a file with a hand-written
`prompts.foo` but no `promptType` keeps exactly what was written, while a
sibling with `promptType` gets defaults — two paths to prompts in one
attrset. The wireguard-tunnels call site (`prompts."conf"` with
`multiline-hidden` intent but no `promptType` on `files."wg.conf"`, relying on
hand-written prompts + placeholder generation) works *because* of this
subtlety. Document the two prompt paths as intentional, or unify on
`promptType` as the single source of truth.

### F9 — Low: `exposeUserSecrets` unit naming + `dest` default + `group` lookup have small collision/robustness gaps
Evidence: `nix/nixos/expose-user.nix:8-30,44-74`.

- `mkServiceName` (`expose-user.nix:8`) interpolates raw
  `user/secretName/file` without sanitization (unlike `acl.nix`'s hashed unit
  names). Two entries differing only in `dest` collide; odd characters in
  names produce invalid unit names.
- `dest` defaults to `""` (`expose-user.nix:53-57,69-73`) with
  `defaultDest` applied in the service body, so `systemd.paths`/`services`
  attribute names can't reflect the real destination. Default the option
  itself (or accept `null`) instead of empty-string-means-default.
- `group="$(id -gn ${user})"` runs at unit runtime (`expose-user.nix:66-68`)
  with unescaped `${es.user}` interpolation; usernames are constrained in
  practice, but `escapeShellArg` the interpolation for consistency with the
  wrapper module.
- `ConditionPathExists = srcFile` (`expose-user.nix:55`) + path-trigger means
  the copy only happens after clan deploys the file; first-boot ordering vs.
  user session creation is untested (no test covers expose-user at all).

### F10 — Low: test suite proves eval, not behavior
Evidence: `nix/tests/eval-test.nix:1-40`, `nix/modules/checks.nix` (reference).

The single `nixos-eval-test` builds one `mkUserSecret` declaration and echoes
one `neededFor`. It does not assert: prompts shape, `manifest.json`
presence/absence per `generateManifest`, `_acl_additionalReaders` round-trip,
`stripMeta`/`extractTags` semantics, `getPath` miss behavior, duplicate
generator merge, `discover` filtering, ACL/expose-user unit generation, or the
home wrapper. Given findings F1–F6 all live in untested logic, the suite's
marginal value is "module imports". The `README.md` "Usage patterns" section
effectively serves as the spec; promote at least the parsing/table cases
(`extractTags` top/inner/both/empty, `stripMeta` depth, `includeTags == []`
include-all, duplicate merge) to eval assertions. Infra's stub
(`tests/lib/secrets-stub.nix`) further means helper regressions surface only
in production deploys, never in `infra/tests/*`.

## Open questions

1. Is `generateManifest` staying `false` in production permanently? If yes,
   should manifests be removed (or moved to an opt-in `my.secrets.manifests`
   dev-tool) rather than carried as dead weight in every generator?
2. Should `additionalReaders` (constructor-captured, JSON sidecar) and
   `allowReadAccess` (manual, plain nouns) converge on one spelling? Today the
   fleet uses `allowReadAccess` almost exclusively; `vaultwarden.nix`'s
   `additionalReaders = ["vaultwarden"]` is the exception that proves the
   sidecar path is exercised once.
3. Who owns tag vocabulary? `includeTags` lists are hand-maintained per
   machine with broad tags (`"b2"`, `"user"`, `"debug"`) that over-include by
   design; is there appetite for namespaced tags (`scope:name`, e.g.
   the README's `"oumuamua"` example) or for asserting `excludeTags` usage?
4. Should `share = true` generators be required to come from discovery (single
   file, all machines see the same source), given the air-exhaust lesson that
   machine-local inline declarations of shared secrets deploy to one machine
   only?
5. Is the home wrapper's `plain` (non-systemd) mode intended for secrets at
   all, or only for non-sensitive `environmentFile`s? The answer determines
   whether F7 is a docs fix or a default-flip.
6. What clan-core version pins the flat prompt format, `validation` scalar
   constraint, and `/run/secrets[-for-users]/vars/` layout this module
   depends on? None is recorded; a clan bump that relaxes the scalar rule
   would obsolete F1's hack, one that changes prompt shape would revive the
   `CHANGELOG.md` incidents.

## Recommendations (in priority order)

1. Add `getPathStrict` (or strict flag) and migrate first-party modules; keep
   `getPath` as the lenient alias. (F2)
2. Fix `extractTags` to union top-level + inner tags; align
   `secrets-discovery-check.py` with the same rule; add eval tests for
   top/inner/both/empty. (F3.1)
3. Decide manifests: either re-enable in prod or remove from the hot path
   (including unconditional `pkgs.jq`). Stop paying for disabled features.
   (F4)
4. Replace the `validation` JSON sidecar with a sibling option or assert +
   document it, including rotation semantics. (F1)
5. Type the seams: submodule for `wrappedHomeBinaries` entries, assertions on
   `declarations` shape and `discover.dir` existence, sanitized + hashed
   expose-user unit names. (F6, F7, F9)
6. Expand `eval-test.nix` from one echo to a table of assertions covering
   prompts, manifests on/off, discovery filtering, path/value helpers, and
   ACL/expose-user unit counts. (F10)
7. Extract shared `runtimePath` and use it in `module.nix`, `acl.nix`,
   `expose-user.nix`, `manifest.nix`. (F5)
