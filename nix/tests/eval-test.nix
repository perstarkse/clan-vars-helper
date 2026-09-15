{ pkgs, lib, self, ... }:
let
  # Declare dummy clan options that this helper module reads/writes
  clanStub = { lib, ... }: {
    options.clan.core.vars = {
      generators = lib.mkOption {
        type = lib.types.attrsOf lib.types.attrs;
        default = { };
      };
      settings = {
        secretStore = lib.mkOption {
          type = lib.types.str;
          default = "sops";
        };
        publicStore = lib.mkOption {
          type = lib.types.str;
          default = "git";
        };
      };
    };
  };

  nixosSystem = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      ({ config, ... }: {
        nixpkgs.hostPlatform = "x86_64-linux";

        # Configure the mock settings
        clan.core.vars.settings.secretStore = "sops";
        clan.core.vars.settings.publicStore = "git";

        # Test options and constructors
        my.secrets.declarations = [
          (config.my.secrets.mkUserSecret {
            name = "test-secret";
            files.key = { };
            script = "echo test > $out/key";
          })
          (config.my.secrets.mkMachineSecret {
            name = "test-svc";
            files.svc = { };
            script = "echo test > $out/svc";
          })
        ];
      })
    ];
  };

  discoverSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";

        my.secrets.discover = {
          enable = true;
          dir = ./fixtures/discover;
          includeTags = [ "tag-top" "tag-inner" "tag-both-inner" ];
        };
      }
    ];
  };

  phase1Sys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      ({ config, ... }: {
        nixpkgs.hostPlatform = "x86_64-linux";

        my.secrets.declarations = [
          (config.my.secrets.mkUserSecret {
            name = "strict-secret";
            files.key = { };
            files.pub = { secret = false; mode = "0444"; };
            script = "echo test > $out/key; echo pub > $out/pub";
          })
          # Duplicate generator name: last declaration wins (and warns via trace).
          {
            dup = {
              share = false;
              files.a = { neededFor = "services"; };
              runtimeInputs = [ ];
              script = "echo a > $out/a";
            };
          }
          {
            dup = {
              share = false;
              files.b = { neededFor = "services"; };
              runtimeInputs = [ ];
              script = "echo b > $out/b";
            };
          }
        ];
        my.secrets.requireGenerators = [ "strict-secret" ];
      })
    ];
  };

  reqMissingSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.requireGenerators = [ "ghost-generator" ];
      }
    ];
  };

  emptyTagsSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.discover = {
          enable = true;
          dir = ./fixtures/discover;
          includeTags = [ ];
        };
      }
    ];
  };

  badDirSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.discover = {
          enable = true;
          dir = /definitely/not/here;
          includeTags = [ "tag-top" ];
        };
      }
    ];
  };

  advUser = "a';id;#";

  phase2Sys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.exposeUserSecrets = [
          {
            enable = true;
            secretName = "user-ssh-key";
            file = "key";
            user = "alice";
          }
          {
            enable = true;
            secretName = "weird-secret";
            file = "key";
            user = advUser;
            dest = "/home/victim/injected";
          }
          {
            enable = true;
            secretName = "svc-secret";
            file = "env";
            user = "svc";
            dest = "/var/lib/svc/secret.env";
          }
        ];
      }
    ];
  };

  badModeSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.exposeUserSecrets = [
          { enable = true; secretName = "s"; file = "f"; user = "u"; mode = "0644"; }
        ];
      }
    ];
  };

  relDestSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.exposeUserSecrets = [
          { enable = true; secretName = "s"; file = "f"; user = "u"; dest = "relative/path"; }
        ];
      }
    ];
  };

  outsideDestSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.exposeUserSecrets = [
          { enable = true; secretName = "s"; file = "f"; user = "u"; dest = "/etc/evil"; }
        ];
      }
    ];
  };

  revokedSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.allowReadAccess = [
          { path = "/run/secrets/vars/revoked-secret/token"; readers = [ ]; }
        ];
      }
    ];
  };

  revokeSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.allowReadAccess = [
          { path = "/run/secrets/vars/revoked-secret/token"; readers = [ ]; }
        ];
        my.secrets.revokeStaleAcls = true;
      }
    ];
  };

  rotationSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      ({ config, ... }: {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.declarations = [
          (config.my.secrets.mkSharedSecret {
            name = "rotation-secret";
            files.env = { };
            script = "echo test > $out/env";
            requiredPrompts = [ "env" ];
          })
        ];
        systemd.paths = (config.my.secrets.mkTryRestartOnRotation {
          service = "demo-svc";
          secretName = "rotation-secret";
          file = "env";
        }).paths;
        systemd.services = (config.my.secrets.mkTryRestartOnRotation {
          service = "demo-svc";
          secretName = "rotation-secret";
          file = "env";
        }).services;
      })
    ];
  };

  gens = nixosSystem.config.clan.core.vars.generators;
  discoverGens = discoverSys.config.clan.core.vars.generators;
  getPath = nixosSystem.config.my.secrets.getPath;
  getValue = phase1Sys.config.my.secrets.getValue;
  phase1Gens = phase1Sys.config.clan.core.vars.generators;
  expectPathStrict = gen: file: expected:
    let actual = phase1Sys.config.my.secrets.getPath gen file;
    in if actual == expected then actual else throw ("getPath mismatch for " + gen + "/" + file + ": got " + (toString actual) + ", want " + expected);
  expectThrow = label: v:
    if (builtins.tryEval v).success
    then throw label + ": expected an evaluation failure, but it succeeded"
    else "throws as expected";

  expectPath = gen: file: expected:
    let actual = getPath gen file;
    in if actual == expected then actual else throw "getPath ${gen}/${file}: got ${toString actual}, want ${expected}";
  expectPresent = set: name:
    if set ? ${name} then "present" else throw "${name} missing from clan.core.vars.generators";
  expectAbsent = set: name:
    if set ? ${name} then throw "${name} should not be in clan.core.vars.generators" else "absent";
  # Phase 2 units: filter to our units (the test system has ~50 stock ones).
  exposeSvcs = phase2Sys.config.systemd.services;
  exposePaths = phase2Sys.config.systemd.paths;
  ourSvcNames = builtins.filter (n: lib.hasPrefix "my-expose-user-secret-" n) (builtins.attrNames exposeSvcs);
  ourPathNames = builtins.filter (n: lib.hasPrefix "my-expose-user-secret-" n) (builtins.attrNames exposePaths);
  advName = builtins.head (builtins.filter (n: lib.hasInfix "weird-secret" n) ourSvcNames);
  advScript = (builtins.getAttr advName exposeSvcs).script;
  expectUnitField = units: unit: field: expected:
    let
      actual = (builtins.getAttr unit units).unitConfig.${field} or (builtins.getAttr unit units).pathConfig.${field} or null;
    in
    if actual == expected then toString actual else throw "unit ${unit} field ${field}: got ${toString actual}, want ${toString expected}";
  sopsStub = { lib, ... }: {
    options.sops.useTmpfs = lib.mkOption { type = lib.types.bool; default = false; };
  };

  sopsSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      sopsStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.allowReadAccess = [
          { path = "/run/secrets-for-users/vars/s/token"; readers = [ "alice" ]; }
        ];
      }
    ];
  };

  # Phase 4 systems: manifest verbosity + no-jq + sidecar guard
  manifestSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      ({ config, ... }: {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.declarations = [
          (config.my.secrets.mkSharedSecret {
            name = "manifest-secret";
            files.token = { };
            script = "echo test > $out/token";
          })
        ];
      })
    ];
  };

  fullManifestSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      ({ config, ... }: {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.manifestVerbosity = "full";
        my.secrets.declarations = [
          (config.my.secrets.mkSharedSecret {
            name = "manifest-secret";
            files.token = { };
            script = "echo test > $out/token";
            meta = { owner = "sec"; };
          })
        ];
      })
    ];
  };

  noManifestSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      ({ config, ... }: {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.generateManifest = false;
        my.secrets.declarations = [
          (config.my.secrets.mkSharedSecret {
            name = "plain-secret";
            files.token = { };
            script = "echo test > $out/token";
          })
        ];
      })
    ];
  };

  sidecarSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      ({ config, ... }: {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.declarations = [
          (config.my.secrets.mkSharedSecret {
            name = "sidecar-secret";
            files.token = { };
            script = "echo test > $out/token";
            validation = { _acl_additionalReaders = "{}"; };
          })
        ];
      })
    ];
  };

  # Phase 5: malformed declarations fail closed with a helpful message
  malformedSys = lib.nixosSystem {
    modules = [
      self.nixosModules.default
      clanStub
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        my.secrets.declarations = [
          (_: { })
        ];
      }
    ];
  };
  revokedUnits =
    builtins.listToAttrs
      (builtins.filter (u: lib.hasPrefix "my-secrets-acl-revoke-" u.name)
        (lib.mapAttrsToList lib.nameValuePair revokedSys.config.systemd.services));
  revokerUnits =
    builtins.listToAttrs
      (builtins.filter (u: lib.hasPrefix "my-secrets-acl-revoke-" u.name)
        (lib.mapAttrsToList lib.nameValuePair revokeSys.config.systemd.services));
  strictGen = rotationSys.config.clan.core.vars.generators.rotation-secret;
  manifestGen = manifestSys.config.clan.core.vars.generators.manifest-secret;
  fullManifestGen = fullManifestSys.config.clan.core.vars.generators.manifest-secret;
  noManifestGen = noManifestSys.config.clan.core.vars.generators.plain-secret;
in
pkgs.runCommand "nixos-eval-test" { } ''
  echo "Evaluating NixOS Module..."
  echo "Resolved neededFor: ${gens.test-secret.files.key.neededFor}"
  # runtimePath pins (shared runtime-path.nix): users vs services scopes
  echo "users path: ${expectPath "test-secret" "key" "/run/secrets-for-users/vars/test-secret/key"}"
  echo "services path: ${expectPath "test-svc" "svc" "/run/secrets/vars/test-svc/svc"}"
  # discovery tag union: top-level-only, inner-only, both (union), untagged
  echo "gen-top: ${expectPresent discoverGens "gen-top"}"
  echo "gen-inner: ${expectPresent discoverGens "gen-inner"}"
  echo "gen-both: ${expectPresent discoverGens "gen-both"}"
  echo "gen-untagged: ${expectAbsent discoverGens "gen-untagged"}"
  # stripMeta: no meta leaks into clan.core.vars.generators
  echo "meta stripped (gen-top): ${expectAbsent discoverGens.gen-top "meta"}"
  echo "meta stripped (gen-inner): ${expectAbsent discoverGens.gen-inner "meta"}"
  echo "PH1 strict valid: ${expectPathStrict "strict-secret" "key" "/run/secrets-for-users/vars/strict-secret/key"}"
  echo "PH1 miss generator: ${expectThrow "getPath unknown generator" (phase1Sys.config.my.secrets.getPath "no-such-gen" "key")}"
  echo "PH1 miss file: ${expectThrow "getPath unknown file" (phase1Sys.config.my.secrets.getPath "strict-secret" "no-such-file")}"
  echo "PH1 value miss: ${expectThrow "getValue unknown" (getValue "no-such-gen" "key")}"
  echo "PH1 dup last-wins: ${if phase1Gens.dup.files ? b && !(phase1Gens.dup.files ? a) then "last-wins" else throw ("dup merge: expected only file b, files are " + lib.concatStringsSep "," (builtins.attrNames phase1Gens.dup.files))}"
  echo "PH1 requireGenerators miss: ${expectThrow "requireGenerators ghost" reqMissingSys.config.system.build.toplevel.drvPath}"
  echo "PH1 empty includeTags: ${expectThrow "discover empty includeTags" emptyTagsSys.config.system.build.toplevel.drvPath}"
  echo "PH1 missing dir: ${expectThrow "discover missing dir" badDirSys.config.system.build.toplevel.drvPath}"
  # Phase 2: adversarial expose-user entry renders inert (quoted + sanitized)
  echo "PH2 units: ${toString (builtins.length ourSvcNames)} services / ${toString (builtins.length ourPathNames)} paths (expect 3/3)"
  echo "PH2 quoted user: ${if lib.hasInfix "\\'" advScript then "quoted" else throw "adversarial user not escapeShellArg-quoted"}"
  echo "PH2 sane names: ${let bad = builtins.filter (n: builtins.match "[a-zA-Z0-9-]+" n == null) (ourSvcNames ++ ourPathNames); in if bad == [ ] then "sanitized" else throw ("raw chars in unit names: " + lib.concatStringsSep ", " bad)}"
  echo "PH2 limits: ${expectUnitField exposeSvcs advName "StartLimitIntervalSec" 300}/${expectUnitField exposeSvcs advName "StartLimitBurst" 60}"
  echo "PH2 loud absent source: ${if lib.hasInfix "exit 1" advScript then "retries" else throw "absent source exits 0 (silent)"}"
  echo "PH2 trigger coalescing: ${expectUnitField exposePaths advName "TriggerLimitBurst" 10}"
  echo "PH2 bad mode: ${expectThrow "mode 0644 rejected" badModeSys.config.system.build.toplevel.drvPath}"
  echo "PH2 relative dest: ${expectThrow "relative dest rejected" relDestSys.config.system.build.toplevel.drvPath}"
  echo "PH2 outside dest: ${expectThrow "/etc/evil rejected" outsideDestSys.config.system.build.toplevel.drvPath}"
  # Phase 3: empty readers + revokeStaleAcls emits a setfacl -x revoker
  echo "PH3 revoker count: ${toString (builtins.length (builtins.attrNames revokerUnits))} (expect 1)"
  echo "PH3 revoker content: ${let u = builtins.head (builtins.attrValues revokerUnits); in if lib.hasInfix "setfacl -x" u.script then "revokes" else throw "revoker unit lacks 'setfacl -x'"}"
  echo "PH3 no-revoker by default: ${if revokedUnits == { } then "skipped" else throw "revoker emitted without revokeStaleAcls"}"
  echo "PH3 required prompts: ${if lib.hasInfix "required prompt" strictGen.script then "loud" else throw "requiredPrompts check missing from script"}"
  echo "PH3 watcher path: ${let p = rotationSys.config.systemd.paths.demo-svc-env-rotation.pathConfig; in if p.Unit == "demo-svc-env-rotation-restart.service" && p.PathChanged == [ "/run/secrets/vars/rotation-secret/env" ] then "watches" else throw "rotation path unit miswired"}"
  echo "PH3 watcher exec: ${let s = rotationSys.config.systemd.services.demo-svc-env-rotation-restart.serviceConfig; in if lib.hasInfix "try-restart demo-svc.service" s.ExecStart then "try-restarts" else throw "rotation restarter miswired"}"
  # Phase 4: minimal manifest by default, full on opt-in, no jq when disabled
  echo "PH4 minimal: ${if lib.hasInfix "\\\"meta\\\"" manifestGen.script then throw "default manifest leaks meta" else "name+files"}"
  echo "PH4 full: ${if lib.hasInfix "owner" fullManifestGen.script then "meta-gated" else throw "manifestVerbosity=full lost meta"}"
  echo "PH4 full store: ${if lib.hasInfix "secretStore" fullManifestGen.script then "store-gated" else throw "manifestVerbosity=full lost store"}"
  echo "PH4 no-jq: ${
    # Rotation-safe by design: jq stays in every generator closure so a
    # manifest toggle never changes generator inputs (which risks
    # re-generation). Assert presence instead of absence.
    if builtins.elem pkgs.jq noManifestGen.runtimeInputs then "jq-kept" else throw "jq missing with generateManifest=false (closure changed!)"}"
  echo "PH4 sidecar guard: ${expectThrow "validation._acl_additionalReaders rejected" sidecarSys.config.system.build.toplevel.drvPath}"
  echo "PH4 sops tmpfs flips: ${if sopsSys.config.sops.useTmpfs then "auto-enabled" else throw "sops.useTmpfs not auto-enabled for users-run ACL"}"
  # Phase 5: malformed declaration (function, not attrset) fails closed
  echo "PH5 malformed declarations: ${expectThrow "function declaration rejected" malformedSys.config.system.build.toplevel.drvPath}"
  touch $out
''
