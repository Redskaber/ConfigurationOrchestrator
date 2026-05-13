# Recipes & Extension Guide

## Common patterns

### Pattern 1 — Everything as symlinks (simplest)

Best for a fully stable config tree where nothing needs to be written at runtime.

```nix
# policies = [] → tagAll internally → all files become homeFiles
home.file = (orc.readConfigDir {
  src        = inputs.my-config;
  recursive  = true;
  destPrefix = ".config/myapp";
}).homeFiles;
```

Or explicitly with `tagAll`:

```nix
let
  files  = orc.listFilesRecursiveFiltered inputs.my-config "" [ "symlink" ];
  tagged = orc.tagAll files;
  result = orc.emit { files = tagged; destPrefix = ".config/myapp"; };
in
{ home.file = result.homeFiles; }
```

---

### Pattern 2 — One writable file, everything else symlinked

Best for tools like wallust, pywal that write a single config file at runtime.

```nix
let
  result = orc.mergeHomeFiles
    (orc.listFilesRecursiveFiltered inputs.my-config "" [ "symlink" ])
    [
      { include    = [ ];
        emitter    = "symlink";
        destPrefix = ".config/myapp"; }
      { include    = [ "theme/colors.conf" ];
        emitter    = "copy";
        destPrefix = ".config/myapp"; }
    ];
in {
  home.file = result.homeFiles;
  home.activation.myappColors =
    lib.hm.dag.entryAfter [ "writeBoundary" ] result.activation;
}
```

---

### Pattern 3 — Conflict with a home-manager module (hyprland)

When a module (e.g. `wayland.windowManager.hyprland`) generates a file
that conflicts with your config tree:

```nix
{
  # Whole tree via xdg.configFile — force=true wins conflicts
  xdg.configFile."hypr" = {
    source    = inputs.hypr-config;
    recursive = true;
    force     = true;
  };

  # Only the runtime-writable file via activation
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

---

### Pattern 4 — Adding a header comment to all .conf files

```nix
let
  result = orc.mergeHomeFiles
    (orc.listFilesRecursiveFiltered inputs.my-config "" [ "symlink" ])
    [{
      include    = [ "*.conf" ];
      emitter    = "text";
      destPrefix = ".config/myapp";
      transform  = relPath: entry:
        entry // {
          text = "# managed by Nix — do not edit\n"
               + builtins.readFile entry.absPath;
        };
    }];
in {
  home.file = result.homeFiles;
}
```

---

### Pattern 5 — Exclude secrets from the managed tree

```nix
let
  result = orc.mergeHomeFiles
    (orc.listFilesRecursiveFiltered inputs.my-config "" [ "symlink" ])
    [{
      include    = [ ];
      exclude    = [ "secrets/" "*.key" "*.pem" ];
      emitter    = "symlink";
      destPrefix = ".config/myapp";
    }];
in {
  home.file = result.homeFiles;
}
```

---

### Pattern 6 — Large stable tree as a symlink tree (efficient)

For very large trees, one derivation is more efficient than thousands of
individual `home.file` entries.

```nix
let
  result = orc.readConfigDir {
    src        = inputs.big-config;
    inherit pkgs;
    recursive  = true;
    name       = "big-config-tree";
    policies   = [
      { include = [ "sys/" ]; exclude = [ "*.png" ]; emitter = "symlinkTree"; }
      { include = [ "user/" ]; emitter = "homeFiles"; }
    ];
  };
in {
  home.file      = result.homeFiles;
  xdg.configFile."myapp/sys".source = result.symlinkTree;
}
```

---

### Pattern 7 — Multiple config trees composed

```nix
let
  resultA = orc.mergeHomeFiles
    (orc.listFilesRecursiveFiltered inputs.config-a "" [ "symlink" ])
    [{ include = [ ]; emitter = "symlink"; destPrefix = ".config/app-a"; }];

  resultB = orc.mergeHomeFiles
    (orc.listFilesRecursiveFiltered inputs.config-b "" [ "symlink" ])
    [{ include = [ ]; emitter = "symlink"; destPrefix = ".config/app-b"; }];
in {
  home.file = resultA.homeFiles // resultB.homeFiles;
  home.activation.copyFiles =
    lib.hm.dag.entryAfter [ "writeBoundary" ]
      (resultA.activation + "\n" + resultB.activation);
}
```

---

### Pattern 8 — tagAll for direct emit without policies

```nix
let
  files  = orc.listFilesRecursiveFiltered inputs.my-config "" [ "symlink" ];
  tagged = orc.tagAll files;
  result = orc.emit {
    files      = tagged;
    destPrefix = ".config/myapp";
  };
in {
  home.file = result.homeFiles;
}
```

---

### Pattern 9 — force per policy

When you need `force = true` on a subset of files (not the whole tree):

```nix
let
  result = orc.mergeHomeFiles
    (orc.listFilesRecursiveFiltered inputs.my-config "" [ "symlink" ])
    [
      # Most files: normal symlinks
      { include    = [ ];
        emitter    = "symlink";
        destPrefix = ".config/myapp"; }
      # This file: force=true because another module also writes it
      { include    = [ "colors.conf" ];
        emitter    = "symlink";
        destPrefix = ".config/myapp";
        force      = true; }
    ];
in {
  home.file = result.homeFiles;
}
```

---

### Pattern 10 — Custom emitter via registerEmitter

Build a JSON manifest of all managed files alongside the normal homeFiles:

```nix
let
  manifestEmitters = orc.registerEmitter orc.defaultEmitters "manifest"
    ({ files, pkgs, drvName, ... }:
      pkgs.writeText "${drvName}-manifest.json"
        (builtins.toJSON
          (map (relPath: { path = relPath; absPath = files.${relPath}.absPath; })
               (builtins.attrNames files))));

  result = orc.readConfigDir {
    src      = inputs.my-config;
    inherit pkgs;
    emitters = manifestEmitters;
    policies = [
      { include = [ "sys/" ]; emitter = "homeFiles"; }
      { include = [ "sys/" ]; emitter = "manifest"; }
    ];
    destPrefix = ".config/myapp";
  };
in {
  home.file = result.homeFiles // {
    ".config/myapp/.manifest.json".source = result.manifest;
  };
}
```

---

### Pattern 11 — Priority-based merge ordering

When multiple home-manager modules write to overlapping paths, use `priority`
to control which entry wins via `lib.mkOrder`:

```nix
let
  result = orc.mergeHomeFiles files [
    { include  = [ "base.conf" ];
      emitter  = "symlink";
      priority = 100;         # ← low priority; let other modules override
      destPrefix = ".config/myapp"; }
    { include  = [ "override.conf" ];
      emitter  = "symlink";
      priority = 1000;        # ← high priority; wins over other modules
      destPrefix = ".config/myapp"; }
  ];
in {
  home.file = result.homeFiles;
}
```

---

## Extension guide

### Adding a new pattern syntax

Extend `matchesPattern` in `lib/default.nix`:

```nix
matchesPattern = relPath: pattern:
  # … existing cases …
  else if lib.hasPrefix "~" pattern then
    lib.toLower relPath == lib.toLower (lib.removePrefix "~" pattern)
  else
    lib.hasPrefix pattern relPath;
```

### Adding a new emitter type to emit (recommended)

Use `registerEmitter` — no source modification needed:

```nix
let
  myEmitters = orc.registerEmitter orc.defaultEmitters "myType"
    ({ files, destPrefix, pkgs, drvName }:
      myBuilder files);

  result = orc.emit { inherit files pkgs; emitters = myEmitters; };
in …
```

### Adding a new home emitter to mergeHomeFiles

Fork `mergeHomeFiles` and add a new branch in the `finalResult` fold.
Example — a `"template"` emitter that substitutes `{{HOST}}`:

```nix
else if d.emitter == "template" then
  acc // {
    homeFiles = acc.homeFiles // {
      "${key}" = {
        text = lib.replaceStrings
          [ "{{HOST}}" ]
          [ config.networking.hostName ]
          d.text;
      };
    };
  }
```

### Custom transform pipeline (compose transforms)

```nix
let
  addHeader    = _: e: e // { text = "# header\n" + builtins.readFile e.absPath; };
  stripComments = _: e:
    e // { text = lib.concatStringsSep "\n"
      (lib.filter (l: !lib.hasPrefix "#" l)
        (lib.splitString "\n" (builtins.readFile e.absPath))); };

  compose = f: g: relPath: entry:
    let r = f relPath entry;
    in if r == null then null else g relPath r;

  pipeline = compose addHeader stripComments;
in
orc.mergeHomeFiles files [
  { include = [ "*.conf" ]; transform = pipeline; emitter = "text"; destPrefix = ".config/app"; }
]
```

---

## Troubleshooting

### `Conflicting managed target files`

See README.md. Short answer: use `force = true` in `xdg.configFile` or
`home.file`, or use `listFilesRecursiveFiltered` to avoid duplicate symlinks.

### Activation script does nothing in dry-run mode

Expected. home-manager's `run` helper silently prints commands when `DRY_RUN`
is set. Preview: `home-manager switch --dry-run`.

### `pkgs required for emitter="derivation"`

```nix
orc.readConfigDir { inherit src pkgs; … }
```

### `emitter="text" requires a transform that sets entry.text`

```nix
transform = _: e: e // { text = builtins.readFile e.absPath; };
# Or with a header:
transform = _: e: e // { text = "# managed\n" + builtins.readFile e.absPath; };
```

### `error: attribute 'emitter' missing`

You passed a raw `FileMap` to `emit` or `toHomeFiles`. Fix:

```nix
# Option A: tagAll (no filtering)
let tagged = orc.tagAll files;
    result = orc.emit { files = tagged; … };

# Option B: applyPolicies (with filtering)
let tagged = orc.applyPolicies [ { emitter = "homeFiles"; } ] files;
    result = orc.emit { files = tagged; … };

# Option C: readConfigDir (handles this automatically)
let result = orc.readConfigDir { inherit src; … };
```

### `Unknown emitter tag "…"`

You used an emitter name that isn't in the registry. Either:

- Use a built-in name: `"homeFiles"`, `"derivation"`, `"symlinkTree"`
- Register it with `registerEmitter` before calling `emit`

### Priority not affecting merge result

Ensure you're using `lib.mkMerge` in your home-manager module. The
`lib.mkOrder` wrapping from `priority != 5` only takes effect when
home-manager processes the attrset through `lib.mkMerge`. Direct attrset
merges (`//`) always let the right side win regardless of priority.
