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

| Scenario                                        | Best strategy                           |
| ----------------------------------------------- | --------------------------------------- |
| `sys/` — read-only stable config                | symlink (fast, zero copy)               |
| `user/` — personal overrides                    | `home.file` source                      |
| One file written by an external tool at runtime | `emitter = "copy"` (real writable file) |
| A file needs a header injected                  | derivation + transform                  |

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
     Produces { homeFiles; activation } with per-file emitter control:
       "symlink"  → homeFiles   { source = absPath; }   read-only symlink
       "copy"     → activation  cp absPath $HOME/key     real writable file
       "text"     → homeFiles   { text = entry.text; }  symlink to generated file
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

| Entry field          | home.file value         | installed as                           |
| -------------------- | ----------------------- | -------------------------------------- |
| `entry.text` present | `{ text = …; }`         | symlink to a store-generated text file |
| otherwise            | `{ source = absPath; }` | symlink into the Nix store             |

**home-manager always installs `home.file` entries as symlinks** — both `source`
and `text` produce symlinks. For a real writable file use `emitter = "copy"` in
`mergeHomeFiles`, which runs `cp` in the activation script instead.

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

### `mergeHomeFiles` — per-file control, returns `{ homeFiles; activation; }`

```nix
mergeHomeFiles files policies
→ { homeFiles :: attrset;   # → home.file = result.homeFiles
    activation :: string;   # → home.activation.<n>.script = result.activation
  }
```

Per-policy emitters:

| `emitter`   | destination  | result                                             |
| ----------- | ------------ | -------------------------------------------------- |
| `"symlink"` | `homeFiles`  | read-only symlink into Nix store                   |
| `"copy"`    | `activation` | **real writable file** — `cp` runs on every switch |
| `"text"`    | `homeFiles`  | symlink to a store-generated text file             |

**Why `"copy"` uses `home.activation` and not `home.file`:**
home-manager's `home.file` **always** installs files as symlinks — regardless of
`force`, `text`, or `source`. Symlinks point into the read-only Nix store.
The only way to get a real writable file is to `cp` during activation, after
home-manager has finished its linking phase.

```nix
let result = orc.mergeHomeFiles files [
  { include = []; exclude = [ "hyprland.conf" "*.png" ];
    emitter = "symlink"; destPrefix = ".config/hypr"; }
  { include = [ "sys/policy/wallust/wallust-hyprland.conf" ];
    emitter = "copy"; destPrefix = ".config/hypr"; }
]; in
{
  home.file = result.homeFiles;
  home.activation.hyprCopy = lib.hm.dag.entryAfter [ "writeBoundary" ] result.activation;
}
```

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

All files as symlinks, one file as a real writable copy for tools that write at runtime:

```nix
{ inputs, pkgs, lib, ... }:
let
  orc    = inputs.configuration-orchestrator.lib.${pkgs.system};
  files  = orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ];
  result = orc.mergeHomeFiles files [
    # Base layer: everything as symlinks
    # - hyprland.conf excluded: managed by wayland.windowManager.hyprland
    # - *.png excluded: binary assets
    { include    = [ ];
      exclude    = [ "hyprland.conf" "*.png" ];
      emitter    = "symlink";
      destPrefix = ".config/hypr"; }

    # wallust writes this file at runtime to inject dynamic colors.
    # "copy" runs `cp` in the activation script → real writable file on disk.
    { include    = [ "sys/policy/wallust/wallust-hyprland.conf" ];
      emitter    = "copy";
      destPrefix = ".config/hypr"; }
  ];
in
{
  home.file = result.homeFiles;
  # Activation runs after home-manager's linking phase.
  # wallust-hyprland.conf will be a real file, not a symlink.
  home.activation.hyprCopy =
    lib.hm.dag.entryAfter [ "writeBoundary" ] result.activation;
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

#### 4 — mergeHomeFiles: symlink + copy + text

```nix
{ inputs, pkgs, lib, ... }:
let
  orc    = inputs.configuration-orchestrator.lib.${pkgs.system};
  files  = orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ];
  result = orc.mergeHomeFiles files [
    # Base: symlinks for everything (exclude managed/binary files)
    { include    = [ ];
      exclude    = [ "*.png" "hyprland.conf" ];
      emitter    = "symlink";
      destPrefix = ".config/hypr"; }

    # hardware/ as real copies (allows per-machine local edits)
    { include    = [ "sys/hardware/" ];
      emitter    = "copy";
      destPrefix = ".config/hypr"; }

    # wallust: must be a real writable file (written at runtime)
    { include    = [ "sys/policy/wallust/wallust-hyprland.conf" ];
      emitter    = "copy";
      destPrefix = ".config/hypr"; }

    # inject a header via inline text (still a symlink, but to a generated file)
    { include    = [ "user/startup.conf" ];
      emitter    = "text";
      transform  = _: e: e // {
        text = "# managed by Nix — do not edit\n" + builtins.readFile e.absPath;
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

**Produce a writable physical file (for tools that write at runtime):**

```nix
# In mergeHomeFiles — reads content at eval time, home-manager writes a real file:
{ include = [ "sys/policy/wallust/wallust-hyprland.conf" ];
  emitter = "copy";
  destPrefix = ".config/hypr"; }

# Via transform — same mechanism, manual text injection:
transform = _: entry: entry // { text = builtins.readFile entry.absPath; };
# Note: force=true alone does NOT produce a writable file; it only controls
# whether home-manager replaces a pre-existing path before creating a symlink.
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
→ {
    homeFiles  :: attrset   → home.file = result.homeFiles
    activation :: string    → home.activation.<n>.script = result.activation
  }

homePolicy fields (all optional):
  include    :: [ pattern ]
  exclude    :: [ pattern ]
  transform  :: relPath → entry → entry | null
  emitter    :: "symlink" | "copy" | "text"   (default: "symlink")
  destPrefix :: string                         (default: "")
  priority   :: int                            (default: 5)

emitter destinations:
  "symlink"  → homeFiles   { source = absPath; }
  "copy"     → activation  cp --remove-destination absPath $HOME/destPrefix/relPath
  "text"     → homeFiles   { text = entry.text; }   (requires transform)
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
mergeHomeFiles               :: files → [ homePolicy ] → { homeFiles; activation }
```
