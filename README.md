# ConfigurationOrchestrator

A pure-Nix library for reading, filtering, transforming, and emitting
configuration directory trees with **per-file emitter control**.

```
lib/default.nix    — pure function library (three layers + high-level API)
tests/default.nix  — test suite (120+ assertions)
tests/flake.nix    — test harness (hypr-config fixture)
flake.nix          — public interface: lib.<system>
docs/              — architecture, API reference, recipes, extension guide
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
| Custom installation strategy           | `registerEmitter` (plugin point)               |

---

## Architecture overview

```
src (Nix path)
  │
  ▼  Layer 1 · Discovery
  │  listFilesRecursive / listFilesRecursiveFiltered / readDirFlat
  │  FileMap :: { "rel/path" = { absPath; type; }; }
  │
  ▼  Layer 2 · Policy Engine
  │  applyPolicy / applyPolicies / tagAll
  │  Tags each file with { emitter; priority; ?text; ?force; }
  │  Last-match-wins composition. tagAll = zero-policy fast path.
  │  TaggedMap :: { "rel/path" = { absPath; type; emitter; priority; … }; }
  │
  ▼  Layer 3 · Emitter Dispatch
  │  ┌──────────────────────────────────────────────────────────────────┐
  │  │  emit / readConfigDir                                            │
  │  │                                                                  │
  │  │  "homeFiles"    "derivation"    "symlinkTree"   <custom>         │
  │  │  home.file      physical copy   symlink tree    registerEmitter  │
  │  └──────────────────────────────────────────────────────────────────┘
  │  Returns: EmitResult :: { homeFiles; ?derivation; ?symlinkTree; … }
  │
  │  ── mergeHomeFiles ──────────────────────────────────────────────────
  │  Returns: MergeResult :: { homeFiles; activation }
  │    "symlink"  → homeFiles   { source = absPath; }   read-only symlink
  │    "copy"     → activation  run cp absPath $HOME/key  real writable file
  │    "text"     → homeFiles   { text = entry.text; }  symlink to store file
```

---

## home-manager fundamentals

### home.file and xdg.configFile always use symlinks

Both options **always install as symlinks** into the read-only Nix store,
regardless of `force`, `text`, or `source`. This is the core constraint that
drives this library's design.

| Option                        | Purpose                                                          |
| ----------------------------- | ---------------------------------------------------------------- |
| `home.file.<name>.source`     | Path to source file or directory in the Nix store                |
| `home.file.<name>.text`       | Inline text; home-manager writes it to a store path and symlinks |
| `home.file.<name>.force`      | Unconditionally replace target (even if module-generated)        |
| `home.file.<name>.recursive`  | Recursively link a directory tree's leaves                       |
| `home.file.<name>.onChange`   | Shell commands to run when the file changes between generations  |
| `home.file.<name>.executable` | Set the execute bit on the linked file                           |
| `xdg.configFile.<name>.*`     | Same options, but paths are relative to `$XDG_CONFIG_HOME`       |

The **only** way to produce a real writable file is via `home.activation`.
The `"copy"` emitter in `mergeHomeFiles` generates an activation script that
`cp`s the file using the `run` helper (respects `DRY_RUN` and `VERBOSE`).

### home.activation

Entries are DAG nodes that run after linking. Each entry must:

- Be idempotent
- Respect `DRY_RUN` — if set, log but don't perform actions
- Respect `VERBOSE` / `VERBOSE_ARG` — if set, print debug information

```nix
home.activation.myScript =
  lib.hm.dag.entryAfter [ "writeBoundary" ] result.activation;
```

---

## Lifecycle (state machine)

```
[EVAL]       Nix evaluation:
               Discovery (L1) → Policy (L2) → Emit (L3) → EmitResult/MergeResult

[LINK]       home-manager switch — writeBoundary:
               checkLinkTargets → home.file symlinks placed

[ACTIVATE]   home-manager switch — post-writeBoundary:
               activation scripts execute:
                 run mkdir -p …
                 run cp --remove-destination …   ← "copy" emitter
                 run chmod u+w …

[RUNTIME]    External tools write into the copied (writable) files:
               wallust, pywal, etc.
```

---

## Quick start

### Add as a flake input

```nix
inputs.configuration-orchestrator.url =
  "github:redskaber/ConfigurationOrchestrator";
```

```nix
orc = inputs.configuration-orchestrator.lib.${pkgs.system};
```

---

## home-manager examples

### 1 — Everything as symlinks (simplest)

```nix
# policies = [] → tagAll internally → all files become homeFiles
home.file = (orc.readConfigDir {
  src        = inputs.my-config;
  recursive  = true;
  destPrefix = ".config/myapp";
}).homeFiles;
```

### 2 — One writable file, everything else symlinked

```nix
let
  result = orc.mergeHomeFiles
    (orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ])
    [
      { include    = [ ];
        emitter    = "symlink";
        destPrefix = ".config/hypr"; }
      { include    = [ "sys/policy/wallust/wallust-hyprland.conf" ];
        emitter    = "copy";
        destPrefix = ".config/hypr"; }
    ];
in {
  home.file = result.homeFiles;
  home.activation.hyprWallust =
    lib.hm.dag.entryAfter [ "writeBoundary" ] result.activation;
}
```

### 3 — Conflict with a home-manager module (hyprland)

When `wayland.windowManager.hyprland` generates `hyprland.conf` and conflicts
with your config tree:

```nix
{
  xdg.configFile."hypr" = {
    source    = inputs.hypr-config;
    recursive = true;
    force     = true;   # your file wins over module-generated one
  };

  home.activation.hyprWallust =
    lib.hm.dag.entryAfter [ "writeBoundary" ]
      (orc.mergeHomeFiles
        (orc.listFilesRecursive inputs.hypr-config "")
        [{ include    = [ "sys/policy/wallust/wallust-hyprland.conf" ];
           emitter    = "copy";
           destPrefix = ".config/hypr"; }]
      ).activation;
}
```

### 4 — force flag per policy

```nix
let
  result = orc.mergeHomeFiles
    (orc.listFilesRecursiveFiltered inputs.my-config "" [ "symlink" ])
    [{
      include    = [ "*.conf" ];
      emitter    = "symlink";
      destPrefix = ".config/myapp";
      force      = true;   # unconditionally replace targets
    }];
in { home.file = result.homeFiles; }
```

### 5 — Custom emitter via registerEmitter

```nix
let
  # Register a custom emitter that builds a JSON index of all managed files
  indexEmitters = orc.registerEmitter orc.defaultEmitters "jsonIndex"
    ({ files, pkgs, drvName, ... }:
      pkgs.writeText "${drvName}-index.json"
        (builtins.toJSON (builtins.attrNames files)));

  result = orc.readConfigDir {
    src      = inputs.my-config;
    inherit pkgs;
    emitters = indexEmitters;
    policies = [
      { include = [ "sys/" ]; emitter = "homeFiles"; }
      { include = [ "sys/" ]; emitter = "jsonIndex"; }
    ];
  };
in {
  home.file                    = result.homeFiles;
  home.file.".config/index.json".source = result.jsonIndex;
}
```

### 6 — symlink tree + home.file (large stable trees)

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

### 7 — mergeHomeFiles: symlink + copy + text

```nix
let
  result = orc.mergeHomeFiles
    (orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ])
    [
      { include = [ ]; exclude = [ "*.png" ]; emitter = "symlink";
        destPrefix = ".config/hypr"; }
      { include = [ "sys/hardware/" ]; emitter = "copy";
        destPrefix = ".config/hypr"; }
      { include = [ "user/startup.conf" ]; emitter = "text";
        transform = _: e: e // { text = "# managed by Nix\n" + builtins.readFile e.absPath; };
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

## NixOS examples

### 8 — expose sys/ via environment.etc

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

### 9 — NixOS + home-manager together

```nix
let
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

## TaggedMap invariant

**`emit` and `toHomeFiles` require a TaggedMap** — every entry must have
`emitter` and `priority` attributes.

| Function        | When to use                                           |
| --------------- | ----------------------------------------------------- |
| `applyPolicy`   | Apply a single policy (filters + tags matching files) |
| `applyPolicies` | Apply a list of policies (last-wins per file)         |
| `tagAll`        | Tag all files with defaults (no filtering)            |

Never pass a raw `FileMap` directly to `emit` or `toHomeFiles`.

---

## Common pitfall: conflicting managed target files

```
error: Failed assertions:
- Conflicting managed target files: .config/hypr/hyprland.conf
```

**Cause A** — `wayland.windowManager.hyprland` generates `hyprland.conf`.
Fix: use `xdg.configFile` with `force = true` (see example 3 above).

**Cause B** — `listFilesRecursive` sees both a symlink and its target.
Fix: use `listFilesRecursiveFiltered` to skip symlinks at discovery time:

```nix
files = orc.listFilesRecursiveFiltered inputs.hypr-config "" [ "symlink" ];
```

---

## Changelog

### v4 (current)

- **Fix:** `priority` field is now correctly propagated via `lib.mkOrder`
  in `toHomeFiles` and `mergeHomeFiles` when it differs from the default (5).
  Previously it was stored in the TaggedMap but never applied to the
  resulting home.file entries. This was the most significant correctness gap.
- **New:** `force` field in `HomePolicy` (for `mergeHomeFiles`). Both
  `"symlink"` and `"text"` emitters now propagate `force = true` to the
  generated home.file entry. `"copy"` entries are always written (unaffected).
- **New:** `registerEmitter` — open/closed plugin point for custom emitters.
  Callers can add new emitter types without modifying the library source.
- **New:** `emit` and `readConfigDir` accept an `emitters` argument for
  dependency injection of the emitter registry.
- **New:** `defaultEmitters` exported so callers can build on the built-in set.
- **New:** `defaultPolicy` exported for introspection and documentation.
- **New:** `_failedTests` output in the test suite for easier debugging.
- **Fix:** `orchError` helper produces friendlier, location-tagged error messages
  with actionable hints for `emitter="text"` missing transform.
- **Fix:** `toDerivation` shell quoting for `escapedRel` used consistently.
- **Docs:** Architecture, API, recipes fully updated for v4 features.

### v3

- **Fix:** `readConfigDir` with `policies = []` now correctly passes a
  `TaggedMap` to `emit` via `tagAll`.
- **New:** `tagAll` exported as a first-class Layer-2 function.
- **Docs:** `TaggedMap` invariant made explicit throughout.

### v2

- **Fix:** `listFilesRecursiveFiltered` propagates `skipTypes` recursively.
- **Fix:** `mergeHomeFiles` activation script uses `run` helper.
- **Fix:** Deterministic key ordering in `mergeHomeFiles`.
- **New:** `toHomeFiles` propagates `force = true`.
- **New:** `mergeHomeFiles` `"copy"` eviction rule.
- **New:** `readConfigDir` non-recursive mode.
- **New:** Multi-system support in `flake.nix`.

---

## Running tests

```bash
cd tests
nix eval .#_summary
# { allPassed = true; passed = N; total = N; }

nix eval . --json | jq ._failedTests
# []  (empty when all pass)

nix eval . --json | jq .layer3
nix eval . --json | jq .v4
```

All 5 test groups must pass: `layer1`, `layer2`, `layer3`, `highLevel`, `v4`.
