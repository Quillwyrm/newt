package main

import "base:runtime"
import "core:mem"
import "core:c"
import lua "luajit"
import sdl "vendor:sdl3"

// ============================================================================
// Window State And Helpers
// ============================================================================

// App quit state requested by Lua or window events.
Quit_Requested : bool

Window_State: struct {
    moved:        bool,
    resized:      bool,
    focus_gained: bool,
    focus_lost:   bool,
    minimized:    bool,
    maximized:    bool,
    restored:     bool,
}

// Cursor tokens, cached as SDL system cursors.
// Fixed-size (bounded) cache: no growth, no maps.
Cursor_Cache : [12]^sdl.Cursor

check_window_safety :: #force_inline proc "contextless"(L: ^lua.State, fn_name: cstring) {
    if Window == nil {
        lua.L_error(L, "%s: window system not initialized yet", fn_name)
    }
}

// Parses a Lua flag list like {"fullscreen", "borderless", "resizable"}.
read_window_flags :: proc "contextless" (L: ^lua.State, idx: lua.Index) -> (fullscreen, borderless, resizable: bool) {
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
        s := transmute(string)mem.Raw_String{data = cast([^]byte)(p), len = int(len)}

        if s == "fullscreen" {
            fullscreen = true
        } else if s == "borderless" {
            borderless = true
        } else if s == "resizable" {
            resizable = true
        } else {
            lua.L_error(L, "window.set_flags: unknown flag '%s'", p)
        }

        lua.pop(L, 1)
        i += 1
    }
    return
}

window_begin_frame :: proc() {
    Window_State = {}
}

window_handle_event :: proc(event: ^sdl.Event) {
    #partial switch event.type {
    case .WINDOW_MOVED:
        Window_State.moved = true
    case .WINDOW_RESIZED:
        Window_State.resized = true
    case .WINDOW_FOCUS_GAINED:
        Window_State.focus_gained = true
    case .WINDOW_FOCUS_LOST:
        Window_State.focus_lost = true
    case .WINDOW_MINIMIZED:
        Window_State.minimized = true
    case .WINDOW_MAXIMIZED:
        Window_State.maximized = true
    case .WINDOW_RESTORED:
        Window_State.restored = true
    }
}

window_shutdown :: proc() {
    if Renderer != nil {
        sdl.DestroyRenderer(Renderer)
        Renderer = nil
    }

    if Window != nil {
        sdl.DestroyWindow(Window)
        Window = nil
    }

    for i in 0..<len(Cursor_Cache) {
        if Cursor_Cache[i] != nil {
            sdl.DestroyCursor(Cursor_Cache[i])
            Cursor_Cache[i] = nil
        }
    }
}

// ============================================================================
// Lua Window Bindings
// ============================================================================

// == Window Control ==

// window.set_flags(flags?)
lua_window_set_flags :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.set_flags")

    nargs := lua.gettop(L)
    if nargs > 1 {
        lua.L_error(L, "window.set_flags: expected 0 or 1 arguments")
        return 0
    }

    fullscreen, borderless, resizable := false, false, false
    if nargs == 1 && !lua.isnil(L, 1) {
        fullscreen, borderless, resizable = read_window_flags(L, 1)
    }

    if !sdl.SetWindowFullscreen(Window, fullscreen) {
        lua.L_error(L, "window.set_flags: SDL_SetWindowFullscreen failed: %s", sdl.GetError())
        return 0
    }

    sdl.SetWindowBordered(Window, !borderless)
    sdl.SetWindowResizable(Window, resizable)

    return 0
}


// window.close() -> request quit
lua_window_close :: proc "c" (L: ^lua.State) -> c.int {
    Quit_Requested = true
    return 0
}

// window.cancel_close()
lua_window_cancel_close :: proc "c" (L: ^lua.State) -> c.int {
    Quit_Requested = false
    return 0
}

// window.should_close() -> bool
lua_window_should_close :: proc "c" (L: ^lua.State) -> c.int {
    lua.pushboolean(L, cast(b32)Quit_Requested)
    return 1
}

// == Getters ==

// window.get_size() -> (w, h) pixels
lua_window_get_size :: proc "c" (L: ^lua.State) -> c.int {
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

// window.get_display_scale() -> float
lua_window_get_display_scale :: proc "c" (L: ^lua.State) -> c.int {
	check_window_safety(L, "window.get_display_scale")

	scale := sdl.GetWindowDisplayScale(Window)
	lua.pushnumber(L, cast(lua.Number)scale)
	return 1
}

// == Setters ==

// lua_window_set_title implements window.set_title(title).
lua_window_set_title :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.set_title")

    title_c := lua_check_cstring(L, 1, "window.set_title", "title")
    sdl.SetWindowTitle(Window, title_c)

    return 0
}

// lua_window_set_size implements window.set_size(width, height) in pixels.
lua_window_set_size :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.set_size")

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
    check_window_safety(L, "window.set_position")

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
    check_window_safety(L, "window.maximize")

    if !sdl.MaximizeWindow(Window) {
        lua.L_error(L, "window.maximize: failed to maximize window: %s", sdl.GetError())
        return 0
    }

    return 0
}

// lua_window_minimize implements window.minimize().
lua_window_minimize :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.minimize")

    if !sdl.MinimizeWindow(Window) {
        lua.L_error(L, "window.minimize: failed to minimize window: %s", sdl.GetError())
        return 0
    }

    return 0
}

// window.restore()
lua_window_restore :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.restore")

    if !sdl.RestoreWindow(Window) {
        lua.L_error(L, "window.restore: failed to restore window: %s", sdl.GetError())
        return 0
    }

    return 0
}

// window.resized() -> bool
lua_window_resized :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.resized")

    lua.pushboolean(L, cast(b32)Window_State.resized)
    return 1
}

// window.moved() -> bool
lua_window_moved :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.moved")

    lua.pushboolean(L, cast(b32)Window_State.moved)
    return 1
}

// window.is_focused() -> bool
lua_window_is_focused :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.is_focused")

    flags := sdl.GetWindowFlags(Window)
    lua.pushboolean(L, cast(b32)(.INPUT_FOCUS in flags))
    return 1
}

// window.focus_gained() -> bool
lua_window_focus_gained :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.focus_gained")

    lua.pushboolean(L, cast(b32)Window_State.focus_gained)
    return 1
}

// window.focus_lost() -> bool
lua_window_focus_lost :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.focus_lost")

    lua.pushboolean(L, cast(b32)Window_State.focus_lost)
    return 1
}

// window.minimized() -> bool
lua_window_minimized :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.minimized")

    lua.pushboolean(L, cast(b32)Window_State.minimized)
    return 1
}

// window.maximized() -> bool
lua_window_maximized :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.maximized")

    lua.pushboolean(L, cast(b32)Window_State.maximized)
    return 1
}

// window.restored() -> bool
lua_window_restored :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.restored")

    lua.pushboolean(L, cast(b32)Window_State.restored)
    return 1
}

// window.is_minimized() -> bool
lua_window_is_minimized :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.is_minimized")

    flags := sdl.GetWindowFlags(Window)
    lua.pushboolean(L, cast(b32)(.MINIMIZED in flags))
    return 1
}

// window.is_maximized() -> bool
lua_window_is_maximized :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.is_maximized")

    flags := sdl.GetWindowFlags(Window)
    lua.pushboolean(L, cast(b32)(.MAXIMIZED in flags))
    return 1
}

// == Cursor ==

// window.set_cursor(name)
lua_window_set_cursor :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.set_cursor")

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
    check_window_safety(L, "window.cursor_show")

    if !sdl.ShowCursor() {
        lua.L_error(L, "window.cursor_show: failed to show cursor: %s", sdl.GetError())
        return 0
    }
    return 0
}

// window.cursor_hide()
lua_window_cursor_hide :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.cursor_hide")

    if !sdl.HideCursor() {
        lua.L_error(L, "window.cursor_hide: failed to hide cursor: %s", sdl.GetError())
        return 0
    }
    return 0
}

// window.is_cursor_visible() -> bool
lua_window_is_cursor_visible :: proc "c" (L: ^lua.State) -> c.int {
    check_window_safety(L, "window.is_cursor_visible")

    lua.pushboolean(L, cast(b32)sdl.CursorVisible())
    return 1
}

// == Lua Registration ==

register_window_api :: proc() {
    lua.newtable(Lua) // [window]

    // Window control
    lua_bind_function(lua_window_set_flags, "set_flags")
    lua_bind_function(lua_window_close, "close")
    lua_bind_function(lua_window_cancel_close, "cancel_close")
    lua_bind_function(lua_window_should_close, "should_close")

    // Getters
    lua_bind_function(lua_window_get_size, "get_size")
    lua_bind_function(lua_window_get_position, "get_position")
    lua_bind_function(lua_window_get_display_scale, "get_display_scale")

    // Setters
    lua_bind_function(lua_window_set_title, "set_title")
    lua_bind_function(lua_window_set_size, "set_size")
    lua_bind_function(lua_window_set_position, "set_position")
    lua_bind_function(lua_window_maximize, "maximize")
    lua_bind_function(lua_window_minimize, "minimize")
    lua_bind_function(lua_window_restore, "restore")

    // Window state
    lua_bind_function(lua_window_resized, "resized")
    lua_bind_function(lua_window_moved, "moved")
    lua_bind_function(lua_window_is_focused, "is_focused")
    lua_bind_function(lua_window_focus_gained, "focus_gained")
    lua_bind_function(lua_window_focus_lost, "focus_lost")
    lua_bind_function(lua_window_minimized, "minimized")
    lua_bind_function(lua_window_maximized, "maximized")
    lua_bind_function(lua_window_restored, "restored")
    lua_bind_function(lua_window_is_minimized, "is_minimized")
    lua_bind_function(lua_window_is_maximized, "is_maximized")

    // Cursor
    lua_bind_function(lua_window_set_cursor, "set_cursor")
    lua_bind_function(lua_window_cursor_show, "cursor_show")
    lua_bind_function(lua_window_cursor_hide, "cursor_hide")
    lua_bind_function(lua_window_is_cursor_visible, "is_cursor_visible")

    lua.setglobal(Lua, "window")
}
