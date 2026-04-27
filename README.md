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

## Motivation

`xdg.configFile` and `home.file` in home-manager apply one strategy to
everything: symlink the whole tree. This is often too coarse:

- System-level config (`sys/`) is read-only and stable → symlinks are ideal
- User overrides (`user/`) should be tracked by home-manager → `home.file`
- A single file needs a comment injected or a secret merged → needs a
  physical copy produced by a derivation

There is no standard primitive for "symlink these, copy those, patch this one"
at file granularity. ConfigurationOrchestrator provides that primitive.

---

## Architecture

```
src (path)
  │
  ▼  Layer 1 · Discovery
  │  listFilesRecursive / readDirFlat
  │  → { "rel/path" = { absPath; type; }; ... }
  │
  ▼  Layer 2 · Policy Engine
  │  applyPolicy / applyPolicies
  │  Each policy tags matching files with { emitter; priority; ?text; ... }
  │  Multiple policies compose: last match wins per file.
  │  → { "rel/path" = { absPath; type; emitter; priority; ?text; }; ... }
  │
  ▼  Layer 3 · Emitter Dispatch
     emit / readConfigDir
     Files are split by their emitter tag and dispatched in parallel:

       homeFiles         derivation         symlinkTree
       home.file         physical copy      symlink tree
       attrset           store path         store path

     Returns:
       {
         homeFiles   = { ".config/hypr/sys/…" = { source = …; }; … };
         derivation  = /nix/store/…;    # only if used
         symlinkTree = /nix/store/…;    # only if used
       }
```

The key design decision: **the emitter is a property of each file, set by
its policy**. One call to `readConfigDir` can produce all three output kinds
simultaneously — each file goes exactly where its policy says.

---

## Layer 1 — File Discovery

```nix
# Non-recursive: { "name" = "regular"|"directory"|"symlink"|"unknown"; }
readDirFlat dir

# Recursive flat map: { "rel/path" = { absPath; type; }; }
# Pass "" as the initial prefix.
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

`applyPolicies` processes the list in order. For files matched by more than
one policy the **last** match wins (later = higher specificity). This lets you
write a broad base policy and then narrow overrides for specific paths.

**Pattern syntax:**

| Pattern    | Semantics                          |
| ---------- | ---------------------------------- |
| `"sys/"`   | prefix match                       |
| `"*.conf"` | suffix match                       |
| `"sys/*"`  | prefix match (trailing `*` strips) |
| `"/ERE/"`  | POSIX extended regular expression  |

---

## Layer 3 — Emitters

### Low-level single-emitter helpers

```nix
toHomeFiles   destPrefix files           # → home.file attrset
toDerivation  { pkgs, name, files }      # → store path (physical copy)
toSymlinkTree { pkgs, name, files }      # → store path (symlink tree)
```

### Multi-emitter dispatch: `emit`

```nix
emit {
  files;                  # processed file map from applyPolicies
  destPrefix ? "";        # prepended to homeFiles keys
  pkgs       ? null;      # required for derivation / symlinkTree
  drvName    ? "config-tree";
}
```

`emit` splits the file map by each entry's `emitter` field, calls the
corresponding emitter function, and returns a merged attrset. Only the output
keys for emitters that were actually used appear in the result.
`homeFiles` is always present (possibly `{}`).

---

## Usage

### Add as a flake input

```nix
inputs.orchestrator.url = "github:redskaber/ConfigurationOrchestrator";
```

### Example 1 — everything as home.file (simplest)

```nix
{ inputs, pkgs, ... }:
let orc = inputs.orchestrator.lib.${pkgs.system}; in
{
  home.file = (orc.readConfigDir {
    src        = inputs.hypr-config;
    recursive  = true;
    destPrefix = ".config/hypr";
    policies   = [ { include = [ "sys/" "user/" ]; exclude = [ "*.png" ]; } ];
  }).homeFiles;
}
```

### Example 2 — symlinks + home.file (canonical split)

`sys/` is large and stable — symlinks are fast and space-efficient.
`user/` contains personal overrides that home-manager should own directly.

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
      { include = [ "user/" ];                       emitter = "homeFiles";   }
    ];
  };
in
{
  home.file = result.homeFiles;
  # result.symlinkTree is a single store path; wire it where needed:
  xdg.configFile."hypr/sys".source = result.symlinkTree;
}
```

### Example 3 — symlinks + home.file + patched derivation

Patch one file, symlink the rest, let user/ stay in home-manager:

```nix
policies = [
  { include   = [ "sys/" ];
    exclude   = [ "*.png" "sys/scripts/" ];
    emitter   = "symlinkTree"; }
  { include   = [ "user/" ];
    emitter   = "homeFiles"; }
  # Override: patch startup.conf — last policy wins for this path
  { include   = [ "sys/startup.conf" ];
    emitter   = "derivation";
    transform = _: entry: entry // {
      text = "# managed by Nix — do not edit\n"
           + builtins.readFile entry.absPath;
    }; }
];
```

The patched file ends up in `result.derivation` as a physical copy;
everything else follows the earlier policies.

### Example 4 — drop all symlinks from a source tree

Some repos use symlinks for aliasing (`hypridle.conf → sys/hypridle.conf`).
Remove them to avoid double-linking:

```nix
policies = [
  { include   = [ "sys/" "user/" ];
    transform = _: entry: if entry.type == "symlink" then null else entry;
    emitter   = "homeFiles"; }
];
```

### Example 5 — NixOS module pattern

```nix
{ pkgs, inputs, ... }:
let
  orc    = inputs.orchestrator.lib.${pkgs.system};
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
  environment.etc."hypr".source = result.symlinkTree;
}
```

---

## Transform recipes

**Prepend a header to every `.conf`:**

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

**Drop all symlinks:**

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
# { allPassed = true; passed = 32; total = 32; }

nix eval . --json | jq .layer3_multi
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
    homeFiles    :: attrset       always present
    derivation   :: derivation    present if any policy used "derivation"
    symlinkTree  :: derivation    present if any policy used "symlinkTree"
  }
```

### `emit`

```
emit {
  files      :: attrset   output of applyPolicies
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
```
