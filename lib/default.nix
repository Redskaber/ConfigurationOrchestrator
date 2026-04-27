# lib/default.nix
# ConfigurationOrchestrator
#
# Three-layer pure-Nix library for reading, filtering, transforming
# and emitting configuration directory trees.
#
# Layer 1 · Discovery   — readDirFlat / listFilesRecursive / listFilesRecursiveFiltered
# Layer 2 · Policy      — include / exclude / transform / priority / emitter
# Layer 3 · Emitter     — toHomeFiles / toDerivation / toSymlinkTree / emit / mergeHomeFiles
{ lib }:

let

  # ───────────────────────────────────────────────────────────────────────────
  # Layer 1 · File Discovery
  # ───────────────────────────────────────────────────────────────────────────

  # Non-recursive: { "name" = "type"; ... }
  # type ∈ "regular" | "directory" | "symlink" | "unknown"
  readDirFlat = dir:
    lib.mapAttrs'
      (name: type: lib.nameValuePair name type)
      (builtins.readDir dir);

  # Recursive flat map: { "rel/path" = { absPath; type; }; ... }
  # Includes ALL non-directory entries (regular, symlink, unknown).
  # Call with prefix = "" at the call-site.
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

  # Like listFilesRecursive but skips entries whose type is in `skipTypes`.
  # Use skipTypes = [ "symlink" ] to exclude all source-tree symlinks
  # (prevents aliased files from generating duplicate home.file entries).
  #
  # Example:
  #   listFilesRecursiveFiltered src "" [ "symlink" ]
  listFilesRecursiveFiltered = dir: prefix: skipTypes:
    let
      entries      = builtins.readDir dir;
      processEntry = name: type:
        let
          relPath = if prefix == "" then name else "${prefix}/${name}";
          absPath = "${toString dir}/${name}";
        in
        if type == "directory"
        then listFilesRecursiveFiltered "${toString dir}/${name}" relPath skipTypes
        else if lib.elem type skipTypes
        then { }
        else { "${relPath}" = { inherit absPath type; }; };
    in
    lib.foldAttrs lib.const { }
      (lib.mapAttrsToList processEntry entries);

  # ───────────────────────────────────────────────────────────────────────────
  # Layer 2 · Policy Engine
  # ───────────────────────────────────────────────────────────────────────────
  #
  # A policy is an attrset — all fields optional:
  #
  #   include   :: [ pattern ]      default: []    accept everything
  #   exclude   :: [ pattern ]      default: []    drop nothing
  #   transform :: relPath → entry → entry | null
  #                                 default: identity; null drops the file
  #   emitter   :: string           default: "homeFiles"
  #                 "homeFiles" | "derivation" | "symlinkTree"   (for applyPolicy)
  #                 "symlink"   | "copy"        | "text"         (for mergeHomeFiles)
  #   priority  :: int              default: 5     home-manager mkMerge priority
  #
  # Pattern syntax:
  #   []          include = [] means accept everything (same as [ "*" ])
  #   "*"         universal wildcard — matches every path
  #   "sys/"      prefix match
  #   "*.conf"    suffix match
  #   "sys/*"     prefix match (trailing * stripped)
  #   "/ERE/"     POSIX extended regular expression (builtins.match)
  #
  # Composition: applyPolicies applies a list in order; the LAST policy that
  # matches a file wins (last-wins enables base-layer + point-override idiom).

  defaultPolicy = {
    include   = [ ];
    exclude   = [ ];
    transform = _relPath: entry: entry;
    emitter   = "homeFiles";
    priority  = 5;
  };

  # pattern → relPath → bool
  #
  # Dispatch order:
  #   "/ERE/" — POSIX ERE via builtins.match
  #   "*"     — universal wildcard (matches everything)
  #   "*.ext" — suffix match (starts with *)
  #   "dir/*" — prefix match (ends with *)
  #   "dir/"  — prefix match (plain string)
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

  # Apply one policy to a file map.
  # Returns { "rel/path" = { absPath; type; emitter; priority; ?text; }; ... }
  applyPolicy = policy: files:
    let
      p = defaultPolicy // policy;

      keep = relPath: _:
        let
          included = p.include == [ ] || matchesAny relPath p.include;
          excluded = p.exclude != [ ] && matchesAny relPath p.exclude;
        in
        included && !excluded;

      filtered    = lib.filterAttrs keep files;
      transformed = lib.mapAttrs (relPath: entry: p.transform relPath entry) filtered;
      cleaned     = lib.filterAttrs (_: v: v != null) transformed;
    in
    lib.mapAttrs (_: entry: entry // {
      emitter  = p.emitter;
      priority = p.priority;
    }) cleaned;

  # Apply a list of policies; last match wins per file.
  applyPolicies = policies: files:
    lib.foldl'
      (acc: policy: acc // applyPolicy policy files)
      { }
      policies;

  # ───────────────────────────────────────────────────────────────────────────
  # Layer 3 · Emitters
  # ───────────────────────────────────────────────────────────────────────────

  # ── 3a: toHomeFiles ───────────────────────────────────────────────────────
  # Converts a file map into a home.file-compatible attrset.
  # destPrefix is prepended to every key.
  #
  # Entry → home.file value mapping:
  #   entry.text present → { text = entry.text; }
  #                        home-manager auto-sets source = pkgs.writeText …
  #                        Still installed as a symlink, but to a store-generated file.
  #   otherwise          → { source = absPath; }  symlink into the Nix store
  #
  # NOTE: home-manager ALWAYS installs home.file entries as symlinks.
  # Neither `source` nor `text` produces a real writable file on disk.
  # For runtime-writable files (e.g. wallust), use the "copy" emitter in
  # mergeHomeFiles, which runs `cp` in the activation script instead.
  toHomeFiles = destPrefix: files:
    lib.mapAttrs'
      (relPath: entry:
        let
          key   = if destPrefix == "" then relPath
                  else "${destPrefix}/${relPath}";
          value =
            if entry ? text
            then { text = entry.text; }
            else { source = entry.absPath; };
        in
        lib.nameValuePair key value)
      files;

  # ── 3b: toDerivation ──────────────────────────────────────────────────────
  # Builds a store path that is a physical copy of the processed files.
  # Inline text is materialised via builtins.toFile (safe for any content).
  toDerivation = { pkgs, name ? "config-tree", files }:
    pkgs.runCommand name { } (
      let
        copies = lib.mapAttrsToList
          (relPath: entry:
            let
              escapedRel = lib.escapeShellArg relPath;
              srcPath    =
                if entry ? text
                then builtins.toFile (baseNameOf relPath) entry.text
                else entry.absPath;
            in ''
              mkdir -p "$out/$(dirname ${escapedRel})"
              cp ${srcPath} "$out/"${escapedRel}
            '')
          files;
      in
      ''
        mkdir -p "$out"
        ${lib.concatStringsSep "\n" copies}
      ''
    );

  # ── 3c: toSymlinkTree ─────────────────────────────────────────────────────
  # Builds a store path whose contents are symlinks into source paths.
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
              ln -s ${target} "$out/"${escapedRel}
            '')
          files;
      in
      ''
        mkdir -p "$out"
        ${lib.concatStringsSep "\n" links}
      ''
    );

  # ── 3d: emit ──────────────────────────────────────────────────────────────
  # Splits the file map by each entry's `emitter` tag and dispatches in parallel.
  #
  # Returns:
  #   {
  #     homeFiles   :: attrset      always present (may be {})
  #     derivation  :: derivation   present only when emitter="derivation" was used
  #     symlinkTree :: derivation   present only when emitter="symlinkTree" was used
  #   }
  #
  # destPrefix applies only to homeFiles keys.
  # pkgs is required when any policy uses "derivation" or "symlinkTree".
  emit = { files, destPrefix ? "", pkgs ? null, drvName ? "config-tree" }:
    let
      byEmitter = tag: lib.filterAttrs (_: e: e.emitter == tag) files;

      homeFileEntries = byEmitter "homeFiles";
      derivationFiles = byEmitter "derivation";
      symlinkFiles    = byEmitter "symlinkTree";

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
    { inherit homeFiles; }
    // lib.optionalAttrs (derivation  != null) { inherit derivation; }
    // lib.optionalAttrs (symlinkTree != null) { inherit symlinkTree; };

  # ── 3e: mergeHomeFiles ────────────────────────────────────────────────────
  # Produces a result attrset from a list of home-specific policies:
  #
  #   {
  #     homeFiles  :: attrset   suitable for home.file = …
  #     activation :: string    suitable for home.activation.<name>.script = …
  #   }
  #
  # Per-policy emitters:
  #   "symlink"  → home.file entry: { source = absPath; }
  #                home-manager creates a read-only symlink into the Nix store.
  #                Default. Use for stable config that is never written at runtime.
  #
  #   "copy"     → activation script: cp --remove-destination absPath target
  #                Copies the file at activation time, producing a real writable file
  #                on disk (not a symlink). Use for files that external tools write
  #                at runtime (e.g. wallust). The copy runs on every `home-manager switch`.
  #
  #   "text"     → home.file entry: { text = entry.text; }
  #                Like "symlink" but content is inline text from a transform.
  #                Still produces a symlink (home-manager always links for home.file).
  #                Use for injecting headers; NOT suitable for runtime-writable files.
  #
  # Why "copy" uses activation and not home.file:
  #   home-manager's home.file ALWAYS installs files as symlinks — regardless of
  #   `force`, `text`, or `source`. The only way to produce a real writable file
  #   is to cp it during the activation phase, after home-manager has finished linking.
  #
  # Per-policy fields (all optional):
  #   include    :: [ pattern ]   default: []  (accept everything)
  #   exclude    :: [ pattern ]   default: []  (drop nothing)
  #   transform  :: relPath → entry → entry | null
  #   emitter    :: "symlink" | "copy" | "text"
  #   destPrefix :: string        default: ""
  #   priority   :: int           default: 5
  #
  # Usage:
  #   let result = orc.mergeHomeFiles files [ … ]; in
  #   {
  #     home.file = result.homeFiles;
  #     home.activation.hyprCopy = lib.hm.dag.entryAfter [ "writeBoundary" ] result.activation;
  #   }
  mergeHomeFiles = files: policies:
    let
      applyOneHomePolicy = policy:
        let
          p = {
            include    = [ ];
            exclude    = [ ];
            transform  = _relPath: entry: entry;
            emitter    = "symlink";
            destPrefix = "";
            priority   = 5;
          } // policy;

          keep = relPath: _:
            let
              included = p.include == [ ] || matchesAny relPath p.include;
              excluded = p.exclude != [ ] && matchesAny relPath p.exclude;
            in included && !excluded;

          filtered    = lib.filterAttrs keep files;
          transformed = lib.mapAttrs (relPath: entry: p.transform relPath entry) filtered;
          cleaned     = lib.filterAttrs (_: v: v != null) transformed;
        in
        # Return { homeFiles = { … }; activationCmds = [ "cmd" … ]; }
        lib.foldl'
          (acc: relPath:
            let
              entry  = cleaned.${relPath};
              key    = if p.destPrefix == "" then relPath
                       else "${p.destPrefix}/${relPath}";
            in
            if p.emitter == "copy" then
              # Activation-time cp — produces a real writable file
              acc // {
                activationCmds = acc.activationCmds ++ [
                  ''
                    mkdir -p "$(dirname "$HOME/${key}")"
                    cp --remove-destination ${lib.escapeShellArg entry.absPath} "$HOME/${key}"
                    chmod u+w "$HOME/${key}"
                  ''
                ];
              }
            else if p.emitter == "text" then
              if ! (entry ? text)
              then throw ''
                ConfigurationOrchestrator.mergeHomeFiles: emitter="text" requires
                a transform that sets entry.text, but "${relPath}" has no text field.
                Add: transform = _: e: e // { text = builtins.readFile e.absPath; };
              ''
              else
                acc // {
                  homeFiles = acc.homeFiles // { "${key}" = { text = entry.text; }; };
                }
            else
              # "symlink" — read-only symlink into the Nix store
              acc // {
                homeFiles = acc.homeFiles // { "${key}" = { source = entry.absPath; }; };
              })
          { homeFiles = { }; activationCmds = [ ]; }
          (builtins.attrNames cleaned);

      # Fold all policies, merging homeFiles and accumulating activation cmds
      folded = lib.foldl'
        (acc: policy:
          let result = applyOneHomePolicy policy; in
          {
            homeFiles      = acc.homeFiles // result.homeFiles;
            activationCmds = acc.activationCmds ++ result.activationCmds;
          })
        { homeFiles = { }; activationCmds = [ ]; }
        policies;
    in
    {
      homeFiles  = folded.homeFiles;
      activation = lib.concatStringsSep "\n" folded.activationCmds;
    };

  # ───────────────────────────────────────────────────────────────────────────
  # High-level entry point
  # ───────────────────────────────────────────────────────────────────────────
  #
  # readConfigDir — discovers files, applies policies, dispatches emitters.
  #
  #   src        :: path
  #   recursive  :: bool          default: true
  #   policies   :: [ policy ]    ordered; last match wins per file
  #   destPrefix :: string        default: ""    homeFiles keys only
  #   pkgs       :: pkgs          required for derivation / symlinkTree
  #   name       :: string        default: "config-tree"
  #
  # Returns emit { … }:
  #   { homeFiles; ?derivation; ?symlinkTree; }
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
    listFilesRecursiveFiltered
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
    mergeHomeFiles
    # High-level
    readConfigDir;
}
