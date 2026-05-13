# Architecture

## Overview

ConfigurationOrchestrator is a pure-Nix library structured as three
composable layers with a high-level entry point on top.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  readConfigDir  (high-level)                                            │
│  mergeHomeFiles (high-level, home-manager specific)                     │
├─────────────────────────────────────────────────────────────────────────┤
│  Layer 3 · Emitter Dispatch                                             │
│  emit · toHomeFiles · toDerivation · toSymlinkTree                      │
├─────────────────────────────────────────────────────────────────────────┤
│  Layer 2 · Policy Engine                                                │
│  applyPolicy · applyPolicies · tagAll                                   │
│  matchesPattern · matchesAny                                            │
├─────────────────────────────────────────────────────────────────────────┤
│  Layer 1 · File Discovery                                               │
│  readDirFlat · listFilesRecursive · listFilesRecursiveFiltered          │
└─────────────────────────────────────────────────────────────────────────┘
```

Every layer is a **pure function** — no ImpureIO, no side effects.
Side effects (symlinking, copying) are deferred to home-manager's activation
and build phases.

---

## Data flow

```
src (Nix path)
  │
  │  Layer 1: Discovery
  ▼
FileMap :: { "rel/path" = { absPath :: string; type :: string; }; }
  │
  │  Layer 2: Policy / Tagging
  │
  │  path A: policies != []
  │    applyPolicies: each policy tags matching files with { emitter; priority }
  │    last-match-wins per file; unmatched files are dropped
  │
  │  path B: policies == []
  │    tagAll: stamps ALL files with default emitter and priority
  │    no filtering — all discovered files survive
  ▼
TaggedMap :: { "rel/path" = { absPath; type; emitter; priority; ?text; }; }
  │
  │  Layer 3: Emitter Dispatch
  │  split by emitter tag, dispatch to builders
  ▼
EmitResult :: {
  homeFiles    :: { "dest/key" = { source | text; ?force; }; }
  derivation   :: StorePath   (optional)
  symlinkTree  :: StorePath   (optional)
}

  OR (mergeHomeFiles path):

MergeResult :: {
  homeFiles  :: { "dest/key" = { source | text; }; }
  activation :: string   (shell script for home.activation)
}
```

### TaggedMap invariant

The **TaggedMap invariant** is the key contract between Layer 2 and Layer 3:
every entry flowing into `emit` or `toHomeFiles` **must** have `emitter` and
`priority` attributes.

Violation (passing a raw `FileMap` to `emit`) causes:

```
error: attribute 'emitter' missing
```

This is enforced at the `readConfigDir` boundary: when `policies = []`, the
raw `FileMap` is passed through `tagAll` before reaching `emit`. Callers who
use `emit` directly are responsible for tagging their files first.

---

## Lifecycle

```
Nix eval time
  └── Discovery   (Layer 1)
  └── Policy      (Layer 2)
  └── Emit        (Layer 3)
       ├── homeFiles   → home.file attrset (resolved at activation time)
       ├── derivation  → Nix store path    (built by nix-build / nix store)
       └── symlinkTree → Nix store path    (built by nix-build / nix store)

home-manager switch
  └── writeBoundary
  └── activation scripts
       └── run cp ...   (places real writable files from "copy" emitter)
       └── run chmod ... (makes files writable for runtime tools)

Runtime
  └── wallust, pywal, etc. write into the copied files
```

---

## Layer 1 — File Discovery

**Responsibility:** translate a Nix path into a flat attrset of
`{ relPath → { absPath, type } }` entries.

**Key design decisions:**

- `listFilesRecursive` is intentionally inclusive — it returns symlinks,
  regular files, and unknowns. Filtering is policy's job.
- `listFilesRecursiveFiltered` provides a discovery-time fast-path for
  the common case of dropping symlinks. This prevents duplicate entries
  that would arise if both `hypridle.conf` (root symlink) and
  `sys/hypridle.conf` (real file) were discovered and mapped to the same
  destination in home.file.
- `readDirFlat` is the non-recursive primitive. Both recursive functions
  are built on top of `builtins.readDir`.

---

## Layer 2 — Policy Engine

**Responsibility:** tag each file with an `{ emitter; priority }` pair,
optionally transform its content, and exclude files that don't match.

**Key design decisions:**

- **Data-driven policies:** a policy is a plain attrset, not a function.
  This makes policies serialisable, inspectable, and composable.
- **Last-match-wins composition:** `applyPolicies` folds left over the
  policy list, using attrset merge (`//`). This means a later policy
  can override the emitter of a file matched by an earlier policy.
- **Explicit exclude:** include and exclude are separate lists, allowing
  `include = [ "sys/" ]; exclude = [ "*.png" ]` without needing to
  express "sys/ except \*.png" as a single pattern.
- **Transform as escape hatch:** the `transform` function gives full
  flexibility — it can modify the entry, inject inline text, or return
  `null` to drop the file entirely.
- **`tagAll` as the zero-policy fast path:** when no policies exist, all
  files should pass through as `homeFiles`. `tagAll` stamps every entry
  without running the pattern-matching engine. This preserves the
  TaggedMap invariant without overhead.

**Pattern matching dispatch order:**

```
"/ERE/"  → builtins.match (POSIX extended regex)
"*"      → universal wildcard
"*.ext"  → suffix match (leading *)
"dir/*"  → prefix match (trailing *)
"dir/"   → prefix match (plain string)
```

---

## Layer 3 — Emitters

**Responsibility:** take a TaggedMap and produce home-manager-compatible output.

### Emitter taxonomy

```
emit / readConfigDir path:
  "homeFiles"    → toHomeFiles   → home.file attrset
  "derivation"   → toDerivation  → Nix store derivation (physical copy)
  "symlinkTree"  → toSymlinkTree → Nix store derivation (symlink tree)

mergeHomeFiles path:
  "symlink"      → homeFiles     → { source = absPath; }
  "copy"         → activation    → run cp ...  (real writable file)
  "text"         → homeFiles     → { text = entry.text; }
```

### Why two separate paths?

`emit`/`readConfigDir` operate at the Nix build level — they produce
store paths. `mergeHomeFiles` operates at the home-manager activation
level — it produces home.file entries and shell scripts. They serve
different use cases and are intentionally kept separate.

### The symlink constraint

home-manager's `home.file` and `xdg.configFile` **always install as
symlinks** into the read-only Nix store. This is not a limitation of
this library; it is a fundamental property of home-manager's design.
See `home-manager/modules/files.nix` and `home-manager/modules/home-environment.nix`.

The `"copy"` emitter in `mergeHomeFiles` works around this by generating
a `home.activation` script that runs `cp` after the symlink phase,
producing a real writable file on disk.

### Copy eviction rule

When a `"copy"` policy matches a key that was already placed in
`homeFiles` by a prior `"symlink"` policy (due to last-wins processing),
the key is evicted from `homeFiles` to prevent a conflict between the
home.file symlink and the activation script's `cp`.

---

## High-level entry points

### readConfigDir

Convenience wrapper that enforces the TaggedMap invariant:

1. Calls `listFilesRecursive` (recursive) or flat map (non-recursive)
2. **If `policies = []`:** calls `tagAll` to tag all files as `"homeFiles"`
3. **If `policies != []`:** calls `applyPolicies`
4. Calls `emit`

### mergeHomeFiles

The home-manager-native combinator that:

1. Processes each policy's decisions into a `{ destKey → decision }` map
2. Folds policies in order (last-wins per key)
3. Sorts keys deterministically before generating the activation script
4. Splits decisions into `homeFiles` and `activationCmds`

Note: `mergeHomeFiles` operates directly on a `FileMap` — it runs its own
internal policy loop (not via `applyPolicies`) and never calls `emit`.

---

## Extension points

| To extend…             | Do this…                                                          |
| ---------------------- | ----------------------------------------------------------------- |
| Add a new pattern type | Extend `matchesPattern` dispatch                                  |
| Add a new emitter type | Add a case to `emit`'s `byEmitter` split                          |
| Add a new home emitter | Add a case to `mergeHomeFiles`'s `finalResult` fold               |
| Compose multiple trees | Call `mergeHomeFiles` multiple times; merge `homeFiles` with `//` |
| Add per-file metadata  | Use `transform` to inject custom fields into entries              |
| Tag without policies   | Use `tagAll` to pass all files through as `homeFiles`             |
