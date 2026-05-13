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

Or explicitly with `tagAll` if you want to call `emit` yourself:

```nix
let
  files  = orc.listFilesRecursiveFiltered inputs.my-config "" [ "symlink" ];
  tagged = orc.tagAll files;
  result = orc.emit { files = tagged; destPrefix = ".config/myapp"; };
in
{ home.file = result.homeFiles; }
```

### Pattern 2 — One writable file, everything else symlinked

Best for tools like wallust, pywal, or any tool that writes a single config
file at runtime.

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

### Pattern 3 — Conflict with a home-manager module

When a module (e.g. `wayland.windowManager.hyprland`) generates a file
that conflicts with your config tree, use `xdg.configFile` with `force = true`
to win the conflict, and `mergeHomeFiles` only for the files that need to be
writable.

```nix
{
  # The whole tree via xdg.configFile — force=true wins conflicts
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

### Pattern 6 — Large stable tree as a symlink tree (efficient)

For very large trees, creating one symlink tree derivation is more efficient
than generating hundreds of individual `home.file` entries.

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

### Pattern 8 — tagAll for direct emit without policies

When you want full control of the emit pipeline but have no filtering
requirements, use `tagAll` to satisfy the `TaggedMap` contract:

```nix
let
  files  = orc.listFilesRecursiveFiltered inputs.my-config "" [ "symlink" ];
  # tagAll stamps { emitter = "homeFiles"; priority = 5; } on every entry
  tagged = orc.tagAll files;
  result = orc.emit {
    files      = tagged;
    destPrefix = ".config/myapp";
  };
in {
  home.file = result.homeFiles;
}
```

This is equivalent to `readConfigDir` with `policies = []` but lets you
control the discovery step separately.

---

## Extension guide

### Adding a new pattern syntax

Extend `matchesPattern` in `lib/default.nix`:

```nix
matchesPattern = relPath: pattern:
  # ... existing cases ...
  else if lib.hasPrefix "~" pattern then
    # custom case: case-insensitive match
    lib.toLower relPath == lib.toLower (lib.removePrefix "~" pattern)
  else
    lib.hasPrefix pattern relPath;
```

### Adding a new emitter type to `emit`

```nix
emit = { files, destPrefix ? "", pkgs ? null, drvName ? "config-tree" }:
  let
    # ... existing byEmitter calls ...
    customEntries = byEmitter "myCustomEmitter";

    customOutput =
      if customEntries == { } then null
      else myCustomBuilder { inherit pkgs; files = customEntries; };
  in
  { inherit homeFiles; }
  // lib.optionalAttrs (derivation    != null) { inherit derivation; }
  // lib.optionalAttrs (symlinkTree   != null) { inherit symlinkTree; }
  // lib.optionalAttrs (customOutput  != null) { myCustom = customOutput; };
```

### Adding a new emitter to `mergeHomeFiles`

Add a new branch in the `finalResult` fold:

```nix
else if d.emitter == "template" then
  acc // {
    homeFiles = acc.homeFiles // {
      "${key}" = { text = lib.replaceStrings [ "{{HOST}}" ] [ config.networking.hostName ] d.text; };
    };
  }
```

### Custom transform pipeline

Transforms can be composed manually:

```nix
let
  addHeader = _: e: e // { text = "# header\n" + builtins.readFile e.absPath; };
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

See the dedicated section in README.md. Short answer: use `force = true` in
`xdg.configFile` or `home.file`, or use `listFilesRecursiveFiltered` to avoid
discovering duplicate symlinks.

### Activation script does nothing in dry-run mode

This is expected. home-manager's `run` helper silently prints commands when
`DRY_RUN` is set. To preview: `home-manager switch --dry-run`.

### `pkgs required for emitter="derivation"`

Pass `pkgs` to `readConfigDir` or `emit`:

```nix
orc.readConfigDir { inherit src pkgs; ... }
```

### `emitter="text" requires a transform that sets entry.text`

The `"text"` emitter requires `entry.text` to be set. Add a `transform`:

```nix
transform = _: e: e // { text = builtins.readFile e.absPath; };
```

Or with a header:

```nix
transform = _: e: e // { text = "# managed\n" + builtins.readFile e.absPath; };
```

### `«error: attribute 'emitter' missing»`

You are passing a raw `FileMap` (output of `listFilesRecursive` or
`readDirFlat`) directly to `emit` or `toHomeFiles`. These functions require a
`TaggedMap`. Fix by tagging the files first:

```nix
# Option A: use tagAll when you have no filtering requirements
let tagged = orc.tagAll files;
    result = orc.emit { files = tagged; ... };

# Option B: use applyPolicies when you want to filter/tag by rules
let tagged = orc.applyPolicies [ { emitter = "homeFiles"; } ] files;
    result = orc.emit { files = tagged; ... };

# Option C: use readConfigDir which handles this for you
let result = orc.readConfigDir { inherit src; ... };
```

Note: `readConfigDir` with `policies = []` automatically calls `tagAll`,
so this error should not occur when using the high-level API.
