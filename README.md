# ConfigurationOrchestrator

A pure-Nix library for reading, filtering, transforming, and emitting
configuration directory trees with per-file emitter control.

```
lib/default.nix    — pure function library (three layers)
test/default.nix   — test suite
test/flake.nix     — test harness (hypr-config fixture lives here only)
flake.nix          — public interface: lib.<system>
```

---

## Why this exists

`xdg.configFile` and `home.file` in home-manager apply one strategy to the
whole tree. In practice you need finer control:

| Scenario                                        | Best strategy                  |
| ----------------------------------------------- | ------------------------------ |
| `sys/` — read-only stable config                | symlink (fast, zero copy)      |
| `user/` — personal overrides                    | `home.file` source             |
| One file written by an external tool at runtime | physical copy (`force = true`) |
| A file needs a header injected                  | derivation + transform         |

There is no standard primitive for "symlink these, copy that one, patch this
one" at file granularity. ConfigurationOrchestrator is that primitive.

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
  │  applyPolicy / applyPolicies
  │  Each policy tags matching files with { emitter; priority; ?text; ... }
  │  Policies compose: last match wins per file.
  │  { "rel/path" = { absPath; type; emitter; priority; ?text; }; ... }
  │
  ▼  Layer 3 · Emitter Dispatch
     ┌──────────────────────────────────────────────────────────────┐
     │  emit / readConfigDir                                        │
     │                                                              │
     │  "homeFiles"    "derivation"    "symlinkTree"               │
     │  home.file      physical copy   symlink tree                │
     │  attrset        store path      store path                  │
     └──────────────────────────────────────────────────────────────┘
     Returns: { homeFiles; ?derivation; ?symlinkTree; }

     ─── mergeHomeFiles (home.file-only path) ──────────────────────
     Produces one home.file attrset with per-file emitter control:
       "symlink"  → { source = absPath; }
       "copy"     → { source = absPath; force = true; }
       "text"     → { text = entry.text; }
```

**Core design principle:** the emitter is a property of each file, set by
its policy — not a global switch for the whole tree.

---

## Common pitfall: conflicting managed target files

If you get:

```
error: Failed assertions:
- Conflicting managed target files: .config/hypr/hyprland.conf
```

This means two sources are mapping to the same destination. The most common
causes with hypr-config:

**Cause A — `wayland.windowManager.hyprland` conflict**
When home-manager's hyprland module is enabled, it automatically manages
`.config/hypr/hyprland.conf`. If you also include `hyprland.conf` from
the source tree, home-manager sees two owners for the same file. Fix:

```nix
# Exclude hyprland.conf — let the hyprland module manage it
{ include    = [ ];
  exclude    = [ "hyprland.conf" "*.png" ];
  emitter    = "symlink";
  destPrefix = ".config/hypr"; }
```

**Cause B — source-tree symlinks creating duplicate entries**
hypr-config root contains symlinks like `hypridle.conf → sys/hypridle.conf`.
`listFilesRecursive` records both the symlink and its target as separate
entries. When both are mapped to `.config/hypr/`, two entries collide.
Fix: use `listFilesRecursiveFiltered` to skip symlinks at discovery time:

```nix
files = orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ];
home.file = orc.mergeHomeFiles files [ … ];
```

---

## Layer 1 — File Discovery

```nix
# Non-recursive: { "name" = "regular"|"directory"|"symlink"|"unknown"; }
readDirFlat dir

# Recursive — includes ALL non-directory entries (regular, symlink, …)
listFilesRecursive dir ""

# Recursive — skips entries whose type is in skipTypes at discovery time
# Use to exclude source-tree symlinks before they enter the policy engine.
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

`applyPolicies` processes the list in order. **Last match wins** per file —
write a broad base policy, then narrow overrides for specific paths:

```nix
applyPolicies [
  { include = [ "sys/" ]; emitter = "symlinkTree"; }            # broad base
  { include = [ "sys/startup.conf" ]; emitter = "derivation"; } # override
] allFiles
# sys/startup.conf → derivation; everything else in sys/ → symlinkTree
```

**Pattern syntax:**

| Pattern           | Semantics                                |
| ----------------- | ---------------------------------------- |
| `[]` or `[ "*" ]` | accept everything (universal base layer) |
| `"sys/"`          | prefix match                             |
| `"*.conf"`        | suffix match                             |
| `"sys/*"`         | prefix match (trailing `*` strips)       |
| `"/ERE/"`         | POSIX extended regular expression        |

---

## Layer 3 — Emitters

### Low-level helpers

```nix
toHomeFiles   destPrefix files          # → home.file attrset
toDerivation  { pkgs, name, files }     # → store path (physical copy)
toSymlinkTree { pkgs, name, files }     # → store path (symlink tree)
```

`toHomeFiles` entry → home.file value:

| Entry field          | home.file value                       |
| -------------------- | ------------------------------------- |
| `entry.text` present | `{ text = …; }`                       |
| `entry.force = true` | `{ source = …; force = true; }`       |
| otherwise            | `{ source = absPath; }` plain symlink |

`force` is opt-in. Set via `transform = _: e: e // { force = true; }` or via
the `"copy"` emitter in `mergeHomeFiles`.

### `emit` — multi-emitter dispatch

```nix
emit {
  files;                 # from applyPolicies
  destPrefix ? "";       # prepended to homeFiles keys
  pkgs ? null;           # required for derivation / symlinkTree
  drvName ? "config-tree";
}
# → { homeFiles; ?derivation; ?symlinkTree; }
```

### `mergeHomeFiles` — per-file control in one home.file attrset

```nix
mergeHomeFiles files policies
```

Per-policy emitters:

| `emitter`   | home.file value                       | notes                             |
| ----------- | ------------------------------------- | --------------------------------- |
| `"symlink"` | `{ source = absPath; }`               | default                           |
| `"copy"`    | `{ source = absPath; force = true; }` | wallust, dynamic files            |
| `"text"`    | `{ text = entry.text; }`              | requires transform to inject text |

`"text"` without a transform that sets `entry.text` throws a descriptive error.

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

#### 1 — base-layer + point-override (recommended idiom)

All files as symlinks, one file as physical copy for tools that write at runtime:

```nix
# hypr-config root has symlink aliases (hypridle.conf → sys/hypridle.conf).
# Use listFilesRecursiveFiltered to skip them at discovery time.
let files = orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ];
in
{
  home.file = orc.mergeHomeFiles files [
    # Base layer: all files as symlinks
    # exclude: hyprland.conf (managed by wayland.windowManager.hyprland)
    #          *.png (binary assets)
    { include    = [ ];
      exclude    = [ "hyprland.conf" "*.png" ];
      emitter    = "symlink";
      destPrefix = ".config/hypr"; }

    # Override: wallust writes this file at runtime.
    # A symlink into the Nix store is read-only → wallust would fail.
    # force=true makes home-manager lay down a real writable file.
    { include    = [ "sys/policy/wallust/wallust-hyprland.conf" ];
      emitter    = "copy";
      destPrefix = ".config/hypr"; }
  ];
}
```

#### 2 — simple: everything as home.file

```nix
home.file = (orc.readConfigDir {
  src        = inputs.hypr-config;
  recursive  = true;
  destPrefix = ".config/hypr";
  policies   = [
    { include = [ "sys/" "user/" ]; exclude = [ "*.png" ]; }
  ];
}).homeFiles;
```

#### 3 — symlink tree + home.file (large stable trees)

When `sys/` is large and read-only, one store-wide symlink tree is more
efficient than per-file home.file entries:

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

#### 4 — mergeHomeFiles: symlink + copy + text in one attrset

```nix
home.file = orc.mergeHomeFiles
  (orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ])
  [
    # Base: everything as symlinks (exclude binaries and managed files)
    { include    = [ ];
      exclude    = [ "*.png" "hyprland.conf" ];
      emitter    = "symlink";
      destPrefix = ".config/hypr"; }

    # hardware/ as forced copies (allows local machine-specific overrides)
    { include    = [ "sys/hardware/" ];
      emitter    = "copy";
      destPrefix = ".config/hypr"; }

    # wallust-managed file: must be a real writable file
    { include    = [ "sys/policy/wallust/wallust-hyprland.conf" ];
      emitter    = "copy";
      destPrefix = ".config/hypr"; }

    # inject Nix-management header into user startup config
    { include    = [ "user/startup.conf" ];
      emitter    = "text";
      transform  = _: e: e // {
        text = "# managed by Nix — do not edit\n" + builtins.readFile e.absPath;
      };
      destPrefix = ".config/hypr"; }
  ];
```

#### 5 — drop source-tree symlinks via transform (alternative to filtered discovery)

```nix
policies = [
  { include   = [ "sys/" "user/" ];
    transform = _: e: if e.type == "symlink" then null else e;
    emitter   = "homeFiles"; }
];
```

---

### NixOS examples

#### 6 — expose sys/ via environment.etc

```nix
{ pkgs, inputs, ... }:
let
  orc    = inputs.configuration-orchestrator.lib.${pkgs.system};
  result = orc.readConfigDir {
    src       = inputs.hypr-config;
    inherit pkgs;
    recursive = true;
    name      = "hypr-sys";
    policies  = [
      { include = [ "sys/" ]; exclude = [ "*.png" ]; emitter = "symlinkTree"; }
    ];
  };
in
{
  environment.etc."hypr/sys".source = result.symlinkTree;
}
```

#### 7 — NixOS + home-manager together

```nix
{ pkgs, inputs, ... }:
let
  orc    = inputs.configuration-orchestrator.lib.${pkgs.system};
  result = orc.readConfigDir {
    src        = inputs.hypr-config;
    inherit pkgs;
    recursive  = true;
    destPrefix = ".config/hypr";
    name       = "hypr-config";
    policies   = [
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

**Drop all source-tree symlinks:**

```nix
transform = _: entry: if entry.type == "symlink" then null else entry;
# Or more efficiently at discovery time:
files = orc.listFilesRecursiveFiltered src "" [ "symlink" ];
```

**Force a file to be a physical copy:**

```nix
transform = _: entry: entry // { force = true; };
# Or use emitter = "copy" in mergeHomeFiles.
```

---

## Tests

```bash
cd test
nix eval .#_summary
# { allPassed = true; passed = N; total = N; }

nix eval . --json | jq .layer1
nix eval . --json | jq .layer3
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
mergeHomeFiles
  files    :: { "rel/path" = { absPath; type; }; }
  policies :: [ homePolicy ]
→ home.file attrset

homePolicy fields (all optional):
  include    :: [ pattern ]
  exclude    :: [ pattern ]
  transform  :: relPath → entry → entry | null
  emitter    :: "symlink" | "copy" | "text"   (default: "symlink")
  destPrefix :: string                         (default: "")
  priority   :: int                            (default: 5)
```

### `emit`

```
emit { files; destPrefix?; pkgs?; drvName?; }
→ { homeFiles; ?derivation; ?symlinkTree; }
```

### Low-level exports

```
readDirFlat                  :: path → { name = type; }
listFilesRecursive           :: path → string → files
listFilesRecursiveFiltered   :: path → string → [ type ] → files
matchesPattern               :: relPath → pattern → bool
matchesAny                   :: relPath → [ pattern ] → bool
applyPolicy                  :: policy → files → files
applyPolicies                :: [ policy ] → files → files
toHomeFiles                  :: destPrefix → files → attrset
toDerivation                 :: { pkgs; name; files } → derivation
toSymlinkTree                :: { pkgs; name; files } → derivation
emit                         :: { files; destPrefix; pkgs; drvName } → result
mergeHomeFiles               :: files → [ homePolicy ] → attrset
```
