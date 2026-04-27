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
whole tree. You often need finer control:

| Scenario                               | Best strategy                                  |
| -------------------------------------- | ---------------------------------------------- |
| Large stable config tree               | `xdg.configFile` recursive symlink (simplest)  |
| One file written by a tool at runtime  | `mergeHomeFiles` `"copy"` emitter              |
| Mix of stable files + runtime-writable | `xdg.configFile` + `mergeHomeFiles` activation |
| Per-file emitter dispatch at scale     | `emit` / `readConfigDir`                       |

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

     ─── mergeHomeFiles ─────────────────────────────────────────────
     Returns: { homeFiles; activation }
       "symlink"  → homeFiles   { source = absPath; }   read-only symlink
       "copy"     → activation  cp absPath $HOME/key     real writable file
       "text"     → homeFiles   { text = entry.text; }  symlink to generated file
```

**Core design principle:** the emitter is a property of each file, set by
its policy — not a global switch for the whole tree.

---

## home-manager and home.file always use symlinks

home-manager's `home.file` and `xdg.configFile` **always install as symlinks**
into the read-only Nix store — regardless of `force`, `text`, or `source`.

The **only** way to produce a real writable file is via `home.activation`,
which runs shell commands after the linking phase. The `"copy"` emitter in
`mergeHomeFiles` generates an activation script that `cp`s the file.

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

The correct fix is **not** to exclude `hyprland.conf` from your config tree —
that would break your configuration. Instead use `xdg.configFile` with
`force = true`, which tells home-manager to let your file win over the
module-generated one:

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
symlinks at discovery time, or rely on `xdg.configFile` which handles this
transparently.

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

**Pattern syntax:**

| Pattern           | Semantics                          |
| ----------------- | ---------------------------------- |
| `[]` or `[ "*" ]` | accept everything                  |
| `"sys/"`          | prefix match                       |
| `"*.conf"`        | suffix match                       |
| `"sys/*"`         | prefix match (trailing `*` strips) |
| `"/ERE/"`         | POSIX extended regular expression  |

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
    activation :: string;    # → home.activation.<n>.script = result.activation
  }
```

| `emitter`   | destination  | result                                                    |
| ----------- | ------------ | --------------------------------------------------------- |
| `"symlink"` | `homeFiles`  | read-only symlink into Nix store                          |
| `"copy"`    | `activation` | **real writable file** — `cp` on every switch             |
| `"text"`    | `homeFiles`  | symlink to store-generated text file (requires transform) |

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

When a home-manager module (e.g. `wayland.windowManager.hyprland`) generates
files that conflict with your config tree, the cleanest solution is:

- `xdg.configFile` with `force = true` handles the whole tree (including the
  conflict — your file wins)
- `mergeHomeFiles` with only a `"copy"` policy generates the activation script
  that makes the runtime-writable file a real file after linking

```nix
{ inputs, shared, lib, ... }:
let
  hyprResult = shared.orc.mergeHomeFiles (
    shared.orc.listFilesRecursive inputs.hypr-config ""
  ) [
    # Only wallust needs special treatment — everything else is handled by
    # xdg.configFile below. The "copy" emitter generates an activation script
    # that runs cp after the linking phase, making this a real writable file.
    { include    = [ "sys/policy/wallust/wallust-hyprland.conf" ];
      emitter    = "copy";
      destPrefix = ".config/hypr"; }
  ];
in
{
  # Recursively link the entire hypr-config tree.
  # force = true lets your hyprland.conf win over the module-generated one.
  xdg.configFile."hypr" = {
    source    = inputs.hypr-config;
    recursive = true;
    force     = true;
  };

  # After linking, replace the wallust symlink with a real writable file.
  # wallust will write dynamic colors into it at runtime.
  home.activation.hyprWallust =
    lib.hm.dag.entryAfter [ "writeBoundary" ] hyprResult.activation;
}
```

This pattern composes cleanly: `xdg.configFile` handles structure, the
activation script handles the single file that needs to be writable.

#### 2 — mergeHomeFiles only (no xdg.configFile conflict)

When no module conflicts exist and you need per-file emitter control entirely
through `home.file`:

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

#### 3 — simple: everything as home.file

```nix
home.file = (orc.readConfigDir {
  src        = inputs.hypr-config;
  recursive  = true;
  destPrefix = ".config/hypr";
  policies   = [ { include = [ "sys/" "user/" ]; exclude = [ "*.png" ]; } ];
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
# At discovery time (preferred):
files = orc.listFilesRecursiveFiltered src "" [ "symlink" ];
# Or via transform:
transform = _: e: if e.type == "symlink" then null else e;
```

---

## Tests

```bash
cd test
nix eval .#_summary
# { allPassed = true; passed = N; total = N; }
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
mergeHomeFiles files [ homePolicy ]
→ { homeFiles :: attrset; activation :: string; }

homePolicy fields (all optional):
  include    :: [ pattern ]
  exclude    :: [ pattern ]
  transform  :: relPath → entry → entry | null
  emitter    :: "symlink" | "copy" | "text"   (default: "symlink")
  destPrefix :: string                         (default: "")

emitter destinations:
  "symlink"  → homeFiles   { source = absPath; }
  "copy"     → activation  cp --remove-destination absPath $HOME/key
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
