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
│  registerEmitter (plugin registry)                                      │
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

## Communication Protocol (inter-layer data contracts)

```
FileMap   :: { "rel/path" = { absPath :: string; type :: string; }; }

TaggedMap :: FileMap entries extended with:
             { emitter  :: string        -- dispatch key
               priority :: int           -- home-manager mkMerge priority
               ?text    :: string        -- inline content (from transform)
               ?force   :: bool          -- propagated to home.file force field
             }

HomeFiles :: { "dest/key" = { source :: string; }
                           | { text   :: string; }
                           [// { force :: bool; }]
                           [wrapped in lib.mkOrder priority]
             }

Activation :: string   (shell script lines, uses `run` helper)

EmitResult  :: { homeFiles    :: HomeFiles
                 ?derivation  :: StorePath
                 ?symlinkTree :: StorePath
                 ?<custom>    :: any          -- from registerEmitter
               }

MergeResult :: { homeFiles  :: HomeFiles
                 activation :: Activation
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
raw `FileMap` is passed through `tagAll` before reaching `emit`.

---

## State Machine / Lifecycle

```
                           ┌─────────────────────────────┐
                           │        NIX EVAL TIME         │
                           └─────────────────────────────┘
                                         │
              src (Nix path)             │
                   │                     │
                   ▼                     │
          ┌─────────────────┐           │
          │  Layer 1        │           │
          │  Discovery      │           │
          │  (FileMap)      │           │
          └────────┬────────┘           │
                   │                     │
          ┌────────▼────────┐           │
          │  Layer 2        │           │
          │  Policy Engine  │           │
          │  (TaggedMap)    │  ← invariant enforced here
          └────────┬────────┘           │
                   │                     │
          ┌────────▼────────┐           │
          │  Layer 3        │           │
          │  Emitter        │           │
          │  Dispatch       │           │
          │  (EmitResult /  │           │
          │   MergeResult)  │           │
          └─────────────────┘           │
                                         │
                           ┌─────────────────────────────┐
                           │   HOME-MANAGER SWITCH        │
                           └─────────────────────────────┘
                                         │
                   ┌─────────────────────┼────────────────────┐
                   │  checkLinkTargets   │  writeBoundary      │
                   │  (pre-write)        │  (symlinks placed)  │
                   └─────────────────────┼────────────────────┘
                                         │
                            activation scripts run:
                              run mkdir -p …
                              run cp --remove-destination …  ← "copy" emitter
                              run chmod u+w …
                                         │
                           ┌─────────────────────────────┐
                           │         RUNTIME              │
                           └─────────────────────────────┘
                                         │
                       wallust / pywal / … write into copied files
```

---

## Data Flow

```
src (Nix path)
  │
  │  Layer 1: Discovery
  ▼
FileMap
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
TaggedMap
  │
  │  Layer 3: Emitter Dispatch
  │  split by emitter tag, dispatch to registered builders
  │
  │  emit / readConfigDir path:
  │    "homeFiles"    → toHomeFiles   → home.file attrset
  │    "derivation"   → toDerivation  → Nix store path
  │    "symlinkTree"  → toSymlinkTree → Nix store path
  │    <custom>       → registered builder via registerEmitter
  │
  │  mergeHomeFiles path:
  │    "symlink"  → homeFiles    { source = absPath; ?force; ?mkOrder }
  │    "copy"     → activation   run cp …
  │    "text"     → homeFiles    { text = entry.text; ?force; ?mkOrder }
  ▼
EmitResult | MergeResult
```

---

## Layer 1 — File Discovery

**Responsibility:** translate a Nix path into a flat attrset of
`{ relPath → { absPath, type } }` entries.

**Key design decisions:**

- `listFilesRecursive` is intentionally inclusive — it returns symlinks,
  regular files, and unknowns. Filtering is policy's job.
- `listFilesRecursiveFiltered` provides a discovery-time fast-path for
  the common case of dropping symlinks, preventing duplicate entries.
- `readDirFlat` is the non-recursive primitive.

---

## Layer 2 — Policy Engine

**Responsibility:** tag each file with `{ emitter; priority }`, optionally
transform content, and exclude files that don't match.

**Key design decisions:**

- **Data-driven policies:** a policy is a plain attrset, not a function.
  Serialisable, inspectable, and composable.
- **Last-match-wins composition:** `applyPolicies` folds left over the
  policy list with attrset merge (`//`). Later policies override earlier ones.
- **Explicit exclude:** separate `include` and `exclude` lists.
- **Transform as escape hatch:** full flexibility — modify the entry, inject
  inline text, or return `null` to drop the file.
- **`tagAll` as the zero-policy fast path:** when no policies exist, all
  files pass through as `homeFiles`. Preserves the TaggedMap invariant
  without the pattern-matching overhead.

**Pattern matching dispatch order:**

```
"*"      → universal wildcard
"/ERE/"  → builtins.match (POSIX extended regex)
"*.ext"  → suffix match (leading *)
"dir/*"  → prefix match (trailing *)
"dir/"   → prefix match (plain string)
```

---

## Layer 3 — Emitters

**Responsibility:** take a TaggedMap and produce home-manager-compatible output.

### Emitter registry (plugin architecture)

```
builtinEmitters (default registry):
  "homeFiles"    → toHomeFiles   → home.file attrset (symlinks via HM)
  "derivation"   → toDerivation  → Nix store derivation (physical copy)
  "symlinkTree"  → toSymlinkTree → Nix store derivation (symlink tree)

Extension via registerEmitter:
  registerEmitter registry name builder
  → new registry with name → builder added
```

Builder signature:

```nix
builder :: { files :: TaggedMap; destPrefix :: string; pkgs :: Pkgs?; drvName :: string } → any
```

### Two dispatch paths

`emit`/`readConfigDir` operate at the Nix build level — they produce store
paths and attrsets. `mergeHomeFiles` operates at the home-manager activation
level — it produces home.file entries and shell scripts. They are intentionally
kept separate because they serve different use cases.

### The symlink constraint

home-manager's `home.file` and `xdg.configFile` **always install as
symlinks** into the read-only Nix store. This is not a limitation of
this library — it is a fundamental property of home-manager's design.

The `"copy"` emitter in `mergeHomeFiles` works around this by generating
a `home.activation` script that runs `cp` after the symlink phase,
producing a real writable file on disk.

### Priority propagation (fix)

In v3 and earlier, `priority` was stored in the `TaggedMap` but never applied
to the resulting home.file entries. In v4, `toHomeFiles` and `mergeHomeFiles`
both wrap entries with `lib.mkOrder priority` when `priority != 5`. This
allows downstream `home-manager` `mkMerge` to respect the caller's ordering
intent.

### Copy eviction rule

When a `"copy"` policy matches a key already in `homeFiles` from a prior
`"symlink"` policy, the key is evicted from `homeFiles`. This prevents a
conflict between the home.file symlink and the activation script's `cp`.

### Force propagation (addition)

`mergeHomeFiles` policies now accept a `force :: bool` field (default: false).
When `true`, the generated home.file entry carries `force = true`, which tells
home-manager to unconditionally replace the target. This mirrors the behaviour
of `xdg.configFile.<name>.force`.

---

## High-level entry points

### readConfigDir

1. Discovers files (Layer 1)
2. **If `policies = []`:** `tagAll` → emit
3. **If `policies != []`:** `applyPolicies` → emit
4. `emit` dispatches to the registered emitter builders

### mergeHomeFiles

1. Folds policies to produce a `{ destKey → decision }` map
2. Sorts keys deterministically (stable diffs)
3. Splits decisions into `homeFiles` and `activationCmds`

Note: `mergeHomeFiles` runs its own internal policy loop, not via
`applyPolicies`, because it needs per-policy `destPrefix` and `force`
fields in addition to the standard policy contract.

---

## Design principles summary

| Principle            | How it manifests                                              |
| -------------------- | ------------------------------------------------------------- |
| Dependency inversion | Callers depend on policy abstractions, not filesystem layout  |
| Pipeline / dataflow  | Discovery → Policy → Emit; each stage is a pure function      |
| Layered architecture | Each layer exposes a stable, composable interface             |
| Data-driven          | Behaviour driven by policy attrsets, not hard-coded logic     |
| Open/closed          | Extend via `registerEmitter` and transforms, not source edits |
| Explicit boundaries  | home.file symlinks vs. activation `cp` are kept distinct      |
| Incremental          | Policies compose; last-match-wins enables override idiom      |
| Fail-early           | TaggedMap invariant enforced at eval time, not activation     |
| Plugin architecture  | `registerEmitter` for custom emitter types                    |
| Single-source        | No patch/fix files; all fixes consolidated in lib/default.nix |

---

## Extension points

| To extend…             | Do this…                                                          |
| ---------------------- | ----------------------------------------------------------------- |
| Add a new pattern type | Extend `matchesPattern` dispatch in lib/default.nix               |
| Add a new emit emitter | `registerEmitter orc.defaultEmitters "name" builder`              |
| Add a new home emitter | Fork `mergeHomeFiles` with an extra branch in `finalResult` fold  |
| Compose multiple trees | Call `mergeHomeFiles` multiple times; merge `homeFiles` with `//` |
| Add per-file metadata  | Use `transform` to inject custom fields into entries              |
| Tag without policies   | Use `tagAll` to pass all files through as `homeFiles`             |
