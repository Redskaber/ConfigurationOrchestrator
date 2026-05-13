# API Reference

## Types

```
Path       :: Nix path (e.g. ./config or inputs.hypr-config)

FileMap    :: { "rel/path" = { absPath :: string; type :: string; }; }

TaggedMap  :: { "rel/path" = { absPath :: string
                               type    :: string
                               emitter  :: string
                               priority :: int
                               ?text   :: string
                               ?force  :: bool
                             };
              }

HomeFiles  :: { "dest/key" = { source :: string; } | { text :: string; }
                              [// { force :: bool; }]
                              [wrapped in lib.mkOrder]
              }

Activation :: string   (shell script for home.activation)

EmitResult :: { homeFiles    :: HomeFiles
                ?derivation  :: StorePath
                ?symlinkTree :: StorePath
                ?<custom>    :: any         (from registerEmitter)
              }

MergeResult :: { homeFiles  :: HomeFiles
                 activation :: Activation
               }

Policy :: { include   ? :: [ Pattern ]
            exclude   ? :: [ Pattern ]
            transform ? :: string → Entry → (Entry | null)
            emitter   ? :: string
            priority  ? :: int
          }

HomePolicy :: Policy // {
               destPrefix ? :: string
               force      ? :: bool
               # emitter values: "symlink" | "copy" | "text"
             }

Pattern :: string   (see pattern syntax below)

EmitterBuilder :: { files      :: TaggedMap
                    destPrefix :: string
                    pkgs       :: Pkgs?
                    drvName    :: string
                  } → any

EmitterRegistry :: { string = EmitterBuilder; }
```

---

## Pattern syntax

| Pattern           | Semantics                                          |
| ----------------- | -------------------------------------------------- |
| `[]` or `[ "*" ]` | Accept everything (universal wildcard)             |
| `"*"`             | Universal wildcard (any single string)             |
| `"sys/"`          | Prefix match                                       |
| `"*.conf"`        | Suffix match (leading `*` stripped)                |
| `"sys/*"`         | Prefix match (trailing `*` stripped)               |
| `"/ERE/"`         | POSIX extended regular expression (builtins.match) |

---

## TaggedMap invariant

`emit` and `toHomeFiles` require a **TaggedMap** — every entry must carry
`emitter` and `priority`. Use one of:

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

---

### `listFilesRecursive`

```
listFilesRecursive :: Path → string → FileMap
```

Recursively walks `dir`, collecting every non-directory entry. Call with
`prefix = ""` at the call-site.

---

### `listFilesRecursiveFiltered`

```
listFilesRecursiveFiltered :: Path → string → [ string ] → FileMap
```

Like `listFilesRecursive` but skips entries whose `type` is in `skipTypes`
at discovery time. Use `skipTypes = [ "symlink" ]` to prevent duplicate entries.

---

## Layer 2 · Policy Engine

### `defaultPolicy`

```
defaultPolicy :: Policy
```

The built-in policy defaults:

- `include = []` — accept everything
- `exclude = []` — drop nothing
- `transform = identity`
- `emitter = "homeFiles"`
- `priority = 5`

---

### `matchesPattern`

```
matchesPattern :: string → Pattern → bool
```

Tests whether `relPath` matches `pattern`. See pattern syntax above.

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

Stamps every entry with `emitter = "homeFiles"` and `priority = 5`.
No filtering — all entries survive.

Semantically equivalent to:

```nix
applyPolicies [ { include = []; emitter = "homeFiles"; priority = 5; } ] files
```

but avoids pattern-matching overhead.

`readConfigDir` calls `tagAll` internally when `policies = []`.

---

## Layer 3 · Emitters

### `toHomeFiles`

```
toHomeFiles :: string → TaggedMap → HomeFiles
```

Converts a tagged file map into a `home.file`-compatible attrset.
`destPrefix` is prepended to every destination key.

Entry mapping:

- `entry.text` present → `{ text = entry.text; }`
- `entry.force = true` → value `// { force = true; }`
- `entry.priority != 5` → value wrapped in `lib.mkOrder entry.priority`
- otherwise → `{ source = entry.absPath; }`

---

### `toDerivation`

```
toDerivation :: { pkgs :: Pkgs; name ? :: string; files :: TaggedMap } → StorePath
```

Builds a Nix store path that physically copies all files. Default `name`:
`"config-tree"`.

---

### `toSymlinkTree`

```
toSymlinkTree :: { pkgs :: Pkgs; name ? :: string; files :: TaggedMap } → StorePath
```

Builds a Nix store path whose contents are symlinks to source paths.
Default `name`: `"config-symlinks"`.

---

### `registerEmitter`

```
registerEmitter :: EmitterRegistry → string → EmitterBuilder → EmitterRegistry
```

Returns a new emitter registry with `name → builder` added. Use to extend
`emit` without modifying the library source (open/closed principle).

```nix
let
  myEmitters = orc.registerEmitter orc.defaultEmitters "myType"
    ({ files, destPrefix, pkgs, drvName }:
      myCustomBuilder files);
  result = orc.emit { inherit files pkgs; emitters = myEmitters; };
in …
```

---

### `defaultEmitters`

```
defaultEmitters :: EmitterRegistry
```

The built-in emitter registry. Pass to `registerEmitter` as the base when
adding custom emitters.

---

### `emit`

```
emit :: { files       :: TaggedMap
          destPrefix  ? :: string       (default: "")
          pkgs        ? :: Pkgs         (required for "derivation" or "symlinkTree")
          drvName     ? :: string       (default: "config-tree")
          emitters    ? :: EmitterRegistry   (default: builtinEmitters)
        } → EmitResult
```

Multi-emitter dispatch. Splits `files` by `emitter` tag and calls the
registered builder.

**Precondition:** every entry in `files` must have `emitter` and `priority`.
Use `tagAll`, `applyPolicy`, or `applyPolicies` before calling `emit` directly.

---

### `mergeHomeFiles`

```
mergeHomeFiles :: FileMap → [ HomePolicy ] → MergeResult
```

Home-manager-native combinator.

**HomePolicy fields** (all optional):

| Field        | Type          | Default     | Description                         |
| ------------ | ------------- | ----------- | ----------------------------------- |
| `include`    | `[ Pattern ]` | `[]`        | Accept everything if empty          |
| `exclude`    | `[ Pattern ]` | `[]`        | Drop nothing if empty               |
| `transform`  | function      | identity    | Modify entry or return null to drop |
| `emitter`    | string        | `"symlink"` | See table below                     |
| `destPrefix` | string        | `""`        | Prepended to destination key        |
| `priority`   | int           | `5`         | home-manager mkMerge priority       |
| `force`      | bool          | `false`     | Set force=true on homeFiles entries |

**Emitter destinations:**

| `emitter`   | Output channel | Effect                                                         |
| ----------- | -------------- | -------------------------------------------------------------- |
| `"symlink"` | `homeFiles`    | `{ source = absPath; ?force; ?mkOrder }` — read-only symlink   |
| `"copy"`    | `activation`   | `run cp --remove-destination` — writable file                  |
| `"text"`    | `homeFiles`    | `{ text = entry.text; ?force; ?mkOrder }` — requires transform |

**Eviction rule:** a `"copy"` policy evicts the same destination key from
`homeFiles`, even if a prior `"symlink"` policy placed it there.

**Activation script format:**

```sh
run mkdir -p "$(dirname "$HOME/<key>")"
run cp --remove-destination /nix/store/... "$HOME/<key>"
run chmod u+w "$HOME/<key>"
```

---

## High-level

### `readConfigDir`

```
readConfigDir :: { src        :: Path
                   recursive  ? :: bool           (default: true)
                   policies   ? :: [ Policy ]     (default: [])
                   destPrefix ? :: string         (default: "")
                   pkgs       ? :: Pkgs           (required for "derivation" or "symlinkTree")
                   name       ? :: string         (default: "config-tree")
                   emitters   ? :: EmitterRegistry (default: builtinEmitters)
                 } → EmitResult
```

Discovers files under `src`, applies `policies`, dispatches emitters.

**Internal pipeline:**

```
policies == []  →  Discovery → tagAll            → emit
policies != []  →  Discovery → applyPolicies     → emit
```

When `policies = []`, all discovered files pass through as `"homeFiles"`.

---

## Low-level exports (complete)

```
readDirFlat                  :: path → { name = type; }
listFilesRecursive           :: path → string → FileMap
listFilesRecursiveFiltered   :: path → string → [ type ] → FileMap
matchesPattern               :: relPath → pattern → bool
matchesAny                   :: relPath → [ pattern ] → bool
defaultPolicy                :: Policy
applyPolicy                  :: policy → files → TaggedMap
applyPolicies                :: [ policy ] → files → TaggedMap
tagAll                       :: FileMap → TaggedMap
toHomeFiles                  :: destPrefix → TaggedMap → HomeFiles
toDerivation                 :: { pkgs; name; files } → derivation
toSymlinkTree                :: { pkgs; name; files } → derivation
defaultEmitters              :: EmitterRegistry
registerEmitter              :: EmitterRegistry → string → builder → EmitterRegistry
emit                         :: { files; destPrefix; pkgs; drvName; emitters } → EmitResult
mergeHomeFiles               :: FileMap → [ homePolicy ] → MergeResult
readConfigDir                :: { src; recursive; policies; destPrefix; pkgs; name; emitters } → EmitResult
```
