# Shared runtime path for deployed vars files.
# Single source of truth for /run/secrets[-for-users]/vars/<name>/<file>;
# imported by module.nix, acl.nix and expose-user.nix so code and docs
# cannot drift (manifest.nix reconstructs the same path in jq).
name: file: neededFor:
let suffix = if neededFor == "users" then "-for-users" else "";
in "/run/secrets${suffix}/vars/${name}/${file}"
