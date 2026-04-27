# test/default.nix
# Run from test/:  nix eval .#_summary
#                  nix eval . --json | jq .layer3
{ pkgs, orc, hypr-config }:

let
  lib = pkgs.lib;
  src = hypr-config;   # test fixture — not a library dependency

  # ─────────────────────────────────────────────────────────────────────────
  # Layer 1 · File Discovery
  # ─────────────────────────────────────────────────────────────────────────

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
      # hypr-config root contains symlinks (hypridle.conf → sys/hypridle.conf)
      hasSymlinks     = lib.any
        (k: (r.${k}).type == "symlink") (builtins.attrNames r);
    };

  # listFilesRecursiveFiltered drops symlinks at discovery time
  t_listFilesRecursiveFiltered =
    let
      all      = orc.listFilesRecursive src "";
      filtered = orc.listFilesRecursiveFiltered src "" [ "symlink" ];
    in {
      fewerThanAll  = (builtins.length (builtins.attrNames filtered)) <
                      (builtins.length (builtins.attrNames all));
      noSymlinks    = lib.all
        (k: (filtered.${k}).type != "symlink")
        (builtins.attrNames filtered);
      stillHasConfs = lib.any (lib.hasSuffix ".conf") (builtins.attrNames filtered);
    };

  # ─────────────────────────────────────────────────────────────────────────
  # Layer 2 · Policy Engine
  # ─────────────────────────────────────────────────────────────────────────

  # Use filtered files as base — avoids symlink-aliased duplicates in tests
  allFiles     = orc.listFilesRecursiveFiltered src "" [ "symlink" ];
  allFilesRaw  = orc.listFilesRecursive src "";   # includes symlinks

  t_matchesPattern = {
    prefixMatch   = orc.matchesPattern "sys/foo.conf"   "sys/";
    suffixMatch   = orc.matchesPattern "sys/foo.conf"   "*.conf";
    globPrefix    = orc.matchesPattern "sys/policy/bar" "sys/*";
    exactPrefix   = orc.matchesPattern "hyprland.conf"  "hyprland";
    noMatch       = ! orc.matchesPattern "user/bar"     "sys/";
    regexMatch    = orc.matchesPattern "sys/foo.conf"   "/sys/.*[.]conf/";
    # Universal wildcard
    starMatchesSys  = orc.matchesPattern "sys/foo.conf"   "*";
    starMatchesRoot = orc.matchesPattern "hyprland.conf"  "*";
    starMatchesUser = orc.matchesPattern "user/bar.conf"  "*";
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

  # Last-wins: sys/→symlinkTree, user/→homeFiles; no overlap → both survive
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
        let sysFiles = lib.filterAttrs (p: _: lib.hasPrefix "sys/" p) r;
        in lib.all (e: e.emitter == "symlinkTree") (builtins.attrValues sysFiles);
      userIsHome   =
        let userFiles = lib.filterAttrs (p: _: lib.hasPrefix "user/" p) r;
        in lib.all (e: e.emitter == "homeFiles") (builtins.attrValues userFiles);
    };

  # ─────────────────────────────────────────────────────────────────────────
  # Layer 3a · toHomeFiles
  # ─────────────────────────────────────────────────────────────────────────

  sysFiles = orc.applyPolicy { include = [ "sys/" ]; } allFiles;

  t_toHomeFiles_source =
    let r = orc.toHomeFiles ".config/hypr" sysFiles; in {
      isAttrset      = builtins.isAttrs r;
      nonEmpty       = r != { };
      keysHavePrefix = lib.all
        (lib.hasPrefix ".config/hypr/sys/") (builtins.attrNames r);
      hasSource = (lib.head (builtins.attrValues r)) ? source;
      # plain homeFiles entries have no force — force is opt-in
      noForce   = ! ((lib.head (builtins.attrValues r)).force or false);
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

  # ─────────────────────────────────────────────────────────────────────────
  # Layer 3b · toDerivation / toSymlinkTree
  # ─────────────────────────────────────────────────────────────────────────

  t_toDerivation =
    let drv = orc.toDerivation { inherit pkgs; name = "test-drv"; files = sysFiles; }; in {
      isDrvPath = builtins.isString (builtins.unsafeDiscardStringContext "${drv}");
    };

  t_toSymlinkTree =
    let drv = orc.toSymlinkTree { inherit pkgs; name = "test-sym"; files = sysFiles; }; in {
      isDrvPath = builtins.isString (builtins.unsafeDiscardStringContext "${drv}");
    };

  # ─────────────────────────────────────────────────────────────────────────
  # Layer 3c · mergeHomeFiles
  # mergeHomeFiles now returns { homeFiles; activation; }
  # homeFiles  → home.file attrset (symlink and text entries)
  # activation → shell script string (copy entries, run in home.activation)
  # ─────────────────────────────────────────────────────────────────────────

  # Scenario A: explicit per-directory policies
  t_mergeHomeFiles_explicit =
    let
      result = orc.mergeHomeFiles allFiles [
        { include    = [ "sys/" ];
          emitter    = "symlink";
          destPrefix = ".config/hypr"; }
        { include    = [ "sys/hardware/" ];
          emitter    = "copy";           # → activation script cp, not homeFiles
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
      hasHomeFiles  = builtins.isAttrs r;
      nonEmpty      = r != { };
      hasActivation = builtins.isString act;
      # "symlink" entries go into homeFiles
      sysPresent    = r ? "${sysKey}";
      sysHasSource  = (r."${sysKey}"  or { }) ? source;
      sysNoText     = ! ((r."${sysKey}" or { }) ? text);
      # "copy" entries go into activation script, NOT homeFiles
      hwNotInHome   = ! (r ? "${hwKey}");
      activationHasHw = lib.hasInfix "sys/hardware" act;
      # "text" entries go into homeFiles
      hyprHasText   = (r."${hyprKey}" or { }) ? text;
      hyprNoSource  = ! ((r."${hyprKey}" or { }) ? source);
    };

  # Scenario B: base-layer + point-override (the recommended idiom)
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
        # wallust writes at runtime → cp in activation, real writable file
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
      # wallust → activation script (real writable file after switch)
      wallustNotInHome    = ! (result.homeFiles ? "${wallustKey}");
      activationHasWallust = lib.hasInfix wallustRel result.activation;
      activationHasCp      = lib.hasInfix "cp " result.activation;
      # everything else → homeFiles as symlinks
      sysInHome     = result.homeFiles ? "${sysKey}";
      sysHasSource  = (result.homeFiles."${sysKey}" or { }) ? source;
      # include=[] ≡ include=["*"]
      baseLayersEquiv = result.homeFiles == result2.homeFiles
                     && result.activation == result2.activation;
    };

  # Scenario C: exclude hyprland.conf
  t_mergeHomeFiles_excludeConflict =
    let
      result = orc.mergeHomeFiles allFiles [
        { include    = [ ];
          exclude    = [ "hyprland.conf" "*.png" ];
          emitter    = "symlink";
          destPrefix = ".config/hypr"; }
      ];
    in {
      noHyprlandConf = ! (result.homeFiles ? ".config/hypr/hyprland.conf");
      hasSysFiles    = lib.any
        (lib.hasPrefix ".config/hypr/sys/")
        (builtins.attrNames result.homeFiles);
      activationEmpty = result.activation == "";
    };

  # ─────────────────────────────────────────────────────────────────────────
  # Layer 3d · emit (multi-emitter dispatch)
  # ─────────────────────────────────────────────────────────────────────────

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

  # ─────────────────────────────────────────────────────────────────────────
  # High-level · readConfigDir
  # ─────────────────────────────────────────────────────────────────────────

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

  # ─────────────────────────────────────────────────────────────────────────
  # Aggregate
  # ─────────────────────────────────────────────────────────────────────────

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
      toHomeFiles_source      = t_toHomeFiles_source;
      toHomeFiles_text        = t_toHomeFiles_text;
      toDerivation            = t_toDerivation;
      toSymlinkTree           = t_toSymlinkTree;
      mergeHomeFiles_explicit = t_mergeHomeFiles_explicit;
      mergeHomeFiles_baseLayer    = t_mergeHomeFiles_baseLayer;
      mergeHomeFiles_excludeConflict = t_mergeHomeFiles_excludeConflict;
      emit_homeOnly           = t_emit_homeOnly;
      emit_derivationOnly     = t_emit_derivationOnly;
      emit_symlinkOnly        = t_emit_symlinkOnly;
      emit_mixed              = t_emit_mixed;
    };
    highLevel = {
      homeFiles   = t_readConfigDir_homeFiles;
      derivation  = t_readConfigDir_derivation;
      symlinkTree = t_readConfigDir_symlinkTree;
      mixed       = t_readConfigDir_mixed;
    };
  };

  flatResults = lib.collect lib.isBool
    (lib.mapAttrsRecursive (_: v: v) allTests);
  passed = lib.count lib.id flatResults;
  total  = builtins.length flatResults;

in
allTests // {
  _summary = { inherit passed total; allPassed = passed == total; };
}
