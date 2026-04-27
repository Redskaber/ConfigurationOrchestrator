# lib/default.nix
# ConfigurationOrchestrator
#
# Three-layer pure-Nix library for reading, filtering, transforming
# and emitting configuration directory trees.
#
# Layer 1 · Discovery   — readDirFlat / listFilesRecursive
# Layer 2 · Policy      — include / exclude / transform / priority / emitter
# Layer 3 · Emitter     — toHomeFiles / toDerivation / toSymlinkTree / emit
{ lib }:

let

  # ───────────────────────────────────────────────────────────────────────────
  # Layer 1 · File Discovery
  # ───────────────────────────────────────────────────────────────────────────

  # Non-recursive: returns { "name" = "type"; ... }
  # type ∈ "regular" | "directory" | "symlink" | "unknown"
  readDirFlat = dir:
    lib.mapAttrs'
      (name: type: lib.nameValuePair name type)
      (builtins.readDir dir);

  # Recursive: returns { "rel/path/to/file" = { absPath; type; }; ... }
  # Call with prefix = "" at the top level.
  listFilesRecursive = dir: prefix:
    let
      entries      = builtins.readDir dir;
      processEntry = name: type:
        let
          relPath = if prefix == "" then name else "${prefix}/${name}";
          absPath = "${toString dir}/${name}";
        in
        if type == "directory"
        then listFilesRecursive "${toString dir}/${name}" relPath
        else { "${relPath}" = { inherit absPath type; }; };
    in
    lib.foldAttrs lib.const { }
      (lib.mapAttrsToList processEntry entries);

  # ───────────────────────────────────────────────────────────────────────────
  # Layer 2 · Policy Engine
  # ───────────────────────────────────────────────────────────────────────────
  #
  # A policy is an attrset:
  #
  #   include   :: [ pattern ]              default: [] (accept everything)
  #   exclude   :: [ pattern ]              default: [] (drop nothing)
  #   transform :: relPath → entry → entry | null
  #                                         default: identity
  #                                         return null to drop the file
  #   emitter   :: "homeFiles"              default: "homeFiles"
  #              | "derivation"
  #              | "symlinkTree"
  #   priority  :: int                      default: 5  (home-manager mkMerge)
  #
  # Pattern syntax:
  #   "sys/"        prefix match
  #   "*.conf"      suffix match
  #   "sys/*"       prefix match (trailing * stripped)
  #   "/ERE/"       POSIX extended regular expression (builtins.match)

  defaultPolicy = {
    include   = [ ];
    exclude   = [ ];
    transform = _relPath: entry: entry;
    emitter   = "homeFiles";
    priority  = 5;
  };

  # pattern → relPath → bool
  matchesPattern = relPath: pattern:
    let
      isRegex  = lib.hasPrefix "/" pattern && lib.hasSuffix "/" pattern;
      inner    = lib.removePrefix "/" (lib.removeSuffix "/" pattern);
      isSuffix = lib.hasPrefix "*" pattern;
      isPrefix = lib.hasSuffix "*" pattern;
    in
    if isRegex       then builtins.match inner relPath != null
    else if isSuffix then lib.hasSuffix (lib.removePrefix "*" pattern) relPath
    else if isPrefix then lib.hasPrefix (lib.removeSuffix "*" pattern) relPath
    else                  lib.hasPrefix pattern relPath;

  matchesAny = relPath: patterns:
    lib.any (matchesPattern relPath) patterns;

  # Apply one policy to the raw file map.
  # Returns { "rel/path" = { absPath; type; emitter; priority; ?text }; ... }
  applyPolicy = policy: files:
    let
      p = defaultPolicy // policy;

      keep = relPath: _entry:
        let
          included = p.include == [ ] || matchesAny relPath p.include;
          excluded = p.exclude != [ ] && matchesAny relPath p.exclude;
        in
        included && !excluded;

      filtered    = lib.filterAttrs keep files;
      transformed = lib.mapAttrs p.transform filtered;
      cleaned     = lib.filterAttrs (_: v: v != null) transformed;
    in
    lib.mapAttrs (_: entry: entry // {
      emitter  = p.emitter;
      priority = p.priority;
    }) cleaned;

  # Apply a list of policies.
  # Files matching multiple policies get the entry from the LAST matching
  # policy (last-wins), so you can progressively refine selections.
  applyPolicies = policies: files:
    lib.foldl'
      (acc: policy: acc // applyPolicy policy files)
      { }
      policies;

  # ───────────────────────────────────────────────────────────────────────────
  # Layer 3 · Emitters
  # ───────────────────────────────────────────────────────────────────────────

  # ── 3a: home.file attrset ────────────────────────────────────────────────
  # destPrefix is prepended to every key.
  # If the entry has a `text` field (injected by a transform) it wins over
  # `source`; otherwise `source = entry.absPath`.
  toHomeFiles = destPrefix: files:
    lib.mapAttrs'
      (relPath: entry:
        let
          key   = if destPrefix == "" then relPath
                  else "${destPrefix}/${relPath}";
          value =
            (if entry ? text
             then { text   = entry.text; }
             else { source = entry.absPath; })
            // lib.optionalAttrs (entry ? priority) { force = true; };
        in
        lib.nameValuePair key value)
      files;

  # ── 3b: derivation (physical copy tree) ──────────────────────────────────
  toDerivation = { pkgs, name ? "config-tree", files }:
    pkgs.runCommand name { } (
      let
        copies = lib.mapAttrsToList
          (relPath: entry:
            let
              escapedRel = lib.escapeShellArg relPath;
              content    =
                if entry ? text
                then ''printf '%s' ${lib.escapeShellArg entry.text} > "$out/${relPath}"''
                else ''cp ${entry.absPath} "$out/${relPath}"'';
            in ''
              mkdir -p "$out/$(dirname ${escapedRel})"
              ${content}
            '')
          files;
      in
      ''
        mkdir -p "$out"
        ${lib.concatStringsSep "\n" copies}
      ''
    );

  # ── 3c: symlink tree ──────────────────────────────────────────────────────
  toSymlinkTree = { pkgs, name ? "config-symlinks", files }:
    pkgs.runCommand name { } (
      let
        links = lib.mapAttrsToList
          (relPath: entry:
            let
              escapedRel = lib.escapeShellArg relPath;
              target     =
                if entry ? text
                then lib.escapeShellArg (builtins.toFile (baseNameOf relPath) entry.text)
                else entry.absPath;
            in ''
              mkdir -p "$out/$(dirname ${escapedRel})"
              ln -s ${target} "$out/${relPath}"
            '')
          files;
      in
      ''
        mkdir -p "$out"
        ${lib.concatStringsSep "\n" links}
      ''
    );

  # ───────────────────────────────────────────────────────────────────────────
  # Multi-emitter dispatch
  # ───────────────────────────────────────────────────────────────────────────
  #
  # `emit` takes the merged file map (where each entry carries an `emitter`
  # field set by its policy) and dispatches to the correct emitter per file.
  #
  # For "homeFiles":
  #   Returns an attrset merged from all per-file home.file entries.
  #
  # For "derivation" / "symlinkTree":
  #   Builds one derivation *per unique (emitter, name) pair* and returns
  #   an attrset:
  #     {
  #       homeFiles   = { … home.file entries … };
  #       derivations = { "name" = <drv>; … };
  #       symlinks    = { "name" = <drv>; … };
  #     }
  #
  # `destPrefix` applies only to homeFiles entries.
  # `pkgs` is required when any policy uses "derivation" or "symlinkTree".

  emit = { files, destPrefix ? "", pkgs ? null, drvName ? "config-tree" }:
    let
      byEmitter = emitterName:
        lib.filterAttrs (_: e: e.emitter == emitterName) files;

      homeFileEntries  = byEmitter "homeFiles";
      derivationFiles  = byEmitter "derivation";
      symlinkFiles     = byEmitter "symlinkTree";

      homeFiles =
        if homeFileEntries == { } then { }
        else toHomeFiles destPrefix homeFileEntries;

      derivation =
        if derivationFiles == { } then null
        else toDerivation { inherit pkgs; name = drvName; files = derivationFiles; };

      symlinkTree =
        if symlinkFiles == { } then null
        else toSymlinkTree { inherit pkgs; name = "${drvName}-links"; files = symlinkFiles; };

    in
    {
      inherit homeFiles;
    }
    // lib.optionalAttrs (derivation  != null) { inherit derivation; }
    // lib.optionalAttrs (symlinkTree != null) { inherit symlinkTree; };

  # ───────────────────────────────────────────────────────────────────────────
  # High-level entry point
  # ───────────────────────────────────────────────────────────────────────────
  #
  # readConfigDir — discovers files, applies policies, dispatches emitters.
  #
  # Arguments:
  #   src        :: path
  #   recursive  :: bool          (default: true)
  #   policies   :: [ policy ]    — ordered list; last match wins per file
  #   destPrefix :: string        (default: "")   homeFiles only
  #   pkgs       :: pkgs          required for derivation / symlinkTree
  #   name       :: string        (default: "config-tree")
  #
  # Returns:  emit { … }  — see `emit` above.
  readConfigDir =
    { src
    , recursive  ? true
    , policies   ? [ ]
    , destPrefix ? ""
    , pkgs       ? null
    , name       ? "config-tree"
    }:
    let
      raw =
        if recursive
        then listFilesRecursive src ""
        else lib.mapAttrs
          (n: type: { absPath = "${toString src}/${n}"; inherit type; })
          (lib.filterAttrs (_: t: t != "directory") (readDirFlat src));

      processed =
        if policies == [ ]
        then raw
        else applyPolicies policies raw;
    in
    emit {
      files      = processed;
      inherit destPrefix pkgs;
      drvName    = name;
    };

in
{
  inherit
    # Layer 1
    readDirFlat
    listFilesRecursive
    # Layer 2
    matchesPattern
    matchesAny
    applyPolicy
    applyPolicies
    # Layer 3
    toHomeFiles
    toDerivation
    toSymlinkTree
    emit
    # High-level
    readConfigDir;
}
