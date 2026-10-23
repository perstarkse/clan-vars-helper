# Shared runtime path for deployed vars files.
# Single source of truth for /run/secrets[-for-users]/vars/<rel_dir>/<file>;
# imported by module.nix, acl.nix and expose-user.nix so code and docs
# cannot drift (manifest.nix reconstructs the same path in jq).
#
# `relDir` is clan-core's generator `rel_dir`: "shared/<gen>" for shared
# generators and "per-machine/<machine>/<gen>" otherwise. clan-core nests
# deployed vars under it, so the old flat "<gen>" layout no longer exists.
relDir: file: neededFor:
let suffix = if neededFor == "users" then "-for-users" else "";
in "/run/secrets${suffix}/vars/${relDir}/${file}"
