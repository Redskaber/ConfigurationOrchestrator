# ConfigurationOrchestrator

A pure-Nix library for reading, filtering, transforming, and emitting
configuration directory trees with **per-file emitter control**.

```
lib/default.nix    — pure function library (three layers)
test/default.nix   — test suite (aligned to library API)
test/flake.nix     — test harness (hypr-config fixture lives here only)
flake.nix          — public interface: lib.<system>
```

---

## Why this exists

`xdg.configFile` and `home.file` in home-manager force one strategy on the
whole tree. In practice you need finer control:

| Scenario                                          | Best strategy              |
| ------------------------------------------------- | -------------------------- |
| `sys/` — read-only, stable system config          | symlink (fast, zero copy)  |
| `user/` — personal overrides home-manager manages | `home.file` source         |
| One file needs a header injected                  | derivation (physical copy) |
| A secret must be merged in                        | derivation + transform     |

There is no standard primitive for "symlink these, copy those, patch this
one" at file granularity. `ConfigurationOrchestrator` is that primitive.

---

## Architecture

```
src (path)
  │
  ▼  Layer 1 · Discovery
  │  listFilesRecursive / readDirFlat
  │  { "rel/path" = { absPath; type; }; ... }
  │
  ▼  Layer 2 · Policy Engine
  │  applyPolicy / applyPolicies
  │  Each policy tags matching files with { emitter; priority; ?text; ... }
  │  Policies compose: last match wins per file.
  │  { "rel/path" = { absPath; type; emitter; priority; ?text; }; ... }
  │
  ▼  Layer 3 · Emitter Dispatch
     ┌─────────────────────────────────────────────────────────────────┐
     │  emit / readConfigDir                                           │
     │                                                                 │
     │  files split by emitter tag → dispatched in parallel           │
     │                                                                 │
     │  "homeFiles"    "derivation"     "symlinkTree"                 │
     │  home.file      physical copy    symlink tree                  │
     │  attrset        store path       store path                    │
     └─────────────────────────────────────────────────────────────────┘
     Returns:
       {
         homeFiles    = { ".config/hypr/user/…" = { source = …; }; … };
         derivation   = /nix/store/…;    # present only if used
         symlinkTree  = /nix/store/…;    # present only if used
       }

     ─── mergeHomeFiles (alternative) ──────────────────────────────────
     For home.file-only use cases needing mixed symlink/copy/text
     granularity within a single attrset:
       "symlink" → { source = absPath; }
       "copy"    → { source = absPath; force = true; }
       "text"    → { text = entry.text; }
```

**Core design principle:** the emitter is a property of each file, set by
its policy — not a global switch. One `readConfigDir` call can produce all
three output kinds simultaneously.

---

## Layer 1 — File Discovery

```nix
# Non-recursive: { "name" = "regular"|"directory"|"symlink"|"unknown"; }
readDirFlat dir

# Recursive flat map: { "rel/path" = { absPath; type; }; }
listFilesRecursive dir ""
```

---

## Layer 2 — Policy

A **policy** is an attrset — all fields optional:

```nix
{
  include   = [ "sys/" "*.conf" ];    # [] = accept everything
  exclude   = [ "*.png" ];            # [] = drop nothing
  transform = relPath: entry:         # return null to drop the file
    entry // { text = "# header\n" + builtins.readFile entry.absPath; };
  emitter   = "homeFiles";            # "homeFiles" | "derivation" | "symlinkTree"
  priority  = 5;                      # home-manager mkMerge priority
}
```

`applyPolicies` processes the list in order.  
**Last match wins** — write a broad base policy, then narrow overrides:

```nix
applyPolicies [
  { include = [ "sys/" ];  emitter = "symlinkTree"; }   # broad
  { include = [ "sys/startup.conf" ]; emitter = "derivation"; } # override
] allFiles
# sys/startup.conf → derivation; everything else in sys/ → symlinkTree
```

**Pattern syntax:**

| Pattern    | Semantics                          |
| ---------- | ---------------------------------- |
| `"sys/"`   | prefix match                       |
| `"*.conf"` | suffix match                       |
| `"sys/*"`  | prefix match (trailing `*` strips) |
| `"/ERE/"`  | POSIX extended regular expression  |

---

## Layer 3 — Emitters

### Low-level helpers

```nix
toHomeFiles   destPrefix files           # → home.file attrset
toDerivation  { pkgs, name, files }      # → store path (physical copy)
toSymlinkTree { pkgs, name, files }      # → store path (symlink tree)
```

### `emit` — multi-emitter dispatch

Takes a file map from `applyPolicies` and routes each file to the emitter
its policy specified:

```nix
emit {
  files;                    # from applyPolicies
  destPrefix ? "";          # prepended to homeFiles keys
  pkgs       ? null;        # required for derivation / symlinkTree
  drvName    ? "config-tree";
}
# → { homeFiles; ?derivation; ?symlinkTree; }
```

Only output keys for emitters that were actually used appear in the result.
`homeFiles` is always present (possibly `{}`).

### `mergeHomeFiles` — mixed home.file in one attrset

When you need symlink/copy/text granularity _within a single `home.file`
attrset_ (without producing separate derivations):

```nix
mergeHomeFiles files [
  { include    = [ "sys/" ];
    emitter    = "symlink";    # → { source = absPath; }
    destPrefix = ".config/hypr"; }
  { include    = [ "sys/hardware/" ];
    emitter    = "copy";       # → { source = absPath; force = true; }
    destPrefix = ".config/hypr"; }
  { include    = [ "hyprland.conf" ];
    emitter    = "text";       # → { text = entry.text; }
    transform  = _: e: e // { text = "# generated"; };
    destPrefix = ".config/hypr"; }
]
# → one attrset: some entries have source, some have force=true, some have text
```

| `emitter` in mergeHomeFiles | home.file entry                       |
| --------------------------- | ------------------------------------- |
| `"symlink"`                 | `{ source = absPath; }`               |
| `"copy"`                    | `{ source = absPath; force = true; }` |
| `"text"`                    | `{ text = entry.text; }`              |

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

#### 1 — everything as home.file (simplest)

```nix
{ inputs, pkgs, ... }:
let orc = inputs.configuration-orchestrator.lib.${pkgs.system}; in
{
  home.file = (orc.readConfigDir {
    src        = inputs.hypr-config;
    recursive  = true;
    destPrefix = ".config/hypr";
    policies   = [
      { include = [ "sys/" "user/" ]; exclude = [ "*.png" ]; }
    ];
    # default emitter = "homeFiles"
  }).homeFiles;
}
```

#### 2 — symlink tree + home.file (canonical split)

`sys/` is large and stable — one store symlink tree, zero per-file
home-manager entries. `user/` personal overrides stay in home-manager:

```nix
let
  result = orc.readConfigDir {
    src        = inputs.hypr-config;
    inherit pkgs;
    recursive  = true;
    destPrefix = ".config/hypr";
    name       = "hypr-config";
    policies   = [
      { include = [ "sys/" ]; exclude = [ "*.png" ]; emitter = "symlinkTree"; }
      { include = [ "user/" ];                        emitter = "homeFiles"; }
    ];
  };
in
{
  home.file = result.homeFiles;
  # Wire the symlink tree wherever needed — e.g. as a read-only XDG dir:
  xdg.configFile."hypr/sys".source = result.symlinkTree;
}
```

#### 3 — symlink + home.file + patched derivation

Patch one file (inject a Nix-managed header), symlink the rest:

```nix
policies = [
  { include = [ "sys/" ]; exclude = [ "*.png" "sys/scripts/" ];
    emitter = "symlinkTree"; }
  { include = [ "user/" ];
    emitter = "homeFiles"; }
  # last-wins override: patch startup.conf, emit as physical copy
  { include   = [ "sys/startup.conf" ];
    emitter   = "derivation";
    transform = _: entry: entry // {
      text = "# managed by Nix — do not edit\n"
           + builtins.readFile entry.absPath;
    }; }
];
# result.homeFiles    → user/ entries
# result.symlinkTree  → sys/ (minus startup.conf and scripts/)
# result.derivation   → patched startup.conf
```

#### 4 — mergeHomeFiles: symlink/copy/text in one `home.file`

Use when you want per-file control _without_ separate derivations, e.g.
when `home.file` is your only integration point:

```nix
home.file = orc.mergeHomeFiles (orc.listFilesRecursive inputs.hypr-config "") [
  # most of sys/ as plain symlinks
  { include    = [ "sys/" ]; exclude = [ "sys/hardware/" "*.png" ];
    emitter    = "symlink";
    destPrefix = ".config/hypr"; }
  # hardware/ as forced copies (allows local overrides)
  { include    = [ "sys/hardware/" ];
    emitter    = "copy";
    destPrefix = ".config/hypr"; }
  # user overrides as symlinks
  { include    = [ "user/" ];
    emitter    = "symlink";
    destPrefix = ".config/hypr"; }
  # inject header into main config
  { include    = [ "hyprland.conf" ];
    emitter    = "text";
    transform  = _: e: e // {
      text = "# generated — do not edit\n" + builtins.readFile e.absPath;
    };
    destPrefix = ".config/hypr"; }
];
```

#### 5 — drop source-tree symlinks before linking

Some repos alias files (`hypridle.conf → sys/hypridle.conf`). Remove them
to avoid double-linking:

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
# In a NixOS module that also imports home-manager:
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
      # System policy layer: symlink stable read-only config
      { include = [ "sys/" ]; exclude = [ "*.png" ]; emitter = "symlinkTree"; }
      # User policy layer: home-manager owns personal overrides
      { include = [ "user/" ]; emitter = "homeFiles"; }
    ];
  };
in
{
  # NixOS side: make sys/ available system-wide
  environment.etc."hypr/sys".source = result.symlinkTree;

  # home-manager side: user/ entries wired into home.file
  home-manager.users.alice = {
    home.file = result.homeFiles;
  };
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

**Drop all symlinks from source tree:**

```nix
transform = _: entry: if entry.type == "symlink" then null else entry;
```

---

## Tests

`hypr-config` is a fixture owned entirely by `test/flake.nix`.
The root `flake.nix` has no dependency on any specific config repository.

```bash
cd test
nix eval .#_summary
# { allPassed = true; passed = N; total = N; }

nix eval . --json | jq .layer3
nix eval . --json | jq .highLevel
```

---

## API reference

### `readConfigDir`

```
readConfigDir {
  src        :: path
  recursive  :: bool          (default: true)
  policies   :: [ policy ]    (default: [])
  destPrefix :: string        (default: "")
  pkgs       :: pkgs          (required when any policy uses derivation/symlinkTree)
  name       :: string        (default: "config-tree")
}
→ {
    homeFiles    :: attrset       always present (may be {})
    derivation   :: derivation    present if any policy used "derivation"
    symlinkTree  :: derivation    present if any policy used "symlinkTree"
  }
```

### `mergeHomeFiles`

```
mergeHomeFiles
  files    :: { "rel/path" = { absPath; type; }; }  (from listFilesRecursive)
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
emit {
  files      :: attrset   (from applyPolicies)
  destPrefix :: string    (default: "")
  pkgs       :: pkgs
  drvName    :: string    (default: "config-tree")
}
→ { homeFiles; ?derivation; ?symlinkTree; }
```

### Low-level exports

```
readDirFlat        :: path → { name = type; }
listFilesRecursive :: path → string → { "rel/path" = { absPath; type; }; }
matchesPattern     :: relPath → pattern → bool
matchesAny         :: relPath → [ pattern ] → bool
applyPolicy        :: policy → files → files
applyPolicies      :: [ policy ] → files → files
toHomeFiles        :: destPrefix → files → attrset
toDerivation       :: { pkgs; name; files } → derivation
toSymlinkTree      :: { pkgs; name; files } → derivation
emit               :: { files; destPrefix; pkgs; drvName } → result
mergeHomeFiles     :: files → [ homePolicy ] → attrset
```
