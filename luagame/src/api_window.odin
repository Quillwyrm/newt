package main

import "base:runtime"
import "core:mem"
import "core:c"
import "core:strings"
import lua "luajit"
import sdl "vendor:sdl3"

//========================================================================================================================================
// HOST HELPERS & STATE
//========================================================================================================================================

//Quit queue state for lua quitting sdl
Quit_Requested : bool

// Cursor tokens, cached as SDL system cursors.
// Fixed-size (bounded) cache: no growth, no maps.
Cursor_Cache : [12]^sdl.Cursor

@(private)
check_window_safety :: #force_inline proc(L: ^lua.State, fn_name: cstring) {
    if Window == nil || Renderer == nil {
        lua.L_error(L, "%s: window system not initialized. Did you forget to call window.init() in runtime.init()?", fn_name)
    }
}

// read_window_flags parses {"fullscreen","borderless","resizable"} into three booleans.
read_window_flags :: proc(L: ^lua.State, idx: lua.Index) -> (fullscreen, borderless, resizable: bool) {
    lua.L_checktype(L, cast(c.int)(idx), lua.Type.TABLE)

    i: lua.Integer = 1
    for {
        lua.rawgeti(L, idx, i) // push flags[i]

        t := lua.type(L, -1)
        if t == lua.Type.NIL {
            lua.pop(L, 1)
            break
        }

        len: c.size_t
        p := lua.L_checklstring(L, -1, &len)
        s := strings.string_from_ptr(cast(^byte)(p), int(len))

        if s == "fullscreen" {
            fullscreen = true
        } else if s == "borderless" {
            borderless = true
        } else if s == "resizable" {
            resizable = true
        } else {
            lua.L_error(L, "window.init: unknown flag '%s'", p)
        }

        lua.pop(L, 1)
        i += 1
    }

    return
}

// apply_window_flags applies fullscreen/borderless/resizable via SDL setters.
apply_window_flags :: proc "contextless" (fullscreen, borderless, resizable: bool) {
    if Window == nil {
        return
    }

    // Fullscreen on/off.
    sdl.SetWindowFullscreen(Window, fullscreen)

    // Borderless toggle (borderless == true → bordered = false).
    sdl.SetWindowBordered(Window, !borderless)

    // Resizable toggle.
    sdl.SetWindowResizable(Window, resizable)
}

// window_shutdown cleans up SDL resources.
window_shutdown :: proc() {
    if Renderer != nil {
        sdl.DestroyRenderer(Renderer)
        Renderer = nil
    }

    if Window != nil {
        sdl.DestroyWindow(Window)
        Window = nil
    }
}


//========================================================================================================================================
// WINDOW API 
// Lua exposed API for handling sdl windowing (monotome.window.*)
//========================================================================================================================================

// ---------------------------------
// LIFECYCLE
// ---------------------------------

// window.init(width, height, title, flags?)
lua_window_init :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if Window != nil || Renderer != nil {
        lua.L_error(L, "window.init: already initialized")
        return 0
    }

    nargs := lua.gettop(L)
    if nargs < 3 {
        lua.L_error(L, "window.init: expected width, height, title, [flags]")
        return 0
    }

    w := int(lua.L_checkinteger(L, 1))
    h := int(lua.L_checkinteger(L, 2))

    title_len: c.size_t
    title_c := lua.L_checklstring(L, 3, &title_len)

    fs, borderless, resizable := false, false, false
    if nargs >= 4 && !lua.isnil(L, 4) {
        fs, borderless, resizable = read_window_flags(L, 4)
    }

    flags: sdl.WindowFlags = {}
    if fs do flags |= {.FULLSCREEN}
    if borderless do flags |= {.BORDERLESS}
    if resizable do flags |= {.RESIZABLE}

    // Step 1: create the SDL window.
    Window = sdl.CreateWindow(title_c, c.int(w), c.int(h), flags)
    if Window == nil {
        lua.L_error(L, "window.init: SDL_CreateWindow failed: %s", sdl.GetError())
        return 0
    }

    // Step 2: create the renderer. If this fails, roll back the window.
    Renderer = sdl.CreateRenderer(Window, nil)
    if Renderer == nil {
        sdl.DestroyWindow(Window)
        Window = nil

        lua.L_error(L, "window.init: SDL_CreateRenderer failed: %s", sdl.GetError())
        return 0
    }

    // Step 3: VSync is currently mandatory for Luagame.
    // If this fails, init is considered unsuccessful and we fully roll back.
    if !sdl.SetRenderVSync(Renderer, 1) {
        sdl.DestroyRenderer(Renderer)
        Renderer = nil

        sdl.DestroyWindow(Window)
        Window = nil

        lua.L_error(L, "window.init: SDL_SetRenderVSync failed: %s", sdl.GetError())
        return 0
    }

    return 0
}


// window.close() -> request quit
lua_window_close :: proc "c" (L: ^lua.State) -> c.int {
    Quit_Requested = true
    return 0
}

// window.should_close() -> bool
lua_window_should_close :: proc "c" (L: ^lua.State) -> c.int {
    lua.pushboolean(L, cast(b32)Quit_Requested)
    return 1
}


// ---------------------------------
// GETTERS
// ---------------------------------

// window.get_size() -> (w, h) pixels
lua_window_get_size :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L, "window.get_size")

    w, h: c.int
    if !sdl.GetWindowSize(Window, &w, &h) {
        lua.L_error(L, "window.get_size: failed to query window size: %s", sdl.GetError())
        return 0
    }

    lua.pushinteger(L, cast(lua.Integer)(w))
    lua.pushinteger(L, cast(lua.Integer)(h))
    return 2
}

// window.get_position() -> (x, y) pixels
lua_window_get_position :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L, "window.get_position")

    x, y: c.int
    if !sdl.GetWindowPosition(Window, &x, &y) {
        lua.L_error(L, "window.get_position: failed to query window position: %s", sdl.GetError())
        return 0
    }

    lua.pushinteger(L, cast(lua.Integer)(x))
    lua.pushinteger(L, cast(lua.Integer)(y))
    return 2
}

// window.metrics() -> (cols, rows, cell_w, cell_h, w, h, x, y)
// lua_window_metrics :: proc "c" (L: ^lua.State) -> c.int {
// 	if Window == nil {
// 		lua.L_error(L, "window.metrics: window not created")
// 		return 0
// 	}
// 	if Cell_W <= 0 || Cell_H <= 0 {
// 		lua.L_error(L, "window.metrics: Cell_W/Cell_H not initialized")
// 		return 0
// 	}

// 	w, h: c.int
// 	if !sdl.GetWindowSize(Window, &w, &h) {
// 		lua.L_error(L, "window.metrics: GetWindowSize failed")
// 		return 0
// 	}

// 	x, y: c.int
// 	if !sdl.GetWindowPosition(Window, &x, &y) {
// 		lua.L_error(L, "window.metrics: GetWindowPosition failed")
// 		return 0
// 	}

// 	cols := int(f32(w) / Cell_W)
// 	rows := int(f32(h) / Cell_H)

// 	lua.pushinteger(L, cast(lua.Integer)(cols))
// 	lua.pushinteger(L, cast(lua.Integer)(rows))
// 	lua.pushinteger(L, cast(lua.Integer)(int(Cell_W)))
// 	lua.pushinteger(L, cast(lua.Integer)(int(Cell_H)))
// 	lua.pushinteger(L, cast(lua.Integer)(w))
// 	lua.pushinteger(L, cast(lua.Integer)(h))
// 	lua.pushinteger(L, cast(lua.Integer)(x))
// 	lua.pushinteger(L, cast(lua.Integer)(y))
// 	return 8
// }


// ---------------------------------
// SETTERS
// ---------------------------------

// lua_window_set_title implements window.set_title(title).
lua_window_set_title :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.set_title")

    title_c := lua.L_checkstring(L, 1)
    sdl.SetWindowTitle(Window, title_c)

    return 0
}

// lua_window_set_size implements window.set_size(width, height) in pixels.
lua_window_set_size :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.set_size")

    w := lua.L_checkinteger(L, 1)
    h := lua.L_checkinteger(L, 2)

    if !sdl.SetWindowSize(Window, cast(c.int)(w), cast(c.int)(h)) {
        lua.L_error(L, "window.set_size: failed to set window size: %s", sdl.GetError())
        return 0
    }

    return 0
}

// lua_window_set_position implements window.set_position(x, y) in pixels.
lua_window_set_position :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.set_position")

    x := lua.L_checkinteger(L, 1)
    y := lua.L_checkinteger(L, 2)

    if !sdl.SetWindowPosition(Window, cast(c.int)(x), cast(c.int)(y)) {
        lua.L_error(L, "window.set_position: failed to set window position: %s", sdl.GetError())
        return 0
    }

    return 0
}

// lua_window_maximize implements window.maximize().
lua_window_maximize :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.maximize")

    if !sdl.MaximizeWindow(Window) {
        lua.L_error(L, "window.maximize: failed to maximize window: %s", sdl.GetError())
        return 0
    }

    return 0
}

// lua_window_minimize implements window.minimize().
lua_window_minimize :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.minimize")

    if !sdl.MinimizeWindow(Window) {
        lua.L_error(L, "window.minimize: failed to minimize window: %s", sdl.GetError())
        return 0
    }

    return 0
}


// ---------------------------------
// CURSOR
// ---------------------------------

// window.set_cursor(name)
lua_window_set_cursor :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.set_cursor")

    len: c.size_t
    p := lua.L_checklstring(L, 1, &len)
    name := transmute(string)mem.Raw_String{data = cast([^]byte)(p), len = int(len)}

    idx := -1
    id: sdl.SystemCursor

    // Love cursor names (no aliases)
    if name == "arrow" {
        idx = 0;  id = .DEFAULT
    } else if name == "ibeam" {
        idx = 1;  id = .TEXT
    } else if name == "wait" {
        idx = 2;  id = .WAIT
    } else if name == "waitarrow" {
        idx = 3;  id = .PROGRESS
    } else if name == "crosshair" {
        idx = 4;  id = .CROSSHAIR
    } else if name == "sizenwse" {
        idx = 5;  id = .NWSE_RESIZE
    } else if name == "sizenesw" {
        idx = 6;  id = .NESW_RESIZE
    } else if name == "sizewe" {
        idx = 7;  id = .EW_RESIZE
    } else if name == "sizens" {
        idx = 8;  id = .NS_RESIZE
    } else if name == "sizeall" {
        idx = 9;  id = .MOVE
    } else if name == "no" {
        idx = 10; id = .NOT_ALLOWED
    } else if name == "hand" {
        idx = 11; id = .POINTER
    } else {
        lua.L_error(L, "window.set_cursor: unknown cursor '%s'", p)
        return 0
    }

    cursor := Cursor_Cache[idx]
    if cursor == nil {
        cursor = sdl.CreateSystemCursor(id)
        if cursor == nil {
            lua.L_error(L, "window.set_cursor: failed to create system cursor: %s", sdl.GetError())
            return 0
        }
        Cursor_Cache[idx] = cursor
    }

    if !sdl.SetCursor(cursor) {
        lua.L_error(L, "window.set_cursor: failed to set cursor: %s", sdl.GetError())
        return 0
    }

    return 0
}

// window.cursor_show()
lua_window_cursor_show :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.cursor_show")

    if !sdl.ShowCursor() {
        lua.L_error(L, "window.cursor_show: failed to show cursor: %s", sdl.GetError())
        return 0
    }
    return 0
}

// window.cursor_hide()
lua_window_cursor_hide :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.cursor_hide")

    if !sdl.HideCursor() {
        lua.L_error(L, "window.cursor_hide: failed to hide cursor: %s", sdl.GetError())
        return 0
    }
    return 0
}

// window.is_cursor_visible() -> bool
lua_window_is_cursor_visible :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.is_cursor_visible")

    lua.pushboolean(L, cast(b32)sdl.CursorVisible())
    return 1
}

// ---------------------------------
// CLIPBOARD
// ---------------------------------

// window.get_clipboard() -> string
// Must free the SDL buffer via sdl.free (SDL_free).
lua_window_get_clipboard :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.get_clipboard")

    p := sdl.GetClipboardText()
    if p == nil {
        lua.L_error(L, "window.get_clipboard: failed to get clipboard text: %s", sdl.GetError())
        return 0
    }

    // Lua copies the C string into its own string object.
    lua.pushstring(L, cast(cstring)(p))

    // SDL owns this allocation.
    sdl.free(cast(rawptr)(p))

    return 1
}

// window.set_clipboard(text)
lua_window_set_clipboard :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_window_safety(L,"window.set_clipboard")

    len: c.size_t
    p := lua.L_checklstring(L, 1, &len)

    // Reject embedded NUL bytes (SDL takes cstring; otherwise it would truncate silently).
    bytes := cast([^]u8)(p)
    for i in 0..<int(len) {
        if bytes[i] == 0 {
            lua.L_error(L, "window.set_clipboard: text contains NUL byte")
            return 0
        }
    }

    if !sdl.SetClipboardText(cast(cstring)(p)) {
        lua.L_error(L, "window.set_clipboard: failed to set clipboard text: %s", sdl.GetError())
        return 0
    }

    return 0
}


// ---------------------------------
// REGISTRATION PROC
// ---------------------------------


// register_window_api creates the monotome.window table and registers all window procs.
register_window_api :: proc(L: ^lua.State) {
    lua.newtable(L) // [window]

    // lifecycle / init
    lua.pushcfunction(L, lua_window_init)
    lua.setfield(L, -2, "init")

    lua.pushcfunction(L, lua_window_close)
    lua.setfield(L, -2, "close")

    lua.pushcfunction(L, lua_window_should_close)
    lua.setfield(L, -2, "should_close")

    // getters (multi-return)
    lua.pushcfunction(L, lua_window_get_size)
    lua.setfield(L, -2, "get_size")

    lua.pushcfunction(L, lua_window_get_position)
    lua.setfield(L, -2, "get_position")

    // lua.pushcfunction(L, lua_window_metrics)
    // lua.setfield(L, -2, "metrics"))

    // setters / controls
    lua.pushcfunction(L, lua_window_set_title)
    lua.setfield(L, -2, "set_title")

    lua.pushcfunction(L, lua_window_set_size)
    lua.setfield(L, -2, "set_size")

    lua.pushcfunction(L, lua_window_set_position)
    lua.setfield(L, -2, "set_position")

    lua.pushcfunction(L, lua_window_maximize)
    lua.setfield(L, -2, "maximize")

    lua.pushcfunction(L, lua_window_minimize)
    lua.setfield(L, -2, "minimize")
    
    // cursor visuals
    lua.pushcfunction(L, lua_window_set_cursor)
    lua.setfield(L, -2, "set_cursor")

    lua.pushcfunction(L, lua_window_cursor_show)
    lua.setfield(L, -2, "cursor_show")

    lua.pushcfunction(L, lua_window_cursor_hide)
    lua.setfield(L, -2, "cursor_hide")

    lua.pushcfunction(L, lua_window_is_cursor_visible)
    lua.setfield(L, -2, "is_cursor_visible")
    
        // clipboard
    lua.pushcfunction(L, lua_window_get_clipboard)
    lua.setfield(L, -2, "get_clipboard")

    lua.pushcfunction(L, lua_window_set_clipboard)
    lua.setfield(L, -2, "set_clipboard")
    
    // Set the table as a global named "window"
    lua.setglobal(Lua, "window")
}


