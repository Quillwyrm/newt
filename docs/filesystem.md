# filesystem

The `filesystem` module provides access to process paths, directory queries, and basic file operations.  
Unless noted otherwise, functions in this module throw on wrong arity or wrong argument types. Relative paths in this module are resolved from the `Working Directory`.

## Functions

**Environment**
* [`get_resource_directory`](#get_resource_directory)
* [`get_working_directory`](#get_working_directory)
* [`set_working_directory`](#set_working_directory)
* [`get_args`](#get_args)

**Queries**
* [`list_directory`](#list_directory)
* [`get_path_info`](#get_path_info)

**File I/O**
* [`read_file`](#read_file)
* [`write_file`](#write_file)

**Path Operations**
* [`make_directory`](#make_directory)
* [`rename`](#rename)
* [`remove`](#remove)

## Environment

### get_resource_directory

Returns the absolute path of the `Resource Directory`, which is the directory containing the executable. This value is fixed by the host for the lifetime of the process.

```lua
filesystem.get_resource_directory() -> path
```

---

### get_working_directory

Returns the current `Working Directory` path. This is separate from the `Resource Directory` and can be changed at runtime.

```lua
filesystem.get_working_directory() -> path | nil, err
```

---

### set_working_directory

Sets the current `Working Directory` for the process. This affects how relative paths are resolved by other filesystem calls.

```lua
filesystem.set_working_directory(path) -> true | false, err
```

---

### get_args

Returns the command-line arguments passed to the program, excluding the executable path.

```lua
filesystem.get_args() -> args
```

#### Returns

`args` is an array of strings.

## Queries

### list_directory

Lists the entries in a directory.

```lua
filesystem.list_directory(path) -> entries | nil, err
```

#### Returns

`entries` is an array of tables with this shape:

```lua
{
    name = string,
    kind = "file" | "directory" | "other",
}
```

---

### get_path_info

Returns metadata for a path.

```lua
filesystem.get_path_info(path) -> info | nil, err
```

#### Returns

`info` has this shape:

```lua
{
    kind = "file" | "directory" | "other",
    size = number,
    modified_time = number,
}
```

`modified_time` is a Unix timestamp in seconds.

## File I/O

### read_file

Reads an entire file into a string.

```lua
filesystem.read_file(path) -> data | nil, err
```

---

### write_file

Writes a string to a file. Creates the file if it does not exist and overwrites it if it does.

```lua
filesystem.write_file(path, data) -> true | false, err
```

## Path Operations

### make_directory

Creates a directory.

```lua
filesystem.make_directory(path) -> true | false, err
```

---

### rename

Renames or moves a file or directory.

```lua
filesystem.rename(old_path, new_path) -> true | false, err
```

---

### remove

Removes a file or an empty directory.

```lua
filesystem.remove(path) -> true | false, err
```