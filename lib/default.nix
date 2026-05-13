# ConfigurationOrchestrator — lib/default.nix  (v4)
#
# Pure-Nix three-layer library for reading, filtering, transforming, and
# emitting configuration directory trees with **per-file emitter control**.
#
# ╔═════════════════════════════════════════════════════════════════════════╗
# ║  High-level API                                                         ║
# ║  readConfigDir · mergeHomeFiles                                         ║
# ╠═════════════════════════════════════════════════════════════════════════╣
# ║  Layer 3 · Emitter Dispatch                                             ║
# ║  emit · toHomeFiles · toDerivation · toSymlinkTree                      ║
# ║  registerEmitter (plugin point)                                         ║
# ╠═════════════════════════════════════════════════════════════════════════╣
# ║  Layer 2 · Policy Engine                                                ║
# ║  applyPolicy · applyPolicies · tagAll                                   ║
# ║  matchesPattern · matchesAny                                            ║
# ╠═════════════════════════════════════════════════════════════════════════╣
# ║  Layer 1 · File Discovery                                               ║
# ║  readDirFlat · listFilesRecursive · listFilesRecursiveFiltered          ║
# ╚═════════════════════════════════════════════════════════════════════════╝
#
# Design principles
# ─────────────────
# • Dependency inversion   — callers depend on policy abstractions, not fs layout
# • Pipeline / dataflow    — Discovery → Policy → Emit; each stage is pure
# • Layered architecture   — each layer exposes a stable, composable interface
# • Data-driven            — behaviour driven by policy attrsets, not hard-coded logic
# • Open/closed            — extend via registerEmitter and transforms, not source edits
# • Explicit boundaries    — home.file symlinks vs. activation cp are kept distinct
# • Incremental            — policies compose; last-match-wins enables override idiom
# • Fail-early             — invariant violations surface at eval time, not activation
# • Single-source          — no patch/fix files; all fixes consolidated here
#
# Lifecycle (state machine)
# ──────────────────────────
#   Nix eval time:
#     [INIT] → Layer 1 Discovery → [FileMap]
#            → Layer 2 Policy    → [TaggedMap]   ← invariant enforced here
#            → Layer 3 Emit      → [EmitResult | MergeResult]
#
#   home-manager switch:
#     [PRE-WRITE]  → checkLinkTargets
#     [WRITE]      → writeBoundary  (symlinks placed)
#     [POST-WRITE] → activation scripts (cp, chmod for "copy" emitter)
#
#   Runtime:
#     External tools (wallust, pywal, …) write into copied (writable) files.
#
# Communication protocol between layers
# ──────────────────────────────────────
#   FileMap   :: { "rel/path" = { absPath :: string; type :: string; }; }
#   TaggedMap :: FileMap entries + { emitter :: string; priority :: int; ?text :: string; ?force :: bool; }
#   HomeFiles :: { "dest/key" = { source :: string; } | { text :: string; } [// { force :: bool; }]; }
#   Activation :: string  (shell script for home.activation, uses `run` helper)
#   EmitResult :: { homeFiles :: HomeFiles; ?derivation :: StorePath; ?symlinkTree :: StorePath; }
#   MergeResult :: { homeFiles :: HomeFiles; activation :: Activation; }
#
{ lib }:

let

  # ═══════════════════════════════════════════════════════════════════════════
  # Internal helpers
  # ═══════════════════════════════════════════════════════════════════════════

  # Normalise a destPrefix: strip trailing slash, treat bare "" as identity.
  # joinPath "" "a/b"    → "a/b"
  # joinPath "x"  "a/b"  → "x/a/b"
  joinPath = prefix: rel:
    if prefix == "" then rel else "${prefix}/${rel}";

  # Format a friendly error with context for the user.
  # orchError :: string → string → a
  orchError = location: msg:
    builtins.throw "ConfigurationOrchestrator.${location}: ${msg}";

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 1 · File Discovery
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # Protocol output: FileMap
  #   { "rel/path" = { absPath :: string; type :: string; }; }
  #
  # Invariant: no directory entries survive — only regular, symlink, unknown.

  # ── readDirFlat ────────────────────────────────────────────────────────────
  # Non-recursive snapshot of a directory.
  # Returns: { "name" = "regular"|"directory"|"symlink"|"unknown"; … }
  readDirFlat = dir:
    builtins.readDir dir;

  # ── listFilesRecursive ─────────────────────────────────────────────────────
  # Recursively walks `dir`, collecting every non-directory entry.
  # Call with prefix = "" at the call-site.
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
  # Like listFilesRecursive but skips entries whose `type` is in `skipTypes`
  # at discovery time. Skip propagates through all recursive calls.
  #
  # Use skipTypes = [ "symlink" ] to prevent aliased source-tree symlinks
  # from generating duplicate home.file entries.
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
  # Protocol input:  FileMap
  # Protocol output: TaggedMap  (every entry MUST carry emitter + priority)
  #
  # A policy is a plain attrset — all fields optional:
  #
  #   include   :: [ Pattern ]   default: []   accept everything
  #   exclude   :: [ Pattern ]   default: []   drop nothing
  #   transform :: relPath → entry → (entry | null)
  #                              default: identity; null drops the file
  #   emitter   :: string        default: "homeFiles"
  #   priority  :: int           default: 5
  #
  # Pattern syntax:
  #   []  or [ "*" ]  → accept everything (universal wildcard)
  #   "*"             → universal wildcard
  #   "sys/"          → prefix match
  #   "*.conf"        → suffix match  (leading *)
  #   "sys/*"         → prefix match  (trailing * stripped)
  #   "/ERE/"         → POSIX extended regular expression (builtins.match)
  #
  # Composition semantics:
  #   applyPolicies applies policies left-to-right.
  #   LAST match wins per file, enabling base-layer + point-override idiom.

  defaultPolicy = {
    include   = [ ];
    exclude   = [ ];
    transform = _relPath: entry: entry;
    emitter   = "homeFiles";
    priority  = 5;
  };

  # ── matchesPattern ─────────────────────────────────────────────────────────
  matchesPattern = relPath: pattern:
    let
      isRegex  = lib.hasPrefix "/" pattern && lib.hasSuffix "/" pattern;
      isSuffix = !isRegex && lib.hasPrefix "*" pattern;
      isPrefix = !isRegex && !isSuffix && lib.hasSuffix "*" pattern;
      isWild   = pattern == "*";
    in
    if isWild   then true
    else if isRegex then
      let inner = lib.removePrefix "/" (lib.removeSuffix "/" pattern);
      in builtins.match inner relPath != null
    else if isSuffix then
      lib.hasSuffix (lib.removePrefix "*" pattern) relPath
    else if isPrefix then
      lib.hasPrefix (lib.removeSuffix "*" pattern) relPath
    else
      lib.hasPrefix pattern relPath;

  # Returns true if relPath matches any pattern in the list.
  matchesAny = relPath: patterns:
    lib.any (matchesPattern relPath) patterns;

  # ── applyPolicy ────────────────────────────────────────────────────────────
  # Applies a single policy to a FileMap → TaggedMap.
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
  # Applies a list of policies in order. Last match wins per file.
  # Files not matched by any policy are excluded from the result.
  applyPolicies = policies: files:
    lib.foldl'
      (acc: policy: acc // applyPolicy policy files)
      { }
      policies;

  # ── tagAll ─────────────────────────────────────────────────────────────────
  # Stamps every FileMap entry with the default emitter and priority.
  # No filtering — all entries survive.
  # Used by readConfigDir when policies = [] and directly by callers who
  # want all files as homeFiles without any include/exclude logic.
  #
  # TaggedMap invariant: emit/toHomeFiles ALWAYS require a TaggedMap.
  # tagAll satisfies this invariant cheaply, without the policy engine.
  tagAll = files:
    lib.mapAttrs (_: entry: entry // {
      emitter  = defaultPolicy.emitter;
      priority = defaultPolicy.priority;
    }) files;

  # ═══════════════════════════════════════════════════════════════════════════
  # Layer 3 · Emitters
  # ═══════════════════════════════════════════════════════════════════════════
  #
  # Protocol input:  TaggedMap
  # Protocol output: EmitResult | MergeResult
  #
  # Built-in emitter registry (open/closed — extend with registerEmitter):
  #   "homeFiles"    → toHomeFiles   → home.file attrset (symlinks via HM)
  #   "derivation"   → toDerivation  → Nix store path (physical copy)
  #   "symlinkTree"  → toSymlinkTree → Nix store path (symlink tree)
  #
  # mergeHomeFiles emitters (home-manager activation path):
  #   "symlink"      → homeFiles     { source = absPath; }
  #   "copy"         → activation    run cp …  (real writable file)
  #   "text"         → homeFiles     { text = entry.text; }

  # ── 3a · toHomeFiles ───────────────────────────────────────────────────────
  # Converts a TaggedMap into a home.file-compatible attrset.
  # `destPrefix` is prepended to every destination key.
  #
  # Entry → home.file value:
  #   entry.text present  →  { text = entry.text; }
  #   entry.force = true  →  value // { force = true; }
  #   otherwise           →  { source = absPath; }
  #
  # FIX v4: priority is now propagated via lib.mkOrder when priority != 5,
  # so callers can influence home-manager's mkMerge resolution order.
  toHomeFiles = destPrefix: files:
    lib.mapAttrs'
      (relPath: entry:
        let
          key   = joinPath destPrefix relPath;
          base  =
            if entry ? text
            then { text = entry.text; }
            else { source = entry.absPath; };
          withForce =
            if entry.force or false
            then base // { force = true; }
            else base;
          # Propagate priority through lib.mkOrder when it differs from default.
          # This allows downstream home-manager mkMerge to respect ordering.
          final =
            if (entry.priority or 5) != 5
            then lib.mkOrder entry.priority withForce
            else withForce;
        in
        lib.nameValuePair key final)
      files;

  # ── 3b · toDerivation ─────────────────────────────────────────────────────
  # Builds a Nix store path that physically copies all files.
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
              cp ${lib.escapeShellArg srcPath} "$out/${escapedRel}"
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
              ln -s ${target} "$out/${escapedRel}"
            '')
          files;
      in
      ''
        mkdir -p "$out"
        ${lib.concatStringsSep "\n" links}
      ''
    );

  # ── 3d · Built-in emitter registry ────────────────────────────────────────
  # Maps emitter tag → builder function.
  # This is the plugin/extension point: use registerEmitter to add new types.
  #
  # Builder signature:
  #   builder :: { files :: TaggedMap; destPrefix :: string; pkgs :: Pkgs?; drvName :: string } → any
  #
  # The "homeFiles" builder must return an attrset (home.file entries).
  # Store-path builders must return a derivation.
  builtinEmitters = {
    homeFiles = { files, destPrefix, ... }:
      toHomeFiles destPrefix files;

    derivation = { files, pkgs, drvName, ... }:
      if pkgs == null
      then orchError "emit" ''pkgs is required for emitter="derivation". Pass pkgs to readConfigDir or emit.''
      else toDerivation { inherit pkgs files; name = drvName; };

    symlinkTree = { files, pkgs, drvName, ... }:
      if pkgs == null
      then orchError "emit" ''pkgs is required for emitter="symlinkTree". Pass pkgs to readConfigDir or emit.''
      else toSymlinkTree { inherit pkgs; name = "${drvName}-links"; files = files; };
  };

  # ── registerEmitter ────────────────────────────────────────────────────────
  # Returns a new emitter registry with `name` → `builder` added.
  # Use this to extend emit without modifying this file (open/closed principle).
  #
  # Example:
  #   let
  #     myEmitters = orc.registerEmitter orc.defaultEmitters "myEmitter"
  #       ({ files, destPrefix, ... }: myBuilder files destPrefix);
  #     result = orc.emit { inherit files pkgs; emitters = myEmitters; };
  #   in …
  registerEmitter = registry: name: builder:
    registry // { "${name}" = builder; };

  # ── 3e · emit ─────────────────────────────────────────────────────────────
  # Multi-emitter dispatch. Splits `files` by each entry's `emitter` tag and
  # calls the registered builder.
  #
  # Precondition: every entry in `files` MUST have `emitter` and `priority`.
  # Use tagAll / applyPolicy / applyPolicies before calling emit on a raw FileMap.
  #
  # Arguments:
  #   files       :: TaggedMap
  #   destPrefix  :: string     default ""       applied to homeFiles keys only
  #   pkgs        :: Pkgs       required for "derivation" or "symlinkTree"
  #   drvName     :: string     default "config-tree"
  #   emitters    :: AttrSet    default builtinEmitters (plugin point)
  #
  # Returns: EmitResult
  #   { homeFiles; ?derivation; ?symlinkTree; ?<custom>; }
  emit = { files, destPrefix ? "", pkgs ? null, drvName ? "config-tree", emitters ? builtinEmitters }:
    let
      # Collect all distinct emitter tags present in the files.
      usedTags = lib.unique (map (e: e.emitter) (builtins.attrValues files));

      # For each used tag, collect the matching files and call the builder.
      dispatchOne = tag:
        let
          byTag   = lib.filterAttrs (_: e: e.emitter == tag) files;
          builder = emitters.${tag} or
            (orchError "emit" "Unknown emitter tag \"${tag}\". Register it with registerEmitter.");
        in
        builder { files = byTag; inherit destPrefix pkgs drvName; };

      # homeFiles is always present (empty attrset if no "homeFiles" entries).
      homeFiles =
        if lib.elem "homeFiles" usedTags
        then dispatchOne "homeFiles"
        else { };

      # Extra emitters produce optional keys in the result.
      extraKeys = lib.remove "homeFiles" usedTags;
      extras    = lib.listToAttrs
        (map (tag: lib.nameValuePair tag (dispatchOne tag)) extraKeys);
    in
    { inherit homeFiles; } // extras;

  # ── 3f · mergeHomeFiles ───────────────────────────────────────────────────
  # Home-manager-native combinator.
  #
  # Returns: MergeResult
  #   homeFiles  :: HomeFiles   → assign to: home.file = result.homeFiles
  #   activation :: Activation  → assign to:
  #                   home.activation.<name> =
  #                     lib.hm.dag.entryAfter ["writeBoundary"] result.activation;
  #
  # Emitter semantics:
  #   "symlink" (default)
  #     Produces: homeFiles { source = absPath; }
  #     home-manager installs a read-only symlink into the Nix store.
  #
  #   "copy"
  #     Produces: activation script lines
  #       run mkdir -p "$(dirname "$HOME/<key>")"
  #       run cp --remove-destination <store-path> "$HOME/<key>"
  #       run chmod u+w "$HOME/<key>"
  #     Real writable file after activation.
  #     Also evicts the key from homeFiles (copy eviction rule).
  #
  #   "text"
  #     Produces: homeFiles { text = entry.text; }
  #     Requires the policy's `transform` to inject `entry.text`.
  #
  # HomePolicy fields (all optional):
  #   include    :: [ Pattern ]
  #   exclude    :: [ Pattern ]
  #   transform  :: relPath → entry → (entry | null)
  #   emitter    :: "symlink" | "copy" | "text"     default: "symlink"
  #   destPrefix :: string                          default: ""
  #   priority   :: int                             default: 5
  #   force      :: bool                            default: false
  #                 When true, sets force=true on homeFiles entries.
  #                 Has no effect on "copy" entries (file is always replaced).
  #
  # FIX v4:
  #   - `force` field now supported per-HomePolicy (propagated to homeFiles).
  #   - Activation script uses `run` helper (respects DRY_RUN / VERBOSE).
  #   - Deterministic key ordering for stable diffs.
  #   - Unified with applyPolicy internals to reduce duplication.
  mergeHomeFiles = files: policies:
    let
      defaultHomePolicy = {
        include    = [ ];
        exclude    = [ ];
        transform  = _relPath: entry: entry;
        emitter    = "symlink";
        destPrefix = "";
        priority   = 5;
        force      = false;
      };

      # Produce a decision map keyed by destination key for one policy.
      # { "<destKey>" = { key; emitter; absPath; ?text; force; priority; }; }
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
              emitter  = p.emitter;
              absPath  = entry.absPath;
              text     = entry.text or null;
              force    = p.force;
              priority = p.priority;
            })
          cleaned;

      # Fold policies left-to-right → last-wins per destination key.
      allDecisions =
        lib.foldl'
          (acc: policy: acc // policyDecisions policy)
          { }
          policies;

      # Deterministic key ordering for stable activation scripts.
      sortedKeys = lib.sort lib.lessThan (builtins.attrNames allDecisions);

      # Split decisions into homeFiles attrset and activation script lines.
      finalResult =
        lib.foldl'
          (acc: key:
            let d = allDecisions.${key}; in

            # ── "copy" → activation script; evict from homeFiles ───────────
            if d.emitter == "copy" then
              acc // {
                homeFiles      = builtins.removeAttrs acc.homeFiles [ key ];
                activationCmds = acc.activationCmds ++ [
                  ''
                    run mkdir -p "$(dirname "$HOME/${key}")"
                    run cp --remove-destination ${lib.escapeShellArg d.absPath} "$HOME/${key}"
                    run chmod u+w "$HOME/${key}"
                  ''
                ];
              }

            # ── "text" → homeFiles (requires transform to set entry.text) ──
            else if d.emitter == "text" then
              if d.text == null
              then orchError "mergeHomeFiles" ''
                emitter="text" requires a transform that sets entry.text,
                but key "${key}" has no text field.

                Fix: add a transform to the policy, for example:
                  transform = _: e: e // { text = builtins.readFile e.absPath; };
                Or with a header:
                  transform = _: e: e // { text = "# managed by Nix\n" + builtins.readFile e.absPath; };
              ''
              else
                let
                  base  = { text = d.text; };
                  entry = if d.force then base // { force = true; } else base;
                  final = if d.priority != 5 then lib.mkOrder d.priority entry else entry;
                in
                acc // { homeFiles = acc.homeFiles // { "${key}" = final; }; }

            # ── "symlink" (default) → homeFiles ───────────────────────────
            else
              let
                base  = { source = d.absPath; };
                entry = if d.force then base // { force = true; } else base;
                final = if d.priority != 5 then lib.mkOrder d.priority entry else entry;
              in
              acc // { homeFiles = acc.homeFiles // { "${key}" = final; }; })

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
  #   src        :: Path
  #   recursive  :: bool           default: true
  #   policies   :: [ Policy ]     ordered; last-match-wins per file
  #                                [] → all files pass through as "homeFiles"
  #   destPrefix :: string         default: ""   homeFiles keys only
  #   pkgs       :: Pkgs           required for "derivation" or "symlinkTree"
  #   name       :: string         default: "config-tree"
  #   emitters   :: AttrSet        default: builtinEmitters (plugin point)
  #
  # Returns EmitResult (via emit):
  #   { homeFiles; ?derivation; ?symlinkTree; ?<custom>; }
  #
  # Internal state machine:
  #   policies == [] → Discovery → tagAll           → emit
  #   policies != [] → Discovery → applyPolicies    → emit
  readConfigDir =
    { src
    , recursive  ? true
    , policies   ? [ ]
    , destPrefix ? ""
    , pkgs       ? null
    , name       ? "config-tree"
    , emitters   ? builtinEmitters
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

      # INVARIANT: processed MUST be a TaggedMap (emitter + priority on every entry).
      processed =
        if policies == [ ]
        then tagAll raw
        else applyPolicies policies raw;
    in
    emit {
      files      = processed;
      inherit destPrefix pkgs emitters;
      drvName    = name;
    };

in
{
  # ── Public constants ───────────────────────────────────────────────────────
  # Expose the default emitter registry so callers can extend it.
  defaultEmitters = builtinEmitters;

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
  inherit defaultPolicy;

  # ── Layer 3 ────────────────────────────────────────────────────────────────
  inherit toHomeFiles;
  inherit toDerivation;
  inherit toSymlinkTree;
  inherit registerEmitter;
  inherit emit;
  inherit mergeHomeFiles;

  # ── High-level ─────────────────────────────────────────────────────────────
  inherit readConfigDir;
}
