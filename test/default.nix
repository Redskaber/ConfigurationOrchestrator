# test/default.nix — ConfigurationOrchestrator test suite
#
# Called by test/flake.nix as:
#   import ./default.nix { inherit pkgs hypr-config orc; }
#
# Run from test/:
#   nix eval .#_summary
#   nix eval . --json | jq .
{ pkgs, hypr-config, orc }:

let
  lib = pkgs.lib;
  src = hypr-config;   # test fixture only — not a library dependency

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
      entryHasAbsPath = r."hyprland.conf".absPath == "${src}/hyprland.conf";
    };

  # ─────────────────────────────────────────────────────────────────────────
  # Layer 2 · Policy Engine
  # ─────────────────────────────────────────────────────────────────────────

  allFiles = orc.listFilesRecursive src "";

  t_matchesPattern = {
    prefixMatch = orc.matchesPattern "sys/foo.conf"   "sys/";
    suffixMatch = orc.matchesPattern "sys/foo.conf"   "*.conf";
    globPrefix  = orc.matchesPattern "sys/policy/bar" "sys/*";
    exactPrefix = orc.matchesPattern "hyprland.conf"  "hyprland";
    noMatch     = ! orc.matchesPattern "user/bar"     "sys/";
    regexMatch  = orc.matchesPattern "sys/foo.conf"   "/sys/.*[.]conf/";
  };

  t_applyPolicy_include =
    let r = orc.applyPolicy { include = [ "sys/" ]; } allFiles; in {
      onlySys  = lib.all (lib.hasPrefix "sys/") (builtins.attrNames r);
      nonEmpty = r != { };
    };

  t_applyPolicy_exclude =
    let r = orc.applyPolicy { exclude = [ "*.conf" ]; } allFiles; in {
      noConfFiles = lib.all
        (p: ! lib.hasSuffix ".conf" p) (builtins.attrNames r);
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
      textIsCorrect = (r."hyprland.conf").text ==
        "# managed by Nix — hyprland.conf";
    };

  t_applyPolicy_dropNull =
    let
      r = orc.applyPolicy {
        transform = _: entry:
          if entry.type == "symlink" then null else entry;
      } allFiles;
    in {
      noSymlinks = lib.all
        (p: r.${p}.type != "symlink") (builtins.attrNames r);
    };

  t_applyPolicy_emitterField =
    let
      r = orc.applyPolicy { emitter = "copy"; include = [ "sys/" ]; } allFiles;
    in {
      allAreCopy = lib.all
        (p: r.${p}.emitter == "copy") (builtins.attrNames r);
    };

  t_applyPolicies =
    let
      r = orc.applyPolicies [
        { include = [ "sys/"  ]; emitter = "symlink"; priority = 10; }
        { include = [ "user/" ]; emitter = "copy";    priority = 20; }
      ] allFiles;
    in {
      hasSysFiles  = lib.any (lib.hasPrefix "sys/")  (builtins.attrNames r);
      hasUserFiles = lib.any (lib.hasPrefix "user/") (builtins.attrNames r);
      noOtherFiles = lib.all
        (p: lib.hasPrefix "sys/" p || lib.hasPrefix "user/" p)
        (builtins.attrNames r);
      userFileIsCopy =
        let userFiles = lib.filterAttrs (p: _: lib.hasPrefix "user/" p) r;
        in lib.all (e: e.emitter == "copy") (builtins.attrValues userFiles);
    };

  # ─────────────────────────────────────────────────────────────────────────
  # Layer 3 · Emitter
  # ─────────────────────────────────────────────────────────────────────────

  sysFiles = orc.applyPolicy { include = [ "sys/" ]; } allFiles;

  t_toHomeFiles_symlink =
    let r = orc.toHomeFiles ".config/hypr" sysFiles; in {
      isAttrset      = builtins.isAttrs r;
      nonEmpty       = r != { };
      keysHavePrefix = lib.all
        (lib.hasPrefix ".config/hypr/sys/") (builtins.attrNames r);
      valHasSource   = (lib.head (builtins.attrValues r)) ? source;
    };

  t_toHomeFiles_copy =
    let
      copyFiles = orc.applyPolicy
        { include = [ "sys/" ]; emitter = "copy"; } allFiles;
      r = orc.toHomeFiles ".config/hypr" copyFiles;
    in {
      hasForce = (lib.head (builtins.attrValues r)).force or false;
    };

  t_toHomeFiles_text =
    let
      textFiles = orc.applyPolicy {
        include   = [ "hyprland.conf" ];
        emitter   = "text";
        transform = relPath: entry:
          entry // { text = "# generated"; };
      } allFiles;
      r = orc.toHomeFiles "" textFiles;
    in {
      hasTextKey = (r."hyprland.conf" or { }) ? text;
    };

  t_toDerivation =
    let drv = orc.toDerivation {
      inherit pkgs;
      name  = "test-config-tree";
      files = sysFiles;
    }; in {
      isDrvPath = builtins.isString (builtins.unsafeDiscardStringContext "${drv}");
    };

  t_toSymlinkTree =
    let drv = orc.toSymlinkTree {
      inherit pkgs;
      name  = "test-config-symlinks";
      files = sysFiles;
    }; in {
      isDrvPath = builtins.isString (builtins.unsafeDiscardStringContext "${drv}");
    };

  # ─────────────────────────────────────────────────────────────────────────
  # mergeHomeFiles — mixed-emitter in one pass
  # ─────────────────────────────────────────────────────────────────────────

  t_mergeHomeFiles =
    let
      r = orc.mergeHomeFiles allFiles [
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
      hwKey   = ".config/hypr/sys/hardware/default.conf";
      hyprKey = ".config/hypr/hyprland.conf";
      sysKey  = ".config/hypr/sys/default.conf";
    in {
      isAttrset    = builtins.isAttrs r;
      nonEmpty     = r != { };
      sysPresent   = r ? "${sysKey}";
      hwHasForce   = (r."${hwKey}"   or { }).force or false;
      hyprHasText  = (r."${hyprKey}" or { }) ? text;
      sysHasSource = (r."${sysKey}"  or { }) ? source;
      sysNoForce   = ! ((r."${sysKey}" or { }).force or false);
    };

  # ─────────────────────────────────────────────────────────────────────────
  # High-level · readConfigDir
  # ─────────────────────────────────────────────────────────────────────────

  t_readConfigDir_homeFiles =
    let r = orc.readConfigDir {
      inherit src;
      recursive  = true;
      policies   = [ { include = [ "sys/" ]; } ];
      emitter    = "homeFiles";
      destPrefix = ".config/hypr";
    }; in {
      isAttrset      = builtins.isAttrs r;
      nonEmpty       = r != { };
      keysHavePrefix = lib.all (lib.hasPrefix ".config/hypr/") (builtins.attrNames r);
    };

  t_readConfigDir_derivation =
    let drv = orc.readConfigDir {
      inherit src pkgs;
      recursive = true;
      policies  = [ { include = [ "sys/" ]; } ];
      emitter   = "derivation";
      name      = "hypr-sys-config";
    }; in {
      isDrv = builtins.isString (builtins.unsafeDiscardStringContext "${drv}");
    };

  t_readConfigDir_symlinkTree =
    let drv = orc.readConfigDir {
      inherit src pkgs;
      recursive = true;
      policies  = [ { include = [ "sys/" ]; } ];
      emitter   = "symlinkTree";
      name      = "hypr-sys-symlinks";
    }; in {
      isDrv = builtins.isString (builtins.unsafeDiscardStringContext "${drv}");
    };

  # ─────────────────────────────────────────────────────────────────────────
  # Aggregate
  # ─────────────────────────────────────────────────────────────────────────

  allTests = {
    layer1 = {
      readDirFlat        = t_readDirFlat;
      listFilesRecursive = t_listFilesRecursive;
    };
    layer2 = {
      matchesPattern        = t_matchesPattern;
      applyPolicy_include   = t_applyPolicy_include;
      applyPolicy_exclude   = t_applyPolicy_exclude;
      applyPolicy_transform = t_applyPolicy_transform;
      applyPolicy_dropNull  = t_applyPolicy_dropNull;
      applyPolicy_emitter   = t_applyPolicy_emitterField;
      applyPolicies         = t_applyPolicies;
    };
    layer3 = {
      toHomeFiles_symlink = t_toHomeFiles_symlink;
      toHomeFiles_copy    = t_toHomeFiles_copy;
      toHomeFiles_text    = t_toHomeFiles_text;
      toDerivation        = t_toDerivation;
      toSymlinkTree       = t_toSymlinkTree;
      mergeHomeFiles      = t_mergeHomeFiles;
    };
    highLevel = {
      homeFiles   = t_readConfigDir_homeFiles;
      derivation  = t_readConfigDir_derivation;
      symlinkTree = t_readConfigDir_symlinkTree;
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
