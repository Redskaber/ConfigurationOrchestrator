# ConfigurationOrchestrator

A pure-Nix library for reading, filtering, transforming, and emitting
configuration directory trees with **per-file emitter control**.

```
lib/default.nix    — pure function library (three layers)
tests/default.nix  — test suite
tests/flake.nix    — test harness (hypr-config fixture lives here only)
flake.nix          — public interface: lib.<system>
```

---

## Why this exists

`xdg.configFile` and `home.file` in home-manager apply **one strategy to the
whole tree**. You often need finer control:

| Scenario                               | Best strategy                                  |
| -------------------------------------- | ---------------------------------------------- |
| Large stable config tree               | `xdg.configFile` recursive symlink (simplest)  |
| One file written by a tool at runtime  | `mergeHomeFiles` `"copy"` emitter              |
| Mix of stable files + runtime-writable | `xdg.configFile` + `mergeHomeFiles` activation |
| Per-file emitter dispatch at scale     | `emit` / `readConfigDir`                       |

---

## home-manager fundamentals

### home.file and xdg.configFile always use symlinks

Both `home.file` and `xdg.configFile` in home-manager **always install as
symlinks** into the read-only Nix store — regardless of `force`, `text`, or
`source`. This is the core constraint that drives this library's design.

Relevant options from home-manager:

| Option                        | Purpose                                                          |
| ----------------------------- | ---------------------------------------------------------------- |
| `home.file.<name>.source`     | Path to source file or directory in the Nix store                |
| `home.file.<name>.text`       | Inline text; home-manager writes it to a store path and symlinks |
| `home.file.<name>.force`      | Unconditionally replace target (even if module-generated)        |
| `home.file.<name>.recursive`  | Recursively link a directory tree's leaves                       |
| `home.file.<name>.onChange`   | Shell commands to run when the file changes between generations  |
| `home.file.<name>.executable` | Set the execute bit on the linked file                           |
| `xdg.configFile.<name>.*`     | Same options, but paths are relative to `$XDG_CONFIG_HOME`       |

The **only** way to produce a real writable file is via `home.activation`,
which runs shell commands after the linking phase. The `"copy"` emitter in
`mergeHomeFiles` generates an activation script that `cp`s the file using
the `run` helper (respects `DRY_RUN` and `VERBOSE`).

### home.activation

`home.activation` entries are DAG nodes that run after linking. Each entry
must be idempotent and must respect:

- `DRY_RUN` — if set, log but don't perform actions
- `VERBOSE` / `VERBOSE_ARG` — if set, print debug information

The library uses the `run` helper in generated activation scripts:

```sh
run mkdir -p "$(dirname "$HOME/key")"
run cp --remove-destination /nix/store/... "$HOME/key"
run chmod u+w "$HOME/key"
```

Your module must place the activation script after `writeBoundary`:

```nix
home.activation.myScript =
  lib.hm.dag.entryAfter [ "writeBoundary" ] result.activation;
```

---

## Architecture

```
src (path)
  │
  ▼  Layer 1 · Discovery
  │  listFilesRecursive / listFilesRecursiveFiltered / readDirFlat
  │  { "rel/path" = { absPath; type; }; ... }
  │
  ▼  Layer 2 · Policy Engine
  │  applyPolicy / applyPolicies / tagAll
  │  Each policy tags matching files with { emitter; priority; ?text; ... }
  │  tagAll stamps every file with the default emitter when no policies exist.
  │  Policies compose: LAST match wins per file.
  │  { "rel/path" = { absPath; type; emitter; priority; ?text; }; ... }
  │
  ▼  Layer 3 · Emitter Dispatch
     ┌──────────────────────────────────────────────────────────────┐
     │  emit / readConfigDir                                        │
     │                                                              │
     │  "homeFiles"    "derivation"    "symlinkTree"                │
     │  home.file      physical copy   symlink tree                 │
     │  attrset        store path      store path                   │
     └──────────────────────────────────────────────────────────────┘
     Returns: { homeFiles; ?derivation; ?symlinkTree; }

     ─── mergeHomeFiles ─────────────────────────────────────────────
     Returns: { homeFiles; activation }
       "symlink"  → homeFiles   { source = absPath; }   read-only symlink
       "copy"     → activation  run cp absPath $HOME/key  real writable file
       "text"     → homeFiles   { text = entry.text; }  symlink to generated file
```

### TaggedMap invariant

**`emit` and `toHomeFiles` require a TaggedMap** — every entry must have
`emitter` and `priority` attributes. This is the contract between Layer 2 and
Layer 3. Use one of:

- `applyPolicy policy files` — tag files matched by a single policy
- `applyPolicies policies files` — fold multiple policies (last-wins)
- `tagAll files` — stamp all files with the default emitter (`"homeFiles"`, priority 5)

`readConfigDir` enforces this invariant internally: when `policies = []` it
calls `tagAll` before handing files to `emit`.

**Core design principle:** the emitter is a property of each file, set by its
policy — not a global switch for the whole tree.

### Design principles

| Principle            | How it manifests                                             |
| -------------------- | ------------------------------------------------------------ |
| Dependency inversion | Callers depend on policy abstractions, not filesystem layout |
| Pipeline / dataflow  | Discovery → Policy → Emit; each stage is a pure function     |
| Layered architecture | Each layer exposes a stable, composable interface            |
| Data-driven          | Behaviour driven by policy attrsets, not hard-coded logic    |
| Open/closed          | Extend via new policies and transforms, not source edits     |
| Explicit boundaries  | home.file symlinks vs. activation `cp` are kept distinct     |
| Incremental          | Policies compose; last-match-wins enables override idiom     |

---

## Common pitfall: conflicting managed target files

```
error: Failed assertions:
- Conflicting managed target files: .config/hypr/hyprland.conf
```

Two modules are declaring the same destination file. Diagnose with:

```bash
nix eval .#homeConfigurations."user@host".config.home.file --json \
  | jq 'to_entries | map(select(.key | contains("hyprland.conf"))) | .'
```

**Cause A — `wayland.windowManager.hyprland` generates `hyprland.conf`**

When the hyprland module has `settings`, `extraConfig`, or plugins configured,
it generates `.config/hypr/hyprland.conf`. Any other module also writing that
path causes a conflict.

The correct fix is to use `xdg.configFile` with `force = true`, which tells
home-manager to let your file win over the module-generated one:

```nix
xdg.configFile."hypr" = {
  source    = inputs.hypr-config;
  recursive = true;
  force     = true;   # your hyprland.conf wins over the module-generated one
};
```

**Cause B — `listFilesRecursive` sees both a symlink and its target**

`hypr-config` root may contain alias symlinks like
`hypridle.conf → sys/hypridle.conf`. Using `listFilesRecursive` picks up both
the root-level symlink and the real file under `sys/`, potentially generating
two `home.file` entries that collide. Use `listFilesRecursiveFiltered` to skip
symlinks at discovery time:

```nix
files = orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ];
```

---

## Layer 1 — File Discovery

```nix
# Non-recursive: { "name" = "regular"|"directory"|"symlink"|"unknown"; }
readDirFlat dir

# Recursive — includes ALL non-directory entries (regular, symlink, …)
listFilesRecursive dir ""

# Recursive — skips entries whose type is in skipTypes at discovery time
listFilesRecursiveFiltered dir "" [ "symlink" ]
```

---

## Layer 2 — Policy

A **policy** is an attrset — all fields optional:

```nix
{
  include   = [ "sys/" "*.conf" ];    # [] = accept everything (same as ["*"])
  exclude   = [ "*.png" ];            # [] = drop nothing
  transform = relPath: entry:         # return null to drop the file
    entry // { text = "# header\n" + builtins.readFile entry.absPath; };
  emitter   = "homeFiles";            # "homeFiles" | "derivation" | "symlinkTree"
  priority  = 5;                      # home-manager mkMerge priority
}
```

`applyPolicies` processes the list in order. **Last match wins** per file:

```nix
applyPolicies [
  { include = [ "sys/" ]; emitter = "symlinkTree"; }            # broad base
  { include = [ "sys/startup.conf" ]; emitter = "derivation"; } # override
] allFiles
```

`tagAll` stamps all files with the default emitter without filtering:

```nix
# Equivalent to applyPolicies [{ include = []; emitter = "homeFiles"; }] files
# but cheaper — no pattern matching, no filter pass.
tagAll files
```

**Pattern syntax:**

| Pattern           | Semantics                                          |
| ----------------- | -------------------------------------------------- |
| `[]` or `[ "*" ]` | accept everything                                  |
| `"sys/"`          | prefix match                                       |
| `"*.conf"`        | suffix match                                       |
| `"sys/*"`         | prefix match (trailing `*` stripped)               |
| `"/ERE/"`         | POSIX extended regular expression (builtins.match) |

---

## Layer 3 — Emitters

### Low-level helpers

```nix
toHomeFiles   destPrefix files          # → home.file attrset (symlinks)
toDerivation  { pkgs, name, files }     # → store path (physical copy)
toSymlinkTree { pkgs, name, files }     # → store path (symlink tree)
```

### `emit` — multi-emitter dispatch

```nix
emit { files; destPrefix?; pkgs?; drvName?; }
→ { homeFiles; ?derivation; ?symlinkTree; }
```

### `mergeHomeFiles` — returns `{ homeFiles; activation; }`

```nix
mergeHomeFiles files policies
→ { homeFiles  :: attrset;   # → home.file = result.homeFiles
    activation :: string;    # → home.activation.<n> =
                             #     lib.hm.dag.entryAfter ["writeBoundary"]
                             #       result.activation
  }
```

| `emitter`   | destination  | result                                                    |
| ----------- | ------------ | --------------------------------------------------------- |
| `"symlink"` | `homeFiles`  | read-only symlink into Nix store                          |
| `"copy"`    | `activation` | **real writable file** — `run cp` on every activation     |
| `"text"`    | `homeFiles`  | symlink to store-generated text file (requires transform) |

**copy eviction rule:** if a `"copy"` policy matches a key that was already
placed in `homeFiles` by a prior `"symlink"` policy, the key is evicted from
`homeFiles` and moved exclusively to the activation script. This ensures no
conflict between home.file and activation.

---

## Usage

### Add as a flake input

```nix
inputs.configuration-orchestrator.url =
  "github:redskaber/ConfigurationOrchestrator";
```

```nix
orc = inputs.configuration-orchestrator.lib.${pkgs.system};
```

---

### home-manager examples

#### 1 — xdg.configFile + activation (recommended for hyprland)

```nix
{ inputs, shared, lib, ... }:
let
  hyprResult = shared.orc.mergeHomeFiles (
    shared.orc.listFilesRecursive inputs.hypr-config ""
  ) [
    { include    = [ "sys/policy/wallust/wallust-hyprland.conf" ];
      emitter    = "copy";
      destPrefix = ".config/hypr"; }
  ];
in
{
  xdg.configFile."hypr" = {
    source    = inputs.hypr-config;
    recursive = true;
    force     = true;
  };

  home.activation.hyprWallust =
    lib.hm.dag.entryAfter [ "writeBoundary" ] hyprResult.activation;
}
```

#### 2 — mergeHomeFiles only (no xdg.configFile conflict)

```nix
{ inputs, pkgs, lib, ... }:
let
  orc    = inputs.configuration-orchestrator.lib.${pkgs.system};
  files  = orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ];
  result = orc.mergeHomeFiles files [
    { include    = [ ];
      exclude    = [ "*.png" ];
      emitter    = "symlink";
      destPrefix = ".config/hypr"; }
    { include    = [ "sys/policy/wallust/wallust-hyprland.conf" ];
      emitter    = "copy";
      destPrefix = ".config/hypr"; }
  ];
in
{
  home.file = result.homeFiles;
  home.activation.hyprWallust =
    lib.hm.dag.entryAfter [ "writeBoundary" ] result.activation;
}
```

#### 3 — simple: everything as home.file (no policies needed)

```nix
# policies = [] → tagAll → all files become homeFiles entries automatically
home.file = (orc.readConfigDir {
  src        = inputs.hypr-config;
  recursive  = true;
  destPrefix = ".config/hypr";
}).homeFiles;
```

#### 4 — symlink tree + home.file (large stable trees)

```nix
let result = orc.readConfigDir {
  src        = inputs.hypr-config;
  inherit pkgs;
  recursive  = true;
  destPrefix = ".config/hypr";
  name       = "hypr-config";
  policies   = [
    { include = [ "sys/" ]; exclude = [ "*.png" ]; emitter = "symlinkTree"; }
    { include = [ "user/" ]; emitter = "homeFiles"; }
  ];
}; in
{
  home.file = result.homeFiles;
  xdg.configFile."hypr/sys".source = result.symlinkTree;
}
```

#### 5 — mergeHomeFiles: symlink + copy + text

```nix
{ inputs, pkgs, lib, ... }:
let
  orc    = inputs.configuration-orchestrator.lib.${pkgs.system};
  files  = orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ];
  result = orc.mergeHomeFiles files [
    { include = [ ]; exclude = [ "*.png" ]; emitter = "symlink";
      destPrefix = ".config/hypr"; }
    { include = [ "sys/hardware/" ]; emitter = "copy";
      destPrefix = ".config/hypr"; }
    { include = [ "sys/policy/wallust/wallust-hyprland.conf" ]; emitter = "copy";
      destPrefix = ".config/hypr"; }
    { include = [ "user/startup.conf" ]; emitter = "text";
      transform = _: e: e // {
        text = "# managed by Nix\n" + builtins.readFile e.absPath;
      };
      destPrefix = ".config/hypr"; }
  ];
in
{
  home.file = result.homeFiles;
  home.activation.hyprCopy =
    lib.hm.dag.entryAfter [ "writeBoundary" ] result.activation;
}
```

---

### NixOS examples

#### 6 — expose sys/ via environment.etc

```nix
{ pkgs, inputs, ... }:
let
  orc    = inputs.configuration-orchestrator.lib.${pkgs.system};
  result = orc.readConfigDir {
    src = inputs.hypr-config; inherit pkgs;
    recursive = true; name = "hypr-sys";
    policies = [ { include = [ "sys/" ]; exclude = [ "*.png" ]; emitter = "symlinkTree"; } ];
  };
in { environment.etc."hypr/sys".source = result.symlinkTree; }
```

#### 7 — NixOS + home-manager together

```nix
{ pkgs, inputs, ... }:
let
  orc    = inputs.configuration-orchestrator.lib.${pkgs.system};
  result = orc.readConfigDir {
    src = inputs.hypr-config; inherit pkgs;
    recursive = true; destPrefix = ".config/hypr"; name = "hypr-config";
    policies = [
      { include = [ "sys/" ]; exclude = [ "*.png" ]; emitter = "symlinkTree"; }
      { include = [ "user/" ]; emitter = "homeFiles"; }
    ];
  };
in
{
  environment.etc."hypr/sys".source = result.symlinkTree;
  home-manager.users.alice.home.file = result.homeFiles;
}
```

---

## Transform recipes

**Prepend a header:**

```nix
transform = relPath: entry:
  if lib.hasSuffix ".conf" relPath
  then entry // { text = "# managed by Nix\n" + builtins.readFile entry.absPath; }
  else entry;
```

**Drop a specific file:**

```nix
transform = relPath: entry:
  if relPath == "sys/secret.conf" then null else entry;
```

**Drop source-tree symlinks:**

```nix
# At discovery time (preferred — prevents duplicate home.file entries):
files = orc.listFilesRecursiveFiltered src "" [ "symlink" ];

# Or via transform (post-hoc):
transform = _: e: if e.type == "symlink" then null else e;
```

---

## Tests

```bash
cd tests
nix eval .#_summary
# { allPassed = true; passed = N; total = N; }

nix eval . --json | jq .layer3
nix eval . --json | jq ._summary
```

All 4 test groups must pass:

```
layer1    — File Discovery
layer2    — Policy Engine
layer3    — Emitter Dispatch
highLevel — readConfigDir (including noPolicies path)
```

---

## API reference

### `readConfigDir`

```
readConfigDir {
  src        :: path
  recursive  :: bool          (default: true)
  policies   :: [ policy ]    When [] all files pass through as "homeFiles"
  destPrefix :: string        (default: "")
  pkgs       :: pkgs          required for derivation / symlinkTree
  name       :: string        (default: "config-tree")
}
→ { homeFiles; ?derivation; ?symlinkTree; }
```

### `mergeHomeFiles`

```
mergeHomeFiles files [ homePolicy ]
→ { homeFiles :: attrset; activation :: string; }

homePolicy fields (all optional):
  include    :: [ pattern ]
  exclude    :: [ pattern ]
  transform  :: relPath → entry → entry | null
  emitter    :: "symlink" | "copy" | "text"   (default: "symlink")
  destPrefix :: string                         (default: "")
  priority   :: int                            (default: 5)

emitter destinations:
  "symlink"  → homeFiles   { source = absPath; }
  "copy"     → activation  run cp --remove-destination absPath $HOME/key
  "text"     → homeFiles   { text = entry.text; }   (requires transform)

eviction: a "copy" policy evicts the same key from homeFiles
          (even if placed there by a prior "symlink" policy).
```

### `emit`

```
emit { files; destPrefix?; pkgs?; drvName?; }
→ { homeFiles; ?derivation; ?symlinkTree; }

Precondition: every entry in `files` must have `emitter` and `priority`.
Use tagAll, applyPolicy, or applyPolicies before calling emit directly.
```

### `tagAll`

```
tagAll :: FileMap → TaggedMap

Stamps every entry with emitter = "homeFiles" and priority = 5.
Use when you want all files as home.file entries without any filtering.
Equivalent to applyPolicies [{ include = []; emitter = "homeFiles"; }] files
but without the pattern-matching overhead.
```

### Low-level exports

```
readDirFlat                  :: path → { name = type; }
listFilesRecursive           :: path → string → FileMap
listFilesRecursiveFiltered   :: path → string → [ type ] → FileMap
matchesPattern               :: relPath → pattern → bool
matchesAny                   :: relPath → [ pattern ] → bool
applyPolicy                  :: policy → files → TaggedMap
applyPolicies                :: [ policy ] → files → TaggedMap
tagAll                       :: FileMap → TaggedMap
toHomeFiles                  :: destPrefix → TaggedMap → HomeFiles
toDerivation                 :: { pkgs; name; files } → derivation
toSymlinkTree                :: { pkgs; name; files } → derivation
emit                         :: { files; destPrefix; pkgs; drvName } → EmitResult
mergeHomeFiles               :: FileMap → [ homePolicy ] → MergeResult
readConfigDir                :: { src; recursive; policies; destPrefix; pkgs; name } → EmitResult
```

---

## Changelog

### v3 (current)

- **Fix:** `readConfigDir` with `policies = []` now correctly passes a
  `TaggedMap` to `emit` instead of a raw `FileMap`. Previously, untagged
  entries caused `«error: attribute 'emitter' missing»` in `emit`'s
  `filterAttrs` call. The fix introduces `tagAll`, a lightweight helper that
  stamps all entries with the default emitter (`"homeFiles"`) and priority (5)
  without running the policy engine.
- **New:** `tagAll` exported as a first-class Layer-2 function. Useful when
  callers want all files as `homeFiles` entries without any filtering.
- **Docs:** `TaggedMap` invariant made explicit in `emit`'s contract comment,
  in the architecture section, and in the API reference.
- **Tests:** `t_readConfigDir_noPolicies` now passes (was
  `«error: attribute 'emitter' missing»` in v2).

### v2

- **Fix:** `listFilesRecursiveFiltered` now correctly propagates `skipTypes`
  into recursive directory calls (previously only filtered the top level).
- **Fix:** `mergeHomeFiles` activation script uses `run` helper (respects
  `DRY_RUN` / `VERBOSE` as required by `home.activation`).
- **Fix:** `mergeHomeFiles` iteration order is now deterministic (sorted keys)
  for stable activation script generation.
- **New:** `toHomeFiles` propagates `entry.force = true` to home.file entries.
- **New:** `mergeHomeFiles` `"copy"` emitter evicts the same key from
  `homeFiles` even if a prior policy placed it there.
- **New:** `readConfigDir` non-recursive mode (`recursive = false`) now works.
- **New:** `emit` asserts `pkgs != null` when `derivation` or `symlinkTree`
  emitters are used, with a clear error message.
- **New:** Multi-system support in root `flake.nix`
  (`x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`).
- **Tests:** Added `noSymlinksDeep`, `toHomeFiles_force`,
  `mergeHomeFiles_copyEvictsSymlink`, `readConfigDir_noPolicies`.
