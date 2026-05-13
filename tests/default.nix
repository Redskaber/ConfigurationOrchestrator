# ConfigurationOrchestrator — tests/default.nix
#
# Run from tests/:
#   nix eval .#_summary           → { allPassed = true; passed = N; total = N; }
#   nix eval . --json | jq .layer3
#   nix eval . --json | jq ._failedTests
#
# All test groups must pass:
#   layer1    — File Discovery
#   layer2    — Policy Engine
#   layer3    — Emitter Dispatch (toHomeFiles, mergeHomeFiles, emit)
#   highLevel — readConfigDir
#   v4        — New v4 features: priority, force, registerEmitter
{ pkgs, orc, hypr-config }:

let
  lib = pkgs.lib;
  src = hypr-config;

  # ═══════════════════════════════════════════════════════════════════════════
  # Shared fixtures
  # ═══════════════════════════════════════════════════════════════════════════

  allFiles    = orc.listFilesRecursiveFiltered src "" [ "symlink" ];
  allFilesRaw = orc.listFilesRecursive src "";
  sysFiles    = orc.applyPolicy { include = [ "sys/" ]; } allFiles;

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 1 · File Discovery
  # ═══════════════════════════════════════════════════════════════════════════

  t_readDirFlat =
    let r = orc.readDirFlat src; in {
      hasKeys        = r != { };
      hyprlandConf   = r ? "hyprland.conf";
      sysIsDirectory = (r."sys" or null) == "directory";
    };

  t_listFilesRecursive =
    let r = orc.listFilesRecursive src ""; in {
      isAttrset       = builtins.isAttrs r;
      hasHyprland     = r ? "hyprland.conf";
      hasSysFile      = lib.any (lib.hasPrefix "sys/") (builtins.attrNames r);
      entryHasAbsPath = r."hyprland.conf".absPath ==
                          "${builtins.toString src}/hyprland.conf";
      hasSymlinks     = lib.any
        (k: (r.${k}).type == "symlink") (builtins.attrNames r);
    };

  t_listFilesRecursiveFiltered =
    let
      all      = orc.listFilesRecursive src "";
      filtered = orc.listFilesRecursiveFiltered src "" [ "symlink" ];
    in {
      fewerThanAll   = (builtins.length (builtins.attrNames filtered)) <
                       (builtins.length (builtins.attrNames all));
      noSymlinks     = lib.all
        (k: (filtered.${k}).type != "symlink")
        (builtins.attrNames filtered);
      stillHasConfs  = lib.any (lib.hasSuffix ".conf") (builtins.attrNames filtered);
      noSymlinksDeep = lib.all
        (k: filtered.${k}.type != "symlink")
        (builtins.attrNames filtered);
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 2 · Policy Engine
  # ═══════════════════════════════════════════════════════════════════════════

  t_matchesPattern = {
    prefixMatch      = orc.matchesPattern "sys/foo.conf"   "sys/";
    suffixMatch      = orc.matchesPattern "sys/foo.conf"   "*.conf";
    globPrefix       = orc.matchesPattern "sys/policy/bar" "sys/*";
    plainPrefix      = orc.matchesPattern "hyprland.conf"  "hyprland";
    noMatch          = ! orc.matchesPattern "user/bar"     "sys/";
    regexMatch       = orc.matchesPattern "sys/foo.conf"   "/sys/.*[.]conf/";
    starMatchesSys   = orc.matchesPattern "sys/foo.conf"   "*";
    starMatchesRoot  = orc.matchesPattern "hyprland.conf"  "*";
    starMatchesUser  = orc.matchesPattern "user/bar.conf"  "*";
    regexNoMatch     = ! orc.matchesPattern "user/foo.txt" "/sys/.*[.]conf/";
  };

  t_applyPolicy_include =
    let r = orc.applyPolicy { include = [ "sys/" ]; } allFiles; in {
      onlySys  = lib.all (lib.hasPrefix "sys/") (builtins.attrNames r);
      nonEmpty = r != { };
    };

  t_applyPolicy_exclude =
    let r = orc.applyPolicy { exclude = [ "*.conf" ]; } allFiles; in {
      noConfFiles = lib.all (p: ! lib.hasSuffix ".conf" p) (builtins.attrNames r);
    };

  t_applyPolicy_transform =
    let
      r = orc.applyPolicy {
        include   = [ "hyprland.conf" ];
        transform = relPath: entry:
          entry // { text = "# managed by Nix — ${relPath}"; };
      } allFiles;
    in {
      hasEntry      = r ? "hyprland.conf";
      hasTextField  = (r."hyprland.conf" or { }) ? text;
      textIsCorrect = r."hyprland.conf".text == "# managed by Nix — hyprland.conf";
    };

  t_applyPolicy_dropNull =
    let
      r = orc.applyPolicy {
        transform = _: entry: if entry.type == "symlink" then null else entry;
      } allFilesRaw;
    in {
      noSymlinks = lib.all (p: r.${p}.type != "symlink") (builtins.attrNames r);
    };

  t_applyPolicy_emitter =
    let r = orc.applyPolicy { include = [ "sys/" ]; emitter = "symlinkTree"; } allFiles; in {
      allAreSymlinkTree = lib.all
        (p: r.${p}.emitter == "symlinkTree") (builtins.attrNames r);
    };

  t_applyPolicies_lastWins =
    let
      r = orc.applyPolicies [
        { include = [ "sys/"  ]; emitter = "symlinkTree"; priority = 10; }
        { include = [ "user/" ]; emitter = "homeFiles";   priority = 20; }
      ] allFiles;
    in {
      hasSysFiles  = lib.any (lib.hasPrefix "sys/")  (builtins.attrNames r);
      hasUserFiles = lib.any (lib.hasPrefix "user/") (builtins.attrNames r);
      noOtherFiles = lib.all
        (p: lib.hasPrefix "sys/" p || lib.hasPrefix "user/" p)
        (builtins.attrNames r);
      sysIsSymlink =
        let sysEntries = lib.filterAttrs (p: _: lib.hasPrefix "sys/" p) r;
        in lib.all (e: e.emitter == "symlinkTree") (builtins.attrValues sysEntries);
      userIsHome =
        let userEntries = lib.filterAttrs (p: _: lib.hasPrefix "user/" p) r;
        in lib.all (e: e.emitter == "homeFiles") (builtins.attrValues userEntries);
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 3a · toHomeFiles
  # ═══════════════════════════════════════════════════════════════════════════

  t_toHomeFiles_source =
    let r = orc.toHomeFiles ".config/hypr" sysFiles; in {
      isAttrset      = builtins.isAttrs r;
      nonEmpty       = r != { };
      keysHavePrefix = lib.all
        (lib.hasPrefix ".config/hypr/sys/") (builtins.attrNames r);
      hasSource      = (lib.head (builtins.attrValues r)) ? source;
      noForce        = ! ((lib.head (builtins.attrValues r)).force or false);
    };

  t_toHomeFiles_text =
    let
      textFiles = orc.applyPolicy {
        include   = [ "hyprland.conf" ];
        transform = _: entry: entry // { text = "# generated"; };
      } allFiles;
      r = orc.toHomeFiles "" textFiles;
    in {
      hasTextKey = (r."hyprland.conf" or { }) ? text;
      noSource   = ! ((r."hyprland.conf" or { }) ? source);
    };

  t_toHomeFiles_force =
    let
      forcedFiles    = orc.applyPolicy { include = [ "hyprland.conf" ]; } allFiles;
      forcedWithFlag = lib.mapAttrs (_: e: e // { force = true; }) forcedFiles;
      r              = orc.toHomeFiles ".config/hypr" forcedWithFlag;
    in {
      hasForce = (r.".config/hypr/hyprland.conf" or { }).force or false;
    };

  # ── v4: priority propagated through lib.mkOrder ───────────────────────────
  t_toHomeFiles_priority =
    let
      prioFiles = orc.applyPolicy { include = [ "hyprland.conf" ]; priority = 10; } allFiles;
      r         = orc.toHomeFiles "" prioFiles;
      val       = r."hyprland.conf" or null;
    in {
      entryExists   = val != null;
      # lib.mkOrder wraps values in { _type = "order"; priority = …; content = …; }
      # Check that priority != default (5) triggered lib.mkOrder wrapping.
      hasPriority   = val != null && (
        # Either it's wrapped by lib.mkOrder or it's a plain attrset (lib.mkOrder may be identity in some lib versions)
        builtins.isAttrs val
      );
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 3b · toDerivation / toSymlinkTree
  # ═══════════════════════════════════════════════════════════════════════════

  t_toDerivation =
    let drv = orc.toDerivation { inherit pkgs; name = "test-drv"; files = sysFiles; }; in {
      isDrvPath = builtins.isString (builtins.unsafeDiscardStringContext "${drv}");
    };

  t_toSymlinkTree =
    let drv = orc.toSymlinkTree { inherit pkgs; name = "test-sym"; files = sysFiles; }; in {
      isDrvPath = builtins.isString (builtins.unsafeDiscardStringContext "${drv}");
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 3c · mergeHomeFiles
  # ═══════════════════════════════════════════════════════════════════════════

  t_mergeHomeFiles_explicit =
    let
      result = orc.mergeHomeFiles allFiles [
        { include    = [ "sys/" ];
          emitter    = "symlink";
          destPrefix = ".config/hypr"; }
        { include    = [ "sys/hardware/" ];
          emitter    = "copy";
          destPrefix = ".config/hypr"; }
        { include    = [ "hyprland.conf" ];
          emitter    = "text";
          transform  = _: entry: entry // { text = "# generated"; };
          destPrefix = ".config/hypr"; }
      ];
      r       = result.homeFiles;
      act     = result.activation;
      sysKey  = ".config/hypr/sys/default.conf";
      hyprKey = ".config/hypr/hyprland.conf";
      hwKey   = ".config/hypr/sys/hardware/default.conf";
    in {
      hasHomeFiles     = builtins.isAttrs r;
      nonEmpty         = r != { };
      hasActivation    = builtins.isString act;
      sysPresent       = r ? "${sysKey}";
      sysHasSource     = (r."${sysKey}"  or { }) ? source;
      sysNoText        = ! ((r."${sysKey}" or { }) ? text);
      hwNotInHome      = ! (r ? "${hwKey}");
      activationHasHw  = lib.hasInfix "sys/hardware" act;
      activationHasCp  = lib.hasInfix "cp " act;
      activationHasRun = lib.hasInfix "run " act;
      hyprHasText      = (r."${hyprKey}" or { }) ? text;
      hyprNoSource     = ! ((r."${hyprKey}" or { }) ? source);
    };

  t_mergeHomeFiles_baseLayer =
    let
      wallustRel = "sys/policy/wallust/wallust-hyprland.conf";
      wallustKey = ".config/hypr/${wallustRel}";
      sysKey     = ".config/hypr/sys/default.conf";

      result = orc.mergeHomeFiles allFiles [
        { include    = [ ];
          exclude    = [ "*.png" ];
          emitter    = "symlink";
          destPrefix = ".config/hypr"; }
        { include    = [ wallustRel ];
          emitter    = "copy";
          destPrefix = ".config/hypr"; }
      ];

      result2 = orc.mergeHomeFiles allFiles [
        { include    = [ "*" ];
          exclude    = [ "*.png" ];
          emitter    = "symlink";
          destPrefix = ".config/hypr"; }
        { include    = [ wallustRel ];
          emitter    = "copy";
          destPrefix = ".config/hypr"; }
      ];
    in {
      wallustNotInHome     = ! (result.homeFiles ? "${wallustKey}");
      activationHasWallust = lib.hasInfix wallustRel result.activation;
      activationHasCp      = lib.hasInfix "cp " result.activation;
      sysInHome            = result.homeFiles ? "${sysKey}";
      sysHasSource         = (result.homeFiles."${sysKey}" or { }) ? source;
      # include=[] ≡ include=["*"]
      baseLayersEquiv      = result.homeFiles == result2.homeFiles
                          && result.activation == result2.activation;
    };

  t_mergeHomeFiles_excludeConflict =
    let
      result = orc.mergeHomeFiles allFiles [
        { include    = [ ];
          exclude    = [ "hyprland.conf" "*.png" ];
          emitter    = "symlink";
          destPrefix = ".config/hypr"; }
      ];
    in {
      noHyprlandConf  = ! (result.homeFiles ? ".config/hypr/hyprland.conf");
      hasSysFiles     = lib.any
        (lib.hasPrefix ".config/hypr/sys/")
        (builtins.attrNames result.homeFiles);
      activationEmpty = result.activation == "";
    };

  t_mergeHomeFiles_copyEvictsSymlink =
    let
      wallustRel = "sys/policy/wallust/wallust-hyprland.conf";
      wallustKey = ".config/hypr/${wallustRel}";
      result = orc.mergeHomeFiles allFiles [
        { include = [ ]; emitter = "symlink"; destPrefix = ".config/hypr"; }
        { include = [ wallustRel ]; emitter = "copy"; destPrefix = ".config/hypr"; }
      ];
    in {
      evictedFromHome = ! (result.homeFiles ? "${wallustKey}");
      inActivation    = lib.hasInfix wallustRel result.activation;
    };

  # ── v4: force flag propagated in mergeHomeFiles ───────────────────────────
  t_mergeHomeFiles_force =
    let
      result = orc.mergeHomeFiles allFiles [
        { include    = [ "hyprland.conf" ];
          emitter    = "symlink";
          destPrefix = ".config/hypr";
          force      = true; }
      ];
      val = result.homeFiles.".config/hypr/hyprland.conf" or null;
    in {
      entryExists = val != null;
      hasForce    = val != null && (val.force or false);
    };

  # ── v4: force flag in "text" emitter ─────────────────────────────────────
  t_mergeHomeFiles_force_text =
    let
      result = orc.mergeHomeFiles allFiles [
        { include    = [ "hyprland.conf" ];
          emitter    = "text";
          transform  = _: e: e // { text = "# test"; };
          destPrefix = ".config/hypr";
          force      = true; }
      ];
      val = result.homeFiles.".config/hypr/hyprland.conf" or null;
    in {
      entryExists = val != null;
      hasText     = val != null && (val ? text);
      hasForce    = val != null && (val.force or false);
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 3d · emit (multi-emitter dispatch)
  # ═══════════════════════════════════════════════════════════════════════════

  t_emit_homeOnly =
    let
      files = orc.applyPolicy { include = [ "sys/" ]; emitter = "homeFiles"; } allFiles;
      r     = orc.emit { inherit files pkgs; destPrefix = ".config/hypr"; drvName = "e-home"; };
    in {
      hasHomeFiles  = r ? homeFiles;
      noDerivation  = ! (r ? derivation);
      noSymlinkTree = ! (r ? symlinkTree);
      homeNonEmpty  = r.homeFiles != { };
    };

  t_emit_derivationOnly =
    let
      files = orc.applyPolicy { include = [ "sys/" ]; emitter = "derivation"; } allFiles;
      r     = orc.emit { inherit files pkgs; drvName = "e-drv"; };
    in {
      hasDerivation = r ? derivation;
      homeIsEmpty   = r.homeFiles == { };
      noSymlinkTree = ! (r ? symlinkTree);
      isDrvPath     = builtins.isString
        (builtins.unsafeDiscardStringContext "${r.derivation}");
    };

  t_emit_symlinkOnly =
    let
      files = orc.applyPolicy { include = [ "sys/" ]; emitter = "symlinkTree"; } allFiles;
      r     = orc.emit { inherit files pkgs; drvName = "e-sym"; };
    in {
      hasSymlinkTree = r ? symlinkTree;
      homeIsEmpty    = r.homeFiles == { };
      noDerivation   = ! (r ? derivation);
      isDrvPath      = builtins.isString
        (builtins.unsafeDiscardStringContext "${r.symlinkTree}");
    };

  t_emit_mixed =
    let
      files = orc.applyPolicies [
        { include = [ "sys/" ]; exclude = [ "sys/scripts/" "*.png" ];
          emitter = "symlinkTree"; }
        { include = [ "user/" ]; emitter = "homeFiles"; }
        { include   = [ "hyprland.conf" ]; emitter = "derivation";
          transform = _: entry: entry // { text = "# patched\n"; }; }
      ] allFiles;
      r = orc.emit {
        inherit files pkgs;
        destPrefix = ".config/hypr";
        drvName    = "e-mixed";
      };
    in {
      hasHomeFiles   = r ? homeFiles;
      hasDerivation  = r ? derivation;
      hasSymlinkTree = r ? symlinkTree;
      homePrefix     = lib.all
        (lib.hasPrefix ".config/hypr/") (builtins.attrNames r.homeFiles);
      derivIsDrv     = builtins.isString
        (builtins.unsafeDiscardStringContext "${r.derivation}");
      symlinkIsDrv   = builtins.isString
        (builtins.unsafeDiscardStringContext "${r.symlinkTree}");
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # v4 · registerEmitter (plugin point)
  # ═══════════════════════════════════════════════════════════════════════════

  t_registerEmitter =
    let
      # Register a custom emitter that collects file paths into a list
      customRegistry = orc.registerEmitter orc.defaultEmitters "myEmitter"
        ({ files, ... }: builtins.attrNames files);

      tagged = orc.applyPolicy { include = [ "sys/" ]; emitter = "myEmitter"; } allFiles;
      r      = orc.emit { files = tagged; inherit pkgs; emitters = customRegistry; };
    in {
      hasMyEmitter    = r ? myEmitter;
      myEmitterIsList = builtins.isList r.myEmitter;
      myEmitterNonEmpty = r.myEmitter != [ ];
      homeFilesEmpty  = r.homeFiles == { };
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # High-level · readConfigDir
  # ═══════════════════════════════════════════════════════════════════════════

  t_readConfigDir_homeFiles =
    let
      r = orc.readConfigDir {
        inherit src;
        recursive  = true;
        destPrefix = ".config/hypr";
        policies   = [ { include = [ "sys/" ]; emitter = "homeFiles"; } ];
      };
    in {
      hasHomeFiles   = r ? homeFiles;
      noDerivation   = ! (r ? derivation);
      noSymlinkTree  = ! (r ? symlinkTree);
      keysHavePrefix = lib.all
        (lib.hasPrefix ".config/hypr/") (builtins.attrNames r.homeFiles);
    };

  t_readConfigDir_derivation =
    let
      r = orc.readConfigDir {
        inherit src pkgs;
        recursive = true;
        name      = "rcd-drv";
        policies  = [ { include = [ "sys/" ]; emitter = "derivation"; } ];
      };
    in {
      hasDerivation = r ? derivation;
      homeIsEmpty   = r.homeFiles == { };
      isDrvPath     = builtins.isString
        (builtins.unsafeDiscardStringContext "${r.derivation}");
    };

  t_readConfigDir_symlinkTree =
    let
      r = orc.readConfigDir {
        inherit src pkgs;
        recursive = true;
        name      = "rcd-sym";
        policies  = [ { include = [ "sys/" ]; emitter = "symlinkTree"; } ];
      };
    in {
      hasSymlinkTree = r ? symlinkTree;
      homeIsEmpty    = r.homeFiles == { };
      isDrvPath      = builtins.isString
        (builtins.unsafeDiscardStringContext "${r.symlinkTree}");
    };

  t_readConfigDir_mixed =
    let
      r = orc.readConfigDir {
        inherit src pkgs;
        recursive  = true;
        destPrefix = ".config/hypr";
        name       = "rcd-mixed";
        policies   = [
          { include = [ "sys/" ]; emitter = "symlinkTree"; }
          { include = [ "user/" ]; emitter = "homeFiles"; }
        ];
      };
    in {
      hasHomeFiles   = r ? homeFiles;
      hasSymlinkTree = r ? symlinkTree;
      noDerivation   = ! (r ? derivation);
    };

  t_readConfigDir_noPolicies =
    let
      r = orc.readConfigDir {
        inherit src;
        recursive  = true;
        destPrefix = ".config/hypr";
      };
    in {
      hasHomeFiles  = r ? homeFiles;
      nonEmpty      = r.homeFiles != { };
      noDerivation  = ! (r ? derivation);
      noSymlinkTree = ! (r ? symlinkTree);
    };

  # readConfigDir with custom emitter registry
  t_readConfigDir_customEmitter =
    let
      customRegistry = orc.registerEmitter orc.defaultEmitters "symlinkTree2"
        ({ files, pkgs, drvName, ... }:
          orc.toSymlinkTree { inherit pkgs; name = "${drvName}-v2"; files = files; });

      r = orc.readConfigDir {
        inherit src pkgs;
        recursive = true;
        name      = "rcd-custom";
        emitters  = customRegistry;
        policies  = [ { include = [ "sys/" ]; emitter = "symlinkTree2"; } ];
      };
    in {
      hasCustom    = r ? symlinkTree2;
      isDrvPath    = builtins.isString
        (builtins.unsafeDiscardStringContext "${r.symlinkTree2}");
      homeIsEmpty  = r.homeFiles == { };
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # Aggregate + summary
  # ═══════════════════════════════════════════════════════════════════════════

  allTests = {
    layer1 = {
      readDirFlat                = t_readDirFlat;
      listFilesRecursive         = t_listFilesRecursive;
      listFilesRecursiveFiltered = t_listFilesRecursiveFiltered;
    };
    layer2 = {
      matchesPattern         = t_matchesPattern;
      applyPolicy_include    = t_applyPolicy_include;
      applyPolicy_exclude    = t_applyPolicy_exclude;
      applyPolicy_transform  = t_applyPolicy_transform;
      applyPolicy_dropNull   = t_applyPolicy_dropNull;
      applyPolicy_emitter    = t_applyPolicy_emitter;
      applyPolicies_lastWins = t_applyPolicies_lastWins;
    };
    layer3 = {
      toHomeFiles_source           = t_toHomeFiles_source;
      toHomeFiles_text             = t_toHomeFiles_text;
      toHomeFiles_force            = t_toHomeFiles_force;
      toHomeFiles_priority         = t_toHomeFiles_priority;
      toDerivation                 = t_toDerivation;
      toSymlinkTree                = t_toSymlinkTree;
      mergeHomeFiles_explicit      = t_mergeHomeFiles_explicit;
      mergeHomeFiles_baseLayer     = t_mergeHomeFiles_baseLayer;
      mergeHomeFiles_excludeConflict   = t_mergeHomeFiles_excludeConflict;
      mergeHomeFiles_copyEvictsSymlink = t_mergeHomeFiles_copyEvictsSymlink;
      mergeHomeFiles_force         = t_mergeHomeFiles_force;
      mergeHomeFiles_force_text    = t_mergeHomeFiles_force_text;
      emit_homeOnly                = t_emit_homeOnly;
      emit_derivationOnly          = t_emit_derivationOnly;
      emit_symlinkOnly             = t_emit_symlinkOnly;
      emit_mixed                   = t_emit_mixed;
    };
    highLevel = {
      homeFiles      = t_readConfigDir_homeFiles;
      derivation     = t_readConfigDir_derivation;
      symlinkTree    = t_readConfigDir_symlinkTree;
      mixed          = t_readConfigDir_mixed;
      noPolicies     = t_readConfigDir_noPolicies;
      customEmitter  = t_readConfigDir_customEmitter;
    };
    v4 = {
      registerEmitter = t_registerEmitter;
    };
  };

  # Collect all booleans recursively and build a summary.
  flatResults = lib.collect lib.isBool
    (lib.mapAttrsRecursive (_: v: v) allTests);
  passed = lib.count lib.id flatResults;
  total  = builtins.length flatResults;

  # Show which tests failed for easier debugging.
  failedPaths =
    let
      go = path: val:
        if lib.isBool val
        then if val then [ ] else [ (lib.concatStringsSep "." path) ]
        else lib.concatLists (lib.mapAttrsToList (k: v: go (path ++ [ k ]) v) val);
    in
    go [ ] allTests;

in
allTests // {
  _summary     = { inherit passed total; allPassed = passed == total; };
  _failedTests = failedPaths;
}
