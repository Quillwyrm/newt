# monotome.filesystem

The OS filesystem API for Monotome, providing access to the process working directory, launch arguments, directory listing, and basic file IO.

### Functions

**Roots / Startup**

* [`resource_dir`](#monotomefilesystemresource_dir)
* [`working_dir`](#monotomefilesystemworking_dir)
* [`set_working_dir`](#monotomefilesystemset_working_dir)
* [`args`](#monotomefilesystemargs)

**Directory**

* [`list_dir`](#monotomefilesystemlist_dir)
* [`info`](#monotomefilesysteminfo)

**Files**

* [`read_file`](#monotomefilesystemread_file)
* [`write_file`](#monotomefilesystemwrite_file)

**Mutations**

* [`mkdir`](#monotomefilesystemmkdir)
* [`rename`](#monotomefilesystemrename)
* [`remove`](#monotomefilesystemremove)

---

## monotome.filesystem.resource_dir

Returns the absolute directory containing the engine’s bundled runtime files (the folder that contains `lua/` and `fonts/` next to the executable).

### Usage

```lua
path = monotome.filesystem.resource_dir()
-- or
path, err = monotome.filesystem.resource_dir()
```

### Arguments

None.

### Returns

* `string: path` - Absolute resource directory.
* On failure: `nil, string: err`

---

## monotome.filesystem.working_dir

Returns the process current working directory (CWD). Relative paths passed to filesystem calls are resolved from this directory by the OS.

### Usage

```lua
path = monotome.filesystem.working_dir()
-- or
path, err = monotome.filesystem.working_dir()
```

### Arguments

None.

### Returns

* `string: path` - Absolute working directory.
* On failure: `nil, string: err`

---

## monotome.filesystem.set_working_dir

Sets the process current working directory (CWD). This is a global side-effect: it changes how the OS resolves relative paths for the whole program.

### Usage

```lua
ok = monotome.filesystem.set_working_dir(path)
-- or
ok, err = monotome.filesystem.set_working_dir(path)
```

### Arguments

* `string: path` - New working directory.

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`

---

## monotome.filesystem.args

Returns the launch arguments passed to the program, excluding the executable path (argv0). This is typically used to open files when launching via CLI or OS “Open with…”.

### Usage

```lua
args = monotome.filesystem.args()
```

### Arguments

None.

### Returns

* `table: args` - Array of strings (`args[1]..args[n]`).

---

## monotome.filesystem.list_dir

Lists the entries in a directory.

### Usage

```lua
entries = monotome.filesystem.list_dir(path)
-- or
entries, err = monotome.filesystem.list_dir(path)
```

### Arguments

* `string: path` - Directory path (absolute or relative).

### Returns

* `table: entries` - Array of entry tables:

  * `string: name` - Base name only (no path prefix).
  * `string: kind` - `"file"`, `"dir"`, or `"other"`.
* On failure: `nil, string: err`

### Notes

* `"."` and `".."` are not included.
* Ordering is unspecified; sort in Lua if needed.

---

## monotome.filesystem.info

Returns basic information about a path.

### Usage

```lua
info = monotome.filesystem.info(path)
-- or
info, err = monotome.filesystem.info(path)
```

### Arguments

* `string: path` - Path to inspect.

### Returns

* `table: info`

  * `string: kind` - `"file"`, `"dir"`, or `"other"`.
  * `number: size` - File size in bytes (meaningful for `"file"`).
  * `number: modified_time` - Unix timestamp in seconds.
* On failure: `nil, string: err`

---

## monotome.filesystem.read_file

Reads an entire file into a Lua string.

### Usage

```lua
data = monotome.filesystem.read_file(path)
-- or
data, err = monotome.filesystem.read_file(path)
```

### Arguments

* `string: path` - File path.

### Returns

* `string: data` - File contents (byte-accurate).
* On failure: `nil, string: err`

---

## monotome.filesystem.write_file

Writes a Lua string to a file. Creates the file if missing and overwrites/truncates if it exists.

### Usage

```lua
ok = monotome.filesystem.write_file(path, data)
-- or
ok, err = monotome.filesystem.write_file(path, data)
```

### Arguments

* `string: path` - File path.
* `string: data` - Data to write.

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`

---

## monotome.filesystem.mkdir

Creates a directory (single-level).

### Usage

```lua
ok = monotome.filesystem.mkdir(path)
-- or
ok, err = monotome.filesystem.mkdir(path)
```

### Arguments

* `string: path` - Directory path.

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`

---

## monotome.filesystem.rename

Renames (or moves) a file or directory.

### Usage

```lua
ok = monotome.filesystem.rename(old_path, new_path)
-- or
ok, err = monotome.filesystem.rename(old_path, new_path)
```

### Arguments

* `string: old_path`
* `string: new_path`

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`

---

## monotome.filesystem.remove

Removes a file or an empty directory.

### Usage

```lua
ok = monotome.filesystem.remove(path)
-- or
ok, err = monotome.filesystem.remove(path)
```

### Arguments

* `string: path`

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`

