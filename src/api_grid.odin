package main

import "base:runtime"
import "core:c"
import lua "luajit"

// ============================================================================
// Datagrid Type And Helpers
// ============================================================================

// Datagrid is a dense 2D integer grid with fixed dimensions.
// Storage is flat row-major: len(cells) == width * height.
Datagrid :: struct {
    width:  int,
    height: int,
    cells:  []i32,
}

// new_datagrid allocates a zero-initialized datagrid of fixed size.
// Assumes width and height were already validated by the caller.
new_datagrid :: proc(width, height: int) -> Datagrid {
    return Datagrid{
        width  = width,
        height = height,
        cells  = make([]i32, width * height),
    }
}

// clone_datagrid duplicates a datagrid and all of its cell values.
clone_datagrid :: proc(src: ^Datagrid) -> Datagrid {
    dst := new_datagrid(src.width, src.height)

    for i in 0..<len(src.cells) {
        dst.cells[i] = src.cells[i]
    }

    return dst
}

// cell_in_bounds reports whether (x, y) is a valid cell coordinate.
cell_in_bounds :: proc(g: ^Datagrid, x, y: int) -> bool {
    return x >= 0 && x < g.width && y >= 0 && y < g.height
}

// cell_idx converts (x, y) cell coordinates into a flat row-major index.
// Assumes coordinates are already known-valid.
cell_idx :: proc(g: ^Datagrid, x, y: int) -> int {
    return y * g.width + x
}

// get_datagrid_cell returns the cell value at (x, y).
// Assumes coordinates are already known-valid.
get_datagrid_cell :: proc(g: ^Datagrid, x, y: int) -> i32 {
    return g.cells[cell_idx(g, x, y)]
}

// set_datagrid_cell writes value to the cell at (x, y).
// Assumes coordinates are already known-valid.
set_datagrid_cell :: proc(g: ^Datagrid, x, y: int, value: i32) {
    g.cells[cell_idx(g, x, y)] = value
}

// fill_datagrid overwrites every cell with the same value.
fill_datagrid :: proc(g: ^Datagrid, value: i32) {
    for i in 0..<len(g.cells) {
        g.cells[i] = value
    }
}

// ============================================================================
// Datagrid Lua Bindings
// ============================================================================

// grid.new_datagrid(w, h) -> datagrid
lua_grid_new_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    width  := cast(int)lua.L_checkinteger(L, 1)
    height := cast(int)lua.L_checkinteger(L, 2)

    if width <= 0 || height <= 0 {
        lua.L_error(L, "grid.new_datagrid: width and height must be positive")
        return 0
    }

    g := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    g^ = new_datagrid(width, height)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    return 1
}

// grid.get_cell(g, x, y) -> value | nil
// Returns nil if the datagrid has been freed.
// Returns nil for out-of-bounds reads.
lua_grid_get_cell :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        lua.pushnil(L)
        return 1
    }

    x := cast(int)lua.L_checkinteger(L, 2)
    y := cast(int)lua.L_checkinteger(L, 3)

    if !cell_in_bounds(g, x, y) {
        lua.pushnil(L)
        return 1
    }

    value := g.cells[cell_idx(g, x, y)]
    lua.pushinteger(L, cast(lua.Integer)value)
    return 1
}

// grid.set_cell(g, x, y, value)
// Dead datagrid writes are no-ops.
// Out-of-bounds writes are no-ops.
lua_grid_set_cell :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        return 0
    }

    x := cast(int)lua.L_checkinteger(L, 2)
    y := cast(int)lua.L_checkinteger(L, 3)
    value := cast(i32)lua.L_checkinteger(L, 4)

    if !cell_in_bounds(g, x, y) {
        return 0
    }

    g.cells[cell_idx(g, x, y)] = value
    return 0
}

// grid.fill_datagrid(g, value)
// Filling a freed datagrid is a no-op.
lua_grid_fill_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        return 0
    }

    value := cast(i32)lua.L_checkinteger(L, 2)
    fill_datagrid(g, value)
    return 0
}

// grid.clear_datagrid(g)
// Clearing a freed datagrid is a no-op.
lua_grid_clear_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        return 0
    }

    fill_datagrid(g, 0)
    return 0
}

// grid.clone_datagrid(g) -> datagrid
lua_grid_clone_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    src := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if src == nil || src.cells == nil {
        lua.L_error(L, "grid.clone_datagrid: source datagrid has been freed")
        return 0
    }

    dst := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    dst^ = clone_datagrid(src)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    return 1
}
// ============================================================================
// Datagrid Lua GC And Metatable
// ============================================================================

// lua_datagrid_gc releases a Datagrid's backing storage when Lua collects it.
lua_datagrid_gc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g != nil && g.cells != nil {
        delete(g.cells)
        g.cells = nil
        g.width = 0
        g.height = 0
    }

    return 0
}

// setup_grid_metatables registers the Datagrid userdata metatable.
setup_grid_metatables :: proc() {
    lua.L_newmetatable(Lua, "Datagrid")
    lua.pushcfunction(Lua, lua_datagrid_gc)
    lua.setfield(Lua, -2, "__gc")
    lua.pop(Lua, 1)
}

// ============================================================================
// Lua Registration
// ============================================================================

register_grid_api :: proc() {
    setup_grid_metatables()

    lua.newtable(Lua) // [grid]

    lua_bind_function(lua_grid_new_datagrid,   "new_datagrid")
    lua_bind_function(lua_grid_get_cell,       "get_cell")
    lua_bind_function(lua_grid_set_cell,       "set_cell")
    lua_bind_function(lua_grid_fill_datagrid,  "fill_datagrid")
    lua_bind_function(lua_grid_clear_datagrid, "clear_datagrid")
    lua_bind_function(lua_grid_clone_datagrid, "clone_datagrid")

    lua.setglobal(Lua, "grid")
}