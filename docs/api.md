# API Reference

## Types

```
Path       :: Nix path (e.g. ./config or inputs.hypr-config)
FileMap    :: { "rel/path" = { absPath :: string; type :: string; }; }
TaggedMap  :: { "rel/path" = { absPath; type; emitter; priority; ?text; }; }
HomeFiles  :: { "dest/key" = { source :: string; } | { text :: string; }; }
Activation :: string   (shell script for home.activation)

EmitResult :: {
  homeFiles    :: HomeFiles
  derivation   :: StorePath   (present only if "derivation" emitter used)
  symlinkTree  :: StorePath   (present only if "symlinkTree" emitter used)
}

MergeResult :: {
  homeFiles  :: HomeFiles
  activation :: Activation
}

Policy :: {
  include   ? :: [ Pattern ]
  exclude   ? :: [ Pattern ]
  transform ? :: string → Entry → (Entry | null)
  emitter   ? :: string
  priority  ? :: int
}

HomePolicy :: Policy // {
  destPrefix ? :: string
  # emitter values: "symlink" | "copy" | "text"
}

Pattern :: string   (see pattern syntax in README)
```

### TaggedMap invariant

`emit` and `toHomeFiles` require a **TaggedMap** — every entry must carry
`emitter` and `priority`. Callers must ensure this by using one of:

| Function        | When to use                                           |
| --------------- | ----------------------------------------------------- |
| `applyPolicy`   | Apply a single policy (filters + tags matching files) |
| `applyPolicies` | Apply a list of policies (last-wins per file)         |
| `tagAll`        | Tag all files with defaults (no filtering)            |

Never pass a raw `FileMap` directly to `emit` or `toHomeFiles`.

---

## Layer 1 · Discovery

### `readDirFlat`

```
readDirFlat :: Path → { string = string; }
```

Non-recursive directory listing. Returns `{ name → type }` where type is
one of `"regular"`, `"directory"`, `"symlink"`, `"unknown"`.

This is a thin wrapper around `builtins.readDir`.

---

### `listFilesRecursive`

```
listFilesRecursive :: Path → string → FileMap
```

Recursively walks `dir`, collecting every non-directory entry
(regular, symlink, unknown). Call with `prefix = ""` at the call-site.

Returns: `{ "rel/path" = { absPath; type; }; }`

---

### `listFilesRecursiveFiltered`

```
listFilesRecursiveFiltered :: Path → string → [ string ] → FileMap
```

Like `listFilesRecursive` but skips entries whose `type` is in `skipTypes`
at discovery time. The skip propagates through all recursive calls.

Use `skipTypes = [ "symlink" ]` to prevent aliased source-tree symlinks
from generating duplicate `home.file` entries.

---

## Layer 2 · Policy Engine

### `matchesPattern`

```
matchesPattern :: string → Pattern → bool
```

Tests whether `relPath` matches `pattern`. See pattern syntax in README.

---

### `matchesAny`

```
matchesAny :: string → [ Pattern ] → bool
```

Returns `true` if `relPath` matches any pattern in the list.

---

### `applyPolicy`

```
applyPolicy :: Policy → FileMap → TaggedMap
```

Applies a single policy to a file map. Surviving entries are tagged with
`{ emitter; priority }`. The `transform` function may also add `{ text }`.

Policy defaults:

- `include = []` — accept everything
- `exclude = []` — drop nothing
- `transform = identity` — no modification
- `emitter = "homeFiles"`
- `priority = 5`

---

### `applyPolicies`

```
applyPolicies :: [ Policy ] → FileMap → TaggedMap
```

Applies a list of policies in order. **Last match wins per file.**

Files not matched by any policy are excluded from the result.

---

### `tagAll`

```
tagAll :: FileMap → TaggedMap
```

Stamps every entry in a raw `FileMap` with the default emitter
(`"homeFiles"`) and priority (5). No filtering is applied — all entries
survive.

Use this when you want every discovered file to become a `home.file`
entry without any include/exclude logic. Semantically equivalent to:

```nix
applyPolicies [ { include = []; emitter = "homeFiles"; priority = 5; } ] files
```

but avoids the pattern-matching overhead.

`readConfigDir` calls `tagAll` internally when `policies = []`, ensuring
that `emit` always receives a valid `TaggedMap`.

---

## Layer 3 · Emitters

### `toHomeFiles`

```
toHomeFiles :: string → TaggedMap → HomeFiles
```

Converts a tagged file map into a `home.file`-compatible attrset.
`destPrefix` is prepended to every destination key (use `""` for none).

Entry mapping:

- `entry.text` present → `{ text = entry.text; }`
- `entry.force = true` present → value `// { force = true; }`
- otherwise → `{ source = entry.absPath; }`

**Note:** home-manager installs all `home.file` entries as symlinks.
See architecture.md for the symlink constraint.

---

### `toDerivation`

```
toDerivation :: { pkgs :: Pkgs; name ? :: string; files :: TaggedMap } → StorePath
```

Builds a Nix store path that physically copies all files.
Inline text entries (`entry.text`) are materialised via `builtins.toFile`.

Default `name`: `"config-tree"`.

---

### `toSymlinkTree`

```
toSymlinkTree :: { pkgs :: Pkgs; name ? :: string; files :: TaggedMap } → StorePath
```

Builds a Nix store path whose contents are symlinks to source paths.
Text entries are materialised via `builtins.toFile` before symlinking.

Default `name`: `"config-symlinks"`.

---

### `emit`

```
emit :: {
  files       :: TaggedMap
  destPrefix  ? :: string      (default: "")
  pkgs        ? :: Pkgs        (required for "derivation" or "symlinkTree")
  drvName     ? :: string      (default: "config-tree")
} → EmitResult
```

Multi-emitter dispatch. Splits `files` by each entry's `emitter` tag and
calls the appropriate low-level builder.

**Precondition:** every entry in `files` must have `emitter` and `priority`.
Use `tagAll`, `applyPolicy`, or `applyPolicies` before calling `emit` directly.

`pkgs` is required (and asserted) when any entry uses `"derivation"` or
`"symlinkTree"`. `destPrefix` applies only to `homeFiles` keys.

---

### `mergeHomeFiles`

```
mergeHomeFiles :: FileMap → [ HomePolicy ] → MergeResult
```

Home-manager-native combinator. Processes `files` through `policies` and
returns two channels:

- `homeFiles` — assign to `home.file = result.homeFiles`
- `activation` — assign to `home.activation.<n> = lib.hm.dag.entryAfter ["writeBoundary"] result.activation`

**HomePolicy fields** (all optional):

| Field        | Type          | Default     | Description                         |
| ------------ | ------------- | ----------- | ----------------------------------- |
| `include`    | `[ Pattern ]` | `[]`        | Accept everything if empty          |
| `exclude`    | `[ Pattern ]` | `[]`        | Drop nothing if empty               |
| `transform`  | function      | identity    | Modify entry or return null to drop |
| `emitter`    | string        | `"symlink"` | See emitter table below             |
| `destPrefix` | string        | `""`        | Prepended to destination key        |
| `priority`   | int           | `5`         | home-manager mkMerge priority       |

**Emitter destinations:**

| `emitter`   | Output channel | Effect                                        |
| ----------- | -------------- | --------------------------------------------- |
| `"symlink"` | `homeFiles`    | `{ source = absPath; }` — read-only symlink   |
| `"copy"`    | `activation`   | `run cp --remove-destination` — writable file |
| `"text"`    | `homeFiles`    | `{ text = entry.text; }` — requires transform |

**Eviction rule:** a `"copy"` policy evicts the same destination key from
`homeFiles`, even if a prior `"symlink"` policy placed it there.

**Activation script format:** each `"copy"` entry generates:

```sh
run mkdir -p "$(dirname "$HOME/<key>")"
run cp --remove-destination /nix/store/... "$HOME/<key>"
run chmod u+w "$HOME/<key>"
```

The `run` helper is provided by home-manager and respects `DRY_RUN`.

---

## High-level

### `readConfigDir`

```
readConfigDir :: {
  src        :: Path
  recursive  ? :: bool      (default: true)
  policies   ? :: [ Policy ] (default: [])
  destPrefix ? :: string    (default: "")
  pkgs       ? :: Pkgs      (required for "derivation" or "symlinkTree")
  name       ? :: string    (default: "config-tree")
} → EmitResult
```

Discovers files under `src`, applies `policies`, dispatches emitters.

**Internal pipeline:**

```
policies == []  →  Discovery → tagAll            → emit
policies != []  →  Discovery → applyPolicies     → emit
```

When `policies = []`, all discovered files pass through as `"homeFiles"`.
`tagAll` ensures every entry is a valid `TaggedMap` entry before `emit`.
