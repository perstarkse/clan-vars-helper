{ lib, pkgs }:
let
  json = lib.generators.toJSON {};
  jq = lib.getExe pkgs.jq;
  defaultGroup = "root";
  ensureStr = x: if builtins.isString x then x else toString x;
in
{
  wrapScript = args:
    let
      filesArr = lib.mapAttrsToList (fname: fcfg: {
        name = fname;
        secret = fcfg.secret or true;
        owner = ensureStr (fcfg.owner or "root");
        group = ensureStr (fcfg.group or defaultGroup);
        mode = fcfg.mode or "0400";
        neededFor = fcfg.neededFor or args.defaultNeededFor;
        description = fcfg.description or null;
      }) args.filesSpec;

      manifestObj = {
        name = args.name;
        scope = args.scope;
        share = args.share;
        neededFor = args.defaultNeededFor;
        store = {
          secretStore = args.settings.secretStore;
          publicStore = args.settings.publicStore;
        };
        meta = args.meta or {};
        validation = args.validation or null;
        derivation = {
          dependencies = args.dependencies or [];
          hostname = args.hostName;
          generatedAt = null;
        };
        files = builtins.map (f: {
          inherit (f) name secret owner group mode description neededFor;
          path = null;
        }) filesArr;
      };
      manifestJSONStatic = json manifestObj;
      post = ''
        set -euo pipefail
        gen_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        tmp_manifest="$(mktemp)"
        mkdir -p "$out"
        cat >"$tmp_manifest" <<'EOF'
${manifestJSONStatic}
EOF
        ${jq} '
          .derivation.generatedAt = $ts
          | .files = (.files | map(.path = ("/run/secrets" + (if .neededFor == "users" then "-for-users" else "") + "/${args.name}/" + .name)))
        ' --arg ts "$gen_ts" "$tmp_manifest" > "$out/manifest.json"
        rm -f "$tmp_manifest"
      '';
    in
    ''
      set -euo pipefail
      ${args.userScript}
      ${post}
    '';
} 