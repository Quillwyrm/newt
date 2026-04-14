package main

import "base:runtime"
import "core:strings"
import "core:time"
import "core:c"
import os  "core:os"
import lua "luajit"

// ============================================================================
// Filesystem Helpers
// ============================================================================

file_type_to_kind :: proc "contextless"(ft: os.File_Type) -> string {
    switch ft {
    case .Regular:   return "file"
    case .Directory: return "directory"

    case .Undetermined,
         .Symlink,
         .Named_Pipe,
         .Socket,
         .Block_Device,
         .Character_Device:
        return "other"
    }
    return "other"
}

push_lua_string :: proc "contextless"(L: ^lua.State, s: string) {
    lua.pushlstring(L, cstring(raw_data(s)), c.size_t(len(s)))
}

push_lua_error :: proc(L: ^lua.State, err: os.Error) {
    msg := os.error_string(err)
    push_lua_string(L, msg)
}

// ============================================================================
// Lua Filesystem Bindings
// ============================================================================

// get_resource_directory() -> string
lua_filesystem_get_resource_directory :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 0 {
        lua.L_error(L, "filesystem.get_resource_directory: expected 0 arguments")
        return 0
    }

    push_lua_string(L, Resource_Directory_Path)
    return 1
}

// get_working_directory() -> string | (nil, err)
lua_filesystem_get_working_directory :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 0 {
        lua.L_error(L, "filesystem.get_working_directory: expected 0 arguments")
        return 0
    }

    dir, err := os.get_working_directory(context.temp_allocator)
    if err != os.ERROR_NONE {
        lua.pushnil(L)
        push_lua_error(L, err)
        return 2
    }

    push_lua_string(L, dir)
    return 1
}

// set_working_directory(path:string) -> (ok:boolean, err?:string)
lua_filesystem_set_working_directory :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 1 {
        lua.L_error(L, "filesystem.set_working_directory: expected 1 argument: path")
        return 0
    }

    path_len: c.size_t
    path_c := lua.L_checklstring(L, 1, &path_len)
    path := strings.string_from_ptr(cast(^byte)(path_c), int(path_len))

    err := os.set_working_directory(path)
    if err != os.ERROR_NONE {
        lua.pushboolean(L, b32(false))
        push_lua_error(L, err)
        return 2
    }

    lua.pushboolean(L, b32(true))
    return 1
}

// get_args() -> {string...}
lua_filesystem_get_args :: proc "c" (L: ^lua.State) -> c.int {

    if lua.gettop(L) != 0 {
        lua.L_error(L, "filesystem.get_args: expected 0 arguments")
        return 0
    }

    lua.newtable(L) // result table

    // Skip argv0 (exe path) and return user args only.
    if len(os.args) == 0 {
        return 1
    }

    j := 1
    for i in 1..<len(os.args) {
        arg := os.args[i]
        push_lua_string(L, arg)
        lua.rawseti(L, -2, c.int(j))
        j += 1
    }

    return 1
}

// list_directory(path:string) -> { {name:string, kind:string}... } | (nil, err)
lua_filesystem_list_directory :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 1 {
        lua.L_error(L, "filesystem.list_directory: expected 1 argument: path")
        return 0
    }

    path_len: c.size_t
    path_c := lua.L_checklstring(L, 1, &path_len)
    path := strings.string_from_ptr(cast(^byte)(path_c), int(path_len))

    infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
    if err != os.ERROR_NONE {
        lua.pushnil(L)
        push_lua_error(L, err)
        return 2
    }

    lua.newtable(L) // result array

    for i in 0..<len(infos) {
        fi := infos[i]

        lua.newtable(L) // entry

        // name
        push_lua_string(L, fi.name)
        lua.setfield(L, -2, "name")

        // kind
        kind := file_type_to_kind(fi.type)
        push_lua_string(L, kind)
        lua.setfield(L, -2, "kind")

        lua.rawseti(L, -2, c.int(i+1))
    }

    return 1
}

// get_path_info(path:string) -> {kind:string, size:number, modified_time:number} | (nil, err)
lua_filesystem_get_path_info :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 1 {
        lua.L_error(L, "filesystem.get_path_info: expected 1 argument: path")
        return 0
    }

    path_len: c.size_t
    path_c := lua.L_checklstring(L, 1, &path_len)
    path := strings.string_from_ptr(cast(^byte)(path_c), int(path_len))

    fi, err := os.stat(path, context.temp_allocator)
    if err != os.ERROR_NONE {
        lua.pushnil(L)
        push_lua_error(L, err)
        return 2
    }

    lua.newtable(L)

    kind := file_type_to_kind(fi.type)
    push_lua_string(L, kind)
    lua.setfield(L, -2, "kind")

    lua.pushinteger(L, cast(lua.Integer)(fi.size))
    lua.setfield(L, -2, "size")

    mtime := time.to_unix_seconds(fi.modification_time)
    lua.pushinteger(L, cast(lua.Integer)(mtime))
    lua.setfield(L, -2, "modified_time")

    return 1
}

// read_file(path:string) -> string | (nil, err)
lua_filesystem_read_file :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 1 {
        lua.L_error(L, "filesystem.read_file: expected 1 argument: path")
        return 0
    }

    path_len: c.size_t
    path_c := lua.L_checklstring(L, 1, &path_len)
    path := strings.string_from_ptr(cast(^byte)(path_c), int(path_len))

    data, err := os.read_entire_file_from_path(path, context.temp_allocator)
    if err != os.ERROR_NONE {
        lua.pushnil(L)
        push_lua_error(L, err)
        return 2
    }

    lua.pushlstring(L, cstring(raw_data(data)), c.size_t(len(data)))
    return 1
}

// write_file(path:string, data:string) -> (ok:boolean, err?:string)
// Creates the file if missing; overwrites/truncates if it exists.
lua_filesystem_write_file :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 2 {
        lua.L_error(L, "filesystem.write_file: expected 2 arguments: path, data")
        return 0
    }

    path_len: c.size_t
    path_c := lua.L_checklstring(L, 1, &path_len)
    path := strings.string_from_ptr(cast(^byte)(path_c), int(path_len))

    data_len: c.size_t
    data_c := lua.L_checklstring(L, 2, &data_len)
    data_str := strings.string_from_ptr(cast(^byte)(data_c), int(data_len))

    err := os.write_entire_file_from_string(path, data_str)
    if err != os.ERROR_NONE {
        lua.pushboolean(L, b32(false))
        push_lua_error(L, err)
        return 2
    }

    lua.pushboolean(L, b32(true))
    return 1
}


// make_directory(path:string) -> (ok:boolean, err?:string)
lua_filesystem_make_directory :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 1 {
        lua.L_error(L, "filesystem.make_directory: expected 1 argument: path")
        return 0
    }

    path_len: c.size_t
    path_c := lua.L_checklstring(L, 1, &path_len)
    path := strings.string_from_ptr(cast(^byte)(path_c), int(path_len))

    err := os.make_directory(path)
    if err != os.ERROR_NONE {
        lua.pushboolean(L, b32(false))
        push_lua_error(L, err)
        return 2
    }

    lua.pushboolean(L, b32(true))
    return 1
}

// rename(old_path:string, new_path:string) -> (ok:boolean, err?:string)
lua_filesystem_rename :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 2 {
        lua.L_error(L, "filesystem.rename: expected 2 arguments: old_path, new_path")
        return 0
    }

    old_len: c.size_t
    old_c := lua.L_checklstring(L, 1, &old_len)
    old_path := strings.string_from_ptr(cast(^byte)(old_c), int(old_len))

    new_len: c.size_t
    new_c := lua.L_checklstring(L, 2, &new_len)
    new_path := strings.string_from_ptr(cast(^byte)(new_c), int(new_len))

    err := os.rename(old_path, new_path)
    if err != os.ERROR_NONE {
        lua.pushboolean(L, b32(false))
        push_lua_error(L, err)
        return 2
    }

    lua.pushboolean(L, b32(true))
    return 1
}

// remove(path:string) -> (ok:boolean, err?:string)
lua_filesystem_remove :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 1 {
        lua.L_error(L, "filesystem.remove: expected 1 argument: path")
        return 0
    }

    path_len: c.size_t
    path_c := lua.L_checklstring(L, 1, &path_len)
    path := strings.string_from_ptr(cast(^byte)(path_c), int(path_len))

    err := os.remove(path)
    if err != os.ERROR_NONE {
        lua.pushboolean(L, b32(false))
        push_lua_error(L, err)
        return 2
    }

    lua.pushboolean(L, b32(true))
    return 1
}

// == Lua Registration ==

register_filesystem_api :: proc() {
    lua.newtable(Lua) // [filesystem]

    // Environment
    lua_bind_function(lua_filesystem_get_resource_directory, "get_resource_directory")
    lua_bind_function(lua_filesystem_get_working_directory, "get_working_directory")
    lua_bind_function(lua_filesystem_set_working_directory, "set_working_directory")
    lua_bind_function(lua_filesystem_get_args, "get_args")

    // Queries
    lua_bind_function(lua_filesystem_list_directory, "list_directory")
    lua_bind_function(lua_filesystem_get_path_info, "get_path_info")

    // File I/O
    lua_bind_function(lua_filesystem_read_file, "read_file")
    lua_bind_function(lua_filesystem_write_file, "write_file")

    // Path Operations
    lua_bind_function(lua_filesystem_make_directory, "make_directory")
    lua_bind_function(lua_filesystem_rename, "rename")
    lua_bind_function(lua_filesystem_remove, "remove")

    lua.setglobal(Lua, "filesystem")
}
