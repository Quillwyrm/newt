# filesystem

The Luagame filesystem API provides access to the process environment, directory management, and basic file IO. All functions are available under the global `filesystem` module.

### Functions

**Roots / Environment**

* [`get_resource_dir`](#filesystemget_resource_dir)
* [`get_working_dir`](#filesystemget_working_dir)
* [`set_working_dir`](#filesystemset_working_dir)
* [`get_args`](#filesystemget_args)

**Directory Management**

* [`list_dir`](#filesystemlist_dir)
* [`info`](#filesysteminfo)
* [`mkdir`](#filesystemmkdir)

**File Operations**

* [`read_file`](#filesystemread_file)
* [`write_file`](#filesystemwrite_file)
* [`rename`](#filesystemrename)
* [`remove`](#filesystemremove)

---

## filesystem.get_resource_dir

Returns the absolute directory containing the Luagame executable. Use this to locate bundled assets like scripts and fonts relative to the binary.

### Usage

```lua
path, err = filesystem.get_resource_dir()
```

### Returns

* `string: path` - Absolute directory of the executable.
* On failure: `nil, string: err`

---

## filesystem.get_working_dir

Returns the current working directory (CWD) of the process. Relative paths in other filesystem calls are resolved from this location.

### Usage

```lua
path, err = filesystem.get_working_dir()
```

### Returns

* `string: path` - The absolute CWD.
* On failure: `nil, string: err`

---

## filesystem.set_working_dir

Sets the current working directory (CWD) for the process. This is a global side-effect affecting how the OS resolves relative paths.

### Usage

```lua
ok, err = filesystem.set_working_dir(path)
```

### Arguments

* `string: path` - The new directory path to set.

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`

---

## filesystem.get_args

Returns the command-line arguments passed to the program. This list excludes the executable path (`argv[0]`), providing only user-supplied arguments.

### Usage

```lua
args = filesystem.get_args()
```

### Returns

* `table: args` - An array of strings.

---

## filesystem.list_dir

Lists the entries within a specified directory.

### Usage

```lua
entries, err = filesystem.list_dir(path)
```

### Arguments

* `string: path` - The directory to list.

### Returns

* `table: entries` - An array of entry tables:
  * `string: name` - The name of the file or directory.
  * `string: kind` - `"file"`, `"dir"`, or `"other"`.
* On failure: `nil, string: err`

---

## filesystem.info

Returns metadata for a specific path.

### Usage

```lua
stats, err = filesystem.info(path)
```

### Arguments

* `string: path` - The path to inspect.

### Returns

* `table: stats`:
  * `string: kind` - `"file"`, `"dir"`, or `"other"`.
  * `number: size` - Size in bytes.
  * `number: modified_time` - Last modification as a Unix timestamp.
* On failure: `nil, string: err`

---

## filesystem.read_file

Reads the entire contents of a file into a string.

### Usage

```lua
data, err = filesystem.read_file(path)
```

### Arguments

* `string: path` - The file to read.

### Returns

* `string: data` - The file contents as a raw byte string.
* On failure: `nil, string: err`

---

## filesystem.write_file

Writes a string to a file. Creates the file if missing and overwrites/truncates it if it exists.

### Usage

```lua
ok, err = filesystem.write_file(path, data)
```

### Arguments

* `string: path` - The destination path.
* `string: data` - The string data to write.

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`

---

## filesystem.mkdir

Creates a new directory.

### Usage

```lua
ok, err = filesystem.mkdir(path)
```

### Arguments

* `string: path` - The directory path to create.

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`

---

## filesystem.rename

Renames or moves a file or directory.

### Usage

```lua
ok, err = filesystem.rename(old_path, new_path)
```

### Arguments

* `string: old_path`
* `string: new_path`

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`

---

## filesystem.remove

Deletes a file or an empty directory.

### Usage

```lua
ok, err = filesystem.remove(path)
```

### Arguments

* `string: path`

### Returns

* `boolean: ok` - `true` on success.
* On failure: `false, string: err`