package main

import "core:c"
import "core:fmt"
import "core:mem"
import os "core:os"
import "core:strings"
import lua "luajit"
import sdl "vendor:sdl3"

// ============================================================================
// Core Engine State
// ============================================================================
DEFAULT_WINDOW_TITLE :: "Game"
DEFAULT_WINDOW_WIDTH :: 800
DEFAULT_WINDOW_HEIGHT :: 600

Window: ^sdl.Window
Renderer: ^sdl.Renderer
Lua: ^lua.State

// ============================================================================
// Engine Global Bindings
// ============================================================================

// free(userdata): call the userdata's __gc metamethod immediately if present..
lua_engine_global_free :: proc "c" (L: ^lua.State) -> c.int {
    if lua.type(L, 1) != lua.Type.USERDATA {
        return 0
    }
    if lua.L_getmetafield(L, 1, "__gc") != 0 {
        lua.pushvalue(L, 1)
        lua.call(L, 1, 0)
    }
    return 0
}

CORE_LUA_HELPERS :: `
local bit = require("bit")
local type = type
local tonumber = tonumber

function rgba(a, b, c, d)
    local t = type(a)
    if t == "number" then
        if not b then
            if a <= 0xFFFFFF then
                return bit.bor(bit.lshift(a, 8), 255)
            end
            return a
        end
        return bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d or 255)
    elseif t == "string" then
        local hex = string.byte(a, 1) == 35 and string.sub(a, 2) or a
        if #hex == 6 then hex = hex .. "FF" end
        return tonumber(hex, 16) or 0xFFFFFFFF
    end
    return 0xFFFFFFFF
end
`

// Registers top-level engine globals.
register_engine_global_api :: proc() {
    lua.pushcfunction(Lua, lua_engine_global_free)
    lua.setglobal(Lua, "free")

    // Inject core lua-side primitives
    if lua.L_dostring(Lua, cstring(CORE_LUA_HELPERS)) != lua.OK {
        fatal_engine_error(fmt.caprintf("engine.boot: failed to load core Lua helpers:\n%s", lua.tostring(Lua, -1)))
    }
}

// ============================================================================
// Fatal Path
// ============================================================================

// Error classes in host:
// - Lua-facing recoverable runtime failures return nil, err / false, err to Lua.
// - Uncaught top-level Lua errors and host boot/cannot-continue failures are fatal.
// - Engine invariants use panic, not the fatal error window.

// Terminal fatal path. Mirrors to stderr, shows the fatal window, exits.
fatal_engine_error :: proc(error_text: cstring) {

    err_text := error_text
    if err_text == nil do err_text = "Unknown Engine Error"

    // Keep terminal output for users who launched from shell.
    fmt.eprintln(err_text)

    // Shut down live subsystems so the error screen owns the process cleanly.
    audio_shutdown()
    input_shutdown()
    window_shutdown()

    window_flags: sdl.WindowFlags = {}
    Window = sdl.CreateWindow("Engine Error", 900, 900, window_flags)
    if Window == nil {
        fmt.eprintln("Failed to create error window:", sdl.GetError())
        os.exit(1)
    }

    Renderer = sdl.CreateRenderer(Window, nil)
    if Renderer == nil {
        fmt.eprintln("Failed to create error renderer:", sdl.GetError())
        sdl.DestroyWindow(Window)
        Window = nil
        os.exit(1)
    }

    _ = sdl.SetRenderVSync(Renderer, 1)

    running := true
    event: sdl.Event
    message := string(err_text)

    for running {
        mem.free_all(context.temp_allocator)

        for sdl.PollEvent(&event) {
            if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
                running = false
            }

            if event.type == .KEY_DOWN {
                if event.key.key == sdl.K_ESCAPE {
                    running = false
                }

                // Ctrl+C copies the full error text to the clipboard.
                if (event.key.mod & sdl.KMOD_CTRL) != {} && (event.key.key == 'c' || event.key.key == 'C') {
                    if !sdl.SetClipboardText(err_text) {
                        fmt.eprintln("Failed to copy error text to clipboard:", sdl.GetError())
                    }
                }
            }
        }

        // Background
        sdl.SetRenderDrawColor(Renderer, 15, 15, 15, 255)
        sdl.RenderClear(Renderer)

        // Header bar
        header_rect := sdl.FRect{16, 16, 108, 16}
        sdl.SetRenderDrawColor(Renderer, 255, 40, 40, 255)
        sdl.RenderFillRect(Renderer, &header_rect)

        // Header text
        sdl.SetRenderDrawColor(Renderer, 240, 240, 240, 255)
        _ = sdl.RenderDebugText(Renderer, 16, 880, "[ESC] Quit - [CTRL+C] Copy Error")

        // Header text
        sdl.SetRenderDrawColor(Renderer, 0, 0, 0, 255)
        _ = sdl.RenderDebugText(Renderer, 20, 20, "ENGINE ERROR:")

        // Body text
        sdl.SetRenderDrawColor(Renderer, 240, 240, 240, 255)

        cursor_y: f32 = 40
        line_start := 0

        for i := 0; i <= len(message); i += 1 {
            if i == len(message) || message[i] == '\n' {
                line := message[line_start:i]

                if len(line) > 0 {
                    line_c := strings.clone_to_cstring(line, context.temp_allocator)
                    _ = sdl.RenderDebugText(Renderer, 16, cursor_y, line_c)
                }

                cursor_y += 12
                line_start = i + 1
            }
        }
        sdl.RenderPresent(Renderer)
    }
    window_shutdown()
    os.exit(1)
}

// ============================================================================
// Lua Embedding Helpers
// ============================================================================

Lua_Binding :: proc "c" (L: ^lua.State) -> c.int

lua_bind_function :: proc(fn: Lua_Binding, fn_name: cstring) {
    lua.pushcfunction(Lua, fn)
    lua.setfield(Lua, -2, fn_name)
}

// Registers all Lua-facing engine modules.
register_lua_api :: proc(L: ^lua.State) {
    register_engine_global_api()

    register_filesystem_api()
    register_graphics_api()
    register_window_api()
    register_input_api()
    register_audio_api()

    lua.newtable(L)
    lua.setglobal(L, "runtime")
}

// lua_traceback is the error handler for lua.pcall; it converts an error into a traceback string.
lua_traceback :: proc "c" (L: ^lua.State) -> c.int {
    msg := lua.tostring(L, 1)
    if msg == nil {
        msg = "Lua error"
    }
    lua.L_traceback(L, L, msg, 1)
    return 1
}

// call_lua_noargs calls runtime[fn]() and fatal-exits on uncaught Lua error.
call_lua_noargs :: proc(func_name: cstring) {
    // 1. Push the error handler and get its absolute stack index
    lua.pushcfunction(Lua, lua_traceback)
    msg_handler_idx := lua.gettop(Lua)

    lua.getglobal(Lua, "runtime")
    lua.getfield(Lua, -1, func_name)

    cb_type := lua.type(Lua, -1)
    if cb_type == lua.Type.NIL {
        lua.pop(Lua, 3)
        return
    }
    if cb_type != lua.Type.FUNCTION {
        lua.pop(Lua, 3)
        fatal_engine_error(fmt.caprintf("runtime.%s is not a function", func_name))
    }
    if lua.pcall(Lua, 0, 0, cast(c.int)msg_handler_idx) != lua.OK {
        fatal_engine_error(fmt.caprintf("Lua error:\n%s", lua.tostring(Lua, -1)))
    }

    // Pop the runtime table and the traceback handler
    lua.pop(Lua, 2)
}

// call_lua_number calls runtime[fn](x: number) if present and fatal-exits on uncaught Lua error.
call_lua_number :: proc(func_name: cstring, arg: f64) {
    // 1. Push the error handler
    lua.pushcfunction(Lua, lua_traceback)
    msg_handler_idx := lua.gettop(Lua)

    lua.getglobal(Lua, "runtime")
    lua.getfield(Lua, -1, func_name)

    cb_type := lua.type(Lua, -1)
    if cb_type == lua.Type.NIL {
        lua.pop(Lua, 3)
        return
    }
    if cb_type != lua.Type.FUNCTION {
        lua.pop(Lua, 3)
        fatal_engine_error(fmt.caprintf("runtime.%s is not a function", func_name))
    }
    
    lua.pushnumber(Lua, lua.Number(arg))
    
    if lua.pcall(Lua, 1, 0, cast(c.int)msg_handler_idx) != lua.OK {
        fatal_engine_error(fmt.caprintf("Lua error:\n%s", lua.tostring(Lua, -1)))
    }

    lua.pop(Lua, 2)
}

prepend_package_path :: proc(exe_dir: string) {
    // Build:
    //   <exe_dir>/lua/?.lua;<exe_dir>/lua/?/init.lua;<old package.path>
    p1, err1 := os.join_path({exe_dir, "lua", "?.lua"}, context.temp_allocator)
    if err1 != os.ERROR_NONE { 
        fatal_engine_error(fmt.caprintf("engine.boot: join_path for lua/?.lua failed: %v", err1))
    }

    p2, err2 := os.join_path({exe_dir, "lua", "?", "init.lua"}, context.temp_allocator)
    if err2 != os.ERROR_NONE {
        fatal_engine_error(fmt.caprintf("engine.boot: join_path for lua/?/init.lua failed: %v", err2))
    }

    p1_c := strings.clone_to_cstring(p1, context.temp_allocator)
    p2_c := strings.clone_to_cstring(p2, context.temp_allocator)

    // package.path = p1..";"..p2..";"..package.path
    lua.getglobal(Lua, "package") // [package]
    lua.getfield(Lua, -1, "path") // [package, old_path]

    old_len: c.size_t
    old_c := lua.tolstring(Lua, -1, &old_len)

    lua.remove(Lua, -1) // [package]

    lua.pushstring(Lua, p1_c) // [package, p1]
    lua.pushstring(Lua, ";") // [package, p1, ";"]
    lua.pushstring(Lua, p2_c) // [package, p1, ";", p2]
    lua.pushstring(Lua, ";") // [package, p1, ";", p2, ";"]
    lua.pushlstring(Lua, old_c, old_len) // [package, p1, ";", p2, ";", old]

    lua.concat(Lua, 5) // [package, new_path]
    lua.setfield(Lua, -2, "path") // package.path = new_path; pops value

    lua.settop(Lua, 0) // []
}

// ============================================================================
// Main Runtime Entry
// ============================================================================
main :: proc() {

    // - SDL
    if !sdl.Init({.VIDEO}) {
        fmt.eprintln("SDL_Init failed:", sdl.GetError())
        return
    }
    defer sdl.Quit()

    // - Lua
    Lua = lua.L_newstate()
    if Lua == nil {
        fatal_engine_error("engine.boot: Lua L_newstate failed")
    }

    // Normal-exit cleanup only.
    // Fatal path exits inside fatal_engine_error().
    defer audio_shutdown()
    defer input_shutdown()
    defer window_shutdown()
    defer lua.close(Lua)

    lua.L_openlibs(Lua)
    register_lua_api(Lua)
    init_graphics_state()

    exe_dir, err := os.get_executable_directory(context.temp_allocator)
    if err != os.ERROR_NONE {
        fatal_engine_error(fmt.caprintf("engine.boot: failed to get executable directory: %v", err))
    }

    prepend_package_path(exe_dir)

    // - script Boot
    main_path, err2 := os.join_path({exe_dir, "lua", "main.lua"}, context.temp_allocator)
    if err2 != os.ERROR_NONE {
        fatal_engine_error(fmt.caprintf("engine.boot: failed to build path to lua/main.lua: %v", err2))
    }

    main_path_c := strings.clone_to_cstring(main_path, context.temp_allocator)

    if !os.exists(main_path) {
        fatal_engine_error("engine.boot: failed to find lua/main.lua. main.lua must exist in the lua directory next to the executable.")
    }

    if lua.L_dofile(Lua, main_path_c) != lua.Status.OK {
        fatal_engine_error(fmt.caprintf("Lua load error:\n%s", lua.tostring(Lua, -1)))
    }

    lua.settop(Lua, 0)
    mem.free_all(context.temp_allocator)

    // Host Boot
    audio_init()
    input_init()

    default_window_flags: sdl.WindowFlags = {.HIDDEN}

    Window = sdl.CreateWindow(DEFAULT_WINDOW_TITLE, DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT, default_window_flags)
    if Window == nil {
        fatal_engine_error(fmt.caprintf("engine.boot: SDL_CreateWindow failed: %s", sdl.GetError()))
    }

    Renderer = sdl.CreateRenderer(Window, nil)
    if Renderer == nil {
        sdl.DestroyWindow(Window)
        Window = nil
        fatal_engine_error(fmt.caprintf("engine.boot: SDL_CreateRenderer failed: %s", sdl.GetError()))
    }

    if !sdl.SetRenderVSync(Renderer, 1) {
        sdl.DestroyRenderer(Renderer)
        Renderer = nil
        sdl.DestroyWindow(Window)
        Window = nil
        fatal_engine_error(fmt.caprintf("engine.boot: SDL_SetRenderVSync failed: %s", sdl.GetError()))
    }

    // - User Init
    call_lua_noargs("init")

    if !sdl.ShowWindow(Window) {
        fatal_engine_error(fmt.caprintf("engine.boot: SDL_ShowWindow failed: %s", sdl.GetError()))
    }

    // - Main Loop
    perf_freq := f64(sdl.GetPerformanceFrequency())
    last_counter := sdl.GetPerformanceCounter()

    event: sdl.Event
    for !Quit_Requested {
        mem.free_all(context.temp_allocator)

        now_counter := sdl.GetPerformanceCounter()
        delta_ticks := now_counter - last_counter
        last_counter = now_counter
        dt := f64(delta_ticks) / perf_freq

        if dt > 0.1 {
            dt = 0.1
        }

        input_begin_frame()

        for sdl.PollEvent(&event) {
            if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
                Quit_Requested = true
            }
            input_handle_event(&event)
        }

        input_end_frame()

        audio_update()
        call_lua_number("update", dt)

        sdl.SetRenderDrawColor(Renderer, 0, 0, 0, 255)
        sdl.RenderClear(Renderer)
        Gfx_Ctx.current_sdl_color = u32rgba(0x000000FF)

        call_lua_noargs("draw")
        sdl.RenderPresent(Renderer)
    }
}
