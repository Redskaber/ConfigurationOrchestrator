# ConfigurationOrchestrator — lib/default.nix
#
# Pure-Nix three-layer library for reading, filtering, transforming, and
# emitting configuration directory trees with **per-file emitter control**.
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │  Layer 1 · Discovery                                                │
# │  readDirFlat / listFilesRecursive / listFilesRecursiveFiltered      │
# │  { "rel/path" = { absPath; type; }; }                               │
# ├─────────────────────────────────────────────────────────────────────┤
# │  Layer 2 · Policy Engine                                            │
# │  applyPolicy / applyPolicies / tagAll                               │
# │  { "rel/path" = { absPath; type; emitter; priority; ?text; }; }    │
# ├─────────────────────────────────────────────────────────────────────┤
# │  Layer 3 · Emitter Dispatch                                         │
# │  toHomeFiles / toDerivation / toSymlinkTree / emit / mergeHomeFiles │
# │  → { homeFiles; ?derivation; ?symlinkTree; }                        │
# │  → { homeFiles; activation; }                                       │
# └─────────────────────────────────────────────────────────────────────┘
#
# Design principles
# ─────────────────
# • Dependency inversion  — callers depend on policy abstractions, not fs layout
# • Pipeline / dataflow   — Discovery → Policy → Emit; each stage is pure
# • Layered architecture  — each layer exposes a stable, composable interface
# • Data-driven           — behaviour driven by policy attrsets, not hard-coded logic
# • Open/closed           — extend via policies and transforms, not source edits
# • Explicit boundaries   — home.file symlinks vs. activation cp are kept distinct
# • Incremental           — policies compose; last-match-wins enables override idiom
#
# Lifecycle
# ─────────
#   Nix eval time:   Discovery → Policy → Emit  (pure, deterministic)
#   home-manager activation:  writeBoundary → activation scripts (cp, chmod)
#   Runtime:         external tools write into copied files
#
{ lib }:

let

  # ═══════════════════════════════════════════════════════════════════════════
  # Helpers
  # ═══════════════════════════════════════════════════════════════════════════

  # Normalise a destPrefix: strip trailing slash, treat bare "" as identity.
  # joinPath "" "a/b"   → "a/b"
  # joinPath "x"  "a/b" → "x/a/b"
  joinPath = prefix: rel:
    if prefix == "" then rel else "${prefix}/${rel}";

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 1 · File Discovery
  # ═══════════════════════════════════════════════════════════════════════════

  # ── readDirFlat ────────────────────────────────────────────────────────────
  # Non-recursive snapshot of a directory.
  # Returns: { "name" = "regular"|"directory"|"symlink"|"unknown"; ... }
  readDirFlat = dir:
    builtins.readDir dir;

  # ── listFilesRecursive ─────────────────────────────────────────────────────
  # Recursively walks `dir`, collecting every non-directory entry.
  # Includes regular, symlink, and unknown entries.
  # Call with prefix = "" at the call-site.
  #
  # Returns: { "rel/path" = { absPath :: string; type :: string; }; ... }
  listFilesRecursive = dir: prefix:
    let
      entries      = builtins.readDir dir;
      processEntry = name: type:
        let
          relPath = if prefix == "" then name else "${prefix}/${name}";
          absPath = "${builtins.toString dir}/${name}";
        in
        if type == "directory"
        then listFilesRecursive absPath relPath
        else { "${relPath}" = { inherit absPath type; }; };
    in
    lib.foldl' (acc: x: acc // x) { }
      (lib.mapAttrsToList processEntry entries);

  # ── listFilesRecursiveFiltered ─────────────────────────────────────────────
  # Like listFilesRecursive but skips entries whose `type` is listed in
  # `skipTypes` at discovery time. The skip propagates through all recursive
  # calls.
  #
  # Preferred over post-hoc transform drops because it prevents aliased
  # source-tree symlinks from generating duplicate home.file entries.
  #
  # Example:
  #   listFilesRecursiveFiltered src "" [ "symlink" ]
  #
  # Returns: { "rel/path" = { absPath; type; }; ... }
  listFilesRecursiveFiltered = dir: prefix: skipTypes:
    let
      entries      = builtins.readDir dir;
      processEntry = name: type:
        let
          relPath = if prefix == "" then name else "${prefix}/${name}";
          absPath = "${builtins.toString dir}/${name}";
        in
        if type == "directory"
        then listFilesRecursiveFiltered absPath relPath skipTypes
        else if lib.elem type skipTypes
        then { }
        else { "${relPath}" = { inherit absPath type; }; };
    in
    lib.foldl' (acc: x: acc // x) { }
      (lib.mapAttrsToList processEntry entries);

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 2 · Policy Engine
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # A policy is an attrset — all fields optional:
  #
  #   include   :: [ pattern ]      default: []    accept everything
  #   exclude   :: [ pattern ]      default: []    drop nothing
  #   transform :: relPath → entry → (entry | null)
  #                                 default: identity; null drops the file
  #   emitter   :: string           default: "homeFiles"
  #                 emit/readConfigDir:  "homeFiles" | "derivation" | "symlinkTree"
  #                 mergeHomeFiles:      "symlink"   | "copy"       | "text"
  #   priority  :: int              default: 5
  #                 Passed through to home.file entries as lib.mkOrder priority.
  #
  # Pattern syntax:
  #   []  or [ "*" ]  accept everything
  #   "sys/"          prefix match
  #   "*.conf"        suffix match (leading *)
  #   "sys/*"         prefix match (trailing *)
  #   "/ERE/"         POSIX extended regular expression via builtins.match
  #
  # Composition:
  #   applyPolicies applies policies in list order.
  #   LAST matching policy wins per file, enabling base-layer + point-override.

  defaultPolicy = {
    include   = [ ];
    exclude   = [ ];
    transform = _relPath: entry: entry;
    emitter   = "homeFiles";
    priority  = 5;
  };

  # ── matchesPattern ─────────────────────────────────────────────────────────
  # Tests whether `relPath` matches `pattern`.
  # Dispatch:
  #   "/ERE/"  → POSIX ERE (builtins.match)
  #   "*"      → universal wildcard
  #   "*.ext"  → suffix match
  #   "dir/*"  → prefix match (trailing * stripped)
  #   "dir/"   → prefix match (plain prefix string)
  matchesPattern = relPath: pattern:
    let
      isRegex  = lib.hasPrefix "/" pattern && lib.hasSuffix "/" pattern;
      isSuffix = !isRegex && lib.hasPrefix "*" pattern;
      isPrefix = !isRegex && !isSuffix && lib.hasSuffix "*" pattern;
    in
    if isRegex then
      let inner = lib.removePrefix "/" (lib.removeSuffix "/" pattern);
      in builtins.match inner relPath != null
    else if isSuffix then
      lib.hasSuffix (lib.removePrefix "*" pattern) relPath
    else if isPrefix then
      lib.hasPrefix (lib.removeSuffix "*" pattern) relPath
    else
      # plain string → prefix match (covers both "dir/" and "file.conf")
      lib.hasPrefix pattern relPath;

  # Returns true if relPath matches any pattern in the list.
  matchesAny = relPath: patterns:
    lib.any (matchesPattern relPath) patterns;

  # ── applyPolicy ────────────────────────────────────────────────────────────
  # Applies a single policy to a file map.
  # Surviving entries are tagged with { emitter; priority }.
  #
  # Returns: { "rel/path" = { absPath; type; emitter; priority; ?text; }; ... }
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

  # ── applyPolicies ──────────────────────────────────────────────────────────
  # Applies a list of policies in order; last match wins per file.
  # Files not matched by any policy are excluded from the result.
  applyPolicies = policies: files:
    lib.foldl'
      (acc: policy: acc // applyPolicy policy files)
      { }
      policies;

  # ── tagAll ─────────────────────────────────────────────────────────────────
  # Tags every entry in a raw FileMap with the default emitter and priority.
  # Used internally by readConfigDir when policies = [] to produce a valid
  # TaggedMap without running through the policy engine.
  #
  # This is the boundary contract: emit/toHomeFiles always receive a TaggedMap
  # (entries that have `emitter` and `priority`). Callers must never pass a raw
  # FileMap directly to Layer-3 functions.
  tagAll = files:
    lib.mapAttrs (_: entry: entry // {
      emitter  = defaultPolicy.emitter;
      priority = defaultPolicy.priority;
    }) files;

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 3 · Emitters
  # ═══════════════════════════════════════════════════════════════════════════

  # ── 3a · toHomeFiles ───────────────────────────────────────────────────────
  # Converts a tagged file map into a home.file-compatible attrset.
  # `destPrefix` is prepended to every destination key.
  #
  # Entry → home.file value:
  #   entry.text present  →  { text = entry.text; }
  #   entry.force = true  →  value // { force = true; }
  #   otherwise           →  { source = absPath; }
  #
  # NOTE: home-manager ALWAYS installs home.file entries as symlinks into the
  # read-only Nix store. Use the "copy" emitter in mergeHomeFiles for
  # runtime-writable files.
  toHomeFiles = destPrefix: files:
    lib.mapAttrs'
      (relPath: entry:
        let
          key   = joinPath destPrefix relPath;
          value =
            if entry ? text
            then { text = entry.text; }
            else { source = entry.absPath; };
          withForce =
            if entry.force or false
            then value // { force = true; }
            else value;
        in
        lib.nameValuePair key withForce)
      files;

  # ── 3b · toDerivation ─────────────────────────────────────────────────────
  # Builds a Nix store path that physically copies all files.
  # Inline text entries are materialised via builtins.toFile.
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
            in
            ''
              mkdir -p "$out/$(dirname ${escapedRel})"
              cp ${lib.escapeShellArg srcPath} "$out/"${escapedRel}
            '')
          files;
      in
      ''
        mkdir -p "$out"
        ${lib.concatStringsSep "\n" copies}
      ''
    );

  # ── 3c · toSymlinkTree ────────────────────────────────────────────────────
  # Builds a Nix store path whose contents are symlinks to source paths.
  # Text entries are first materialised into the store via builtins.toFile.
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
                else lib.escapeShellArg entry.absPath;
            in
            ''
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

  # ── 3d · emit ─────────────────────────────────────────────────────────────
  # Multi-emitter dispatch. Splits `files` by each entry's `emitter` tag and
  # calls the appropriate low-level builder.
  #
  # Precondition: every entry in `files` MUST have an `emitter` attribute.
  # Use tagAll (or applyPolicies) before calling emit on a raw FileMap.
  #
  # Arguments:
  #   files       :: TaggedMap  (output of applyPolicy/applyPolicies/tagAll)
  #   destPrefix  :: string     default ""    applied to homeFiles keys only
  #   pkgs        :: pkgs       required for "derivation" or "symlinkTree"
  #   drvName     :: string     default "config-tree"
  #
  # Returns:
  #   {
  #     homeFiles    :: attrset      always present (may be {})
  #     derivation   :: derivation   present only when emitter="derivation" used
  #     symlinkTree  :: derivation   present only when emitter="symlinkTree" used
  #   }
  emit = { files, destPrefix ? "", pkgs ? null, drvName ? "config-tree" }:
    let
      byEmitter = tag: lib.filterAttrs (_: e: e.emitter == tag) files;

      homeEntries    = byEmitter "homeFiles";
      drvEntries     = byEmitter "derivation";
      symlinkEntries = byEmitter "symlinkTree";

      homeFiles =
        if homeEntries == { } then { }
        else toHomeFiles destPrefix homeEntries;

      derivation =
        if drvEntries == { } then null
        else
          assert pkgs != null ||
            builtins.throw "ConfigurationOrchestrator.emit: pkgs required for emitter=\"derivation\"";
          toDerivation { inherit pkgs; name = drvName; files = drvEntries; };

      symlinkTree =
        if symlinkEntries == { } then null
        else
          assert pkgs != null ||
            builtins.throw "ConfigurationOrchestrator.emit: pkgs required for emitter=\"symlinkTree\"";
          toSymlinkTree { inherit pkgs; name = "${drvName}-links"; files = symlinkEntries; };
    in
    { inherit homeFiles; }
    // lib.optionalAttrs (derivation  != null) { inherit derivation; }
    // lib.optionalAttrs (symlinkTree != null) { inherit symlinkTree; };

  # ── 3e · mergeHomeFiles ───────────────────────────────────────────────────
  # High-level combinator for home-manager deployments.
  # Processes `files` (a raw FileMap) through a list of home-specific policies
  # and returns two output channels:
  #
  #   homeFiles  :: attrset   → assign to: home.file = result.homeFiles
  #   activation :: string    → assign to:
  #                               home.activation.<name> =
  #                                 lib.hm.dag.entryAfter ["writeBoundary"]
  #                                   result.activation;
  #
  # Per-policy `emitter` values and their semantics:
  #
  #   "symlink"  (default)
  #     Adds a home.file entry: { source = absPath; }
  #     home-manager installs a read-only symlink into the Nix store.
  #
  #   "copy"
  #     Adds a shell command to the activation script:
  #       run mkdir -p "$(dirname "$HOME/<key>")"
  #       run cp --remove-destination <store-path> $HOME/<key>
  #       run chmod u+w $HOME/<key>
  #     This produces a real writable file on disk after activation.
  #     Also evicts the key from homeFiles if a prior policy placed it there.
  #
  #   "text"
  #     Adds a home.file entry: { text = entry.text; }
  #     Requires the policy's `transform` to inject `entry.text`; throws otherwise.
  #
  # Policy fields (all optional):
  #   include    :: [ pattern ]
  #   exclude    :: [ pattern ]
  #   transform  :: relPath → entry → (entry | null)
  #   emitter    :: "symlink" | "copy" | "text"     default: "symlink"
  #   destPrefix :: string                          default: ""
  #   priority   :: int                             default: 5
  #
  # Composition: policies processed in list order; last-match-wins per
  # destination key. A "copy" policy evicts any prior "symlink" for the same key.
  mergeHomeFiles = files: policies:
    let
      defaultHomePolicy = {
        include    = [ ];
        exclude    = [ ];
        transform  = _relPath: entry: entry;
        emitter    = "symlink";
        destPrefix = "";
        priority   = 5;
      };

      # For one policy, produce a decision map keyed by destination key:
      #   { "<destKey>" = { key; emitter; absPath; ?text; }; }
      policyDecisions = policy:
        let
          p = defaultHomePolicy // policy;

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
        lib.mapAttrs'
          (relPath: entry:
            let key = joinPath p.destPrefix relPath;
            in lib.nameValuePair key {
              inherit key;
              emitter = p.emitter;
              absPath = entry.absPath;
              text    = entry.text or null;
            })
          cleaned;

      # Fold all policies in order → last-wins per destination key.
      allDecisions =
        lib.foldl'
          (acc: policy: acc // policyDecisions policy)
          { }
          policies;

      # Stable sort on keys for deterministic activation script ordering.
      sortedKeys = lib.sort lib.lessThan (builtins.attrNames allDecisions);

      # Split decisions into homeFiles attrset and activation script lines.
      finalResult =
        lib.foldl'
          (acc: key:
            let d = allDecisions.${key}; in
            if d.emitter == "copy" then
              acc // {
                # Evict from homeFiles if a prior policy put it there
                homeFiles      = builtins.removeAttrs acc.homeFiles [ key ];
                activationCmds = acc.activationCmds ++ [
                  ''
                    run mkdir -p "$(dirname "$HOME/${key}")"
                    run cp --remove-destination ${lib.escapeShellArg d.absPath} "$HOME/${key}"
                    run chmod u+w "$HOME/${key}"
                  ''
                ];
              }
            else if d.emitter == "text" then
              if d.text == null
              then throw ''
                ConfigurationOrchestrator.mergeHomeFiles: emitter="text" requires
                a transform that sets entry.text, but key "${key}" has no text.
                Hint: add  transform = _: e: e // { text = builtins.readFile e.absPath; };
              ''
              else acc // {
                homeFiles = acc.homeFiles // { "${key}" = { text = d.text; }; };
              }
            else
              # "symlink" (default)
              acc // {
                homeFiles = acc.homeFiles // { "${key}" = { source = d.absPath; }; };
              })
          { homeFiles = { }; activationCmds = [ ]; }
          sortedKeys;
    in
    {
      homeFiles  = finalResult.homeFiles;
      activation = lib.concatStringsSep "\n" finalResult.activationCmds;
    };

  # ═══════════════════════════════════════════════════════════════════════════
  # High-level entry point
  # ═══════════════════════════════════════════════════════════════════════════

  # ── readConfigDir ──────────────────────────────────────────────────────────
  # Discovers files under `src`, applies `policies`, dispatches emitters.
  #
  # Arguments:
  #   src        :: path
  #   recursive  :: bool          default: true
  #   policies   :: [ policy ]    ordered; last-match-wins per file
  #                               [] → all files pass through as "homeFiles"
  #   destPrefix :: string        default: ""    homeFiles keys only
  #   pkgs       :: pkgs          required when any policy uses
  #                               "derivation" or "symlinkTree"
  #   name       :: string        default: "config-tree"
  #
  # Returns (via emit):
  #   {
  #     homeFiles    :: attrset
  #     derivation   :: derivation   (present only when used)
  #     symlinkTree  :: derivation   (present only when used)
  #   }
  #
  # Internal state-machine:
  #   policies == []  →  Discovery → tagAll (default emitter) → emit
  #   policies != []  →  Discovery → applyPolicies            → emit
  #
  # The tagAll path ensures that emit always receives a valid TaggedMap
  # (entries guaranteed to have `emitter` and `priority` attributes),
  # regardless of whether any policy was applied.
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
        else lib.mapAttrs'
          (n: type:
            lib.nameValuePair n {
              absPath = "${builtins.toString src}/${n}";
              inherit type;
            })
          (lib.filterAttrs (_: t: t != "directory") (readDirFlat src));

      # INVARIANT: processed is always a TaggedMap (has emitter + priority on
      # every entry) before being handed to emit.
      processed =
        if policies == [ ]
        then tagAll raw          # ← FIX: was passing raw FileMap without tags
        else applyPolicies policies raw;
    in
    emit {
      files      = processed;
      inherit destPrefix pkgs;
      drvName    = name;
    };

in
{
  # ── Layer 1 ────────────────────────────────────────────────────────────────
  inherit readDirFlat;
  inherit listFilesRecursive;
  inherit listFilesRecursiveFiltered;

  # ── Layer 2 ────────────────────────────────────────────────────────────────
  inherit matchesPattern;
  inherit matchesAny;
  inherit applyPolicy;
  inherit applyPolicies;
  inherit tagAll;

  # ── Layer 3 ────────────────────────────────────────────────────────────────
  inherit toHomeFiles;
  inherit toDerivation;
  inherit toSymlinkTree;
  inherit emit;
  inherit mergeHomeFiles;

  # ── High-level ─────────────────────────────────────────────────────────────
  inherit readConfigDir;
}
