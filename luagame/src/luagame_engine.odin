package main

import "base:runtime"
import "core:mem"	
import "core:fmt"
import "core:strings"
import "core:c"
import os  "core:os"
import sdl "vendor:sdl3"
import lua "luajit"

//========================================================================================================================================
// CORE ENGINE STATE
//========================================================================================================================================

Window   : ^sdl.Window
Renderer : ^sdl.Renderer
Lua 		 : ^lua.State

//=========================================================================================
// ENGINE GLOBAL API
//=========================================================================================

// lua_engine_global_free implements: free(userdata)
// This is the universal garbage disposal verb. It looks up the __gc metamethod
// of any userdata passed to it and executes it immediately, freeing backend resources.
lua_engine_global_free :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	// 1. Ensure the user actually passed a Userdata object. Ignore everything else.
	if lua.type(L, 1) != lua.Type.USERDATA {
		return 0
	}

	// 2. Check if the userdata has a "__gc" field in its attached metatable.
	// If it does, L_getmetafield pushes that function to the top of the stack.
	// Stack: [1: Userdata] ... [Top: __gc Function]
	if lua.L_getmetafield(L, 1, cstring("__gc")) != 0 {
		
		// 3. Push a copy of the userdata object to the top of the stack.
		// The __gc function expects the userdata as its first argument.
		// Stack: [1: Userdata] ... [Top-1: __gc Function] [Top: Userdata Copy]
		lua.pushvalue(L, 1)
		
		// 4. Execute the function. (1 argument, 0 return values expected).
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

// register_engine_global_api registers top-level engine builtins like `free`.
// These are injected directly into the global namespace, side-by-side with `print`.
register_engine_global_api :: proc(L: ^lua.State) {
	lua.pushcfunction(L, lua_engine_global_free)
	lua.setglobal(L, cstring("free"))
	
	// Inject core lua-side primitives
	if lua.L_dostring(L, cstring(CORE_LUA_HELPERS)) != lua.OK {
		fmt.eprintln("Failed to load core Lua helpers:\n", lua.tostring(L, -1))
		lua.pop(L, 1)
	}
}

//========================================================================================================================================
// LUA EMBEDDING HELPERS
//========================================================================================================================================

// register_lua_api initializes and exposes all engine sub-systems to the Lua environment.
// Each 'register_*_api' call is responsible for creating its own global table (e.g., 'graphics', 'input')
// and binding its respective Odin procedures to Lua functions.
register_lua_api :: proc() {
		register_engine_global_api(Lua)
	
    register_filesystem_api(Lua)
    register_graphics_api(Lua)
    register_window_api(Lua)
    register_input_api(Lua)
    register_audio_api(Lua)
    
    // The 'runtime' table acts as a general-purpose namespace for engine-level 
    // metadata and lifecycle states that don't fit into specific sub-systems.
    lua.newtable(Lua)
    lua.setglobal(Lua, cstring("runtime"))
}

// lua_traceback is the error handler for lua.pcall; it converts an error into a traceback string.
lua_traceback :: proc "c" (L: ^lua.State) -> c.int {
	msg := lua.tostring(L, 1)
	if msg == nil {
		msg = cstring("Lua error")
	}
	lua.L_traceback(L, L, msg, 1)
	return 1
}

// call_lua_noargs calls runtime[fn]() and prints any Lua error.
call_lua_noargs :: proc(func_name: cstring) -> bool {
    // 1. Push the error handler and get its absolute stack index
    lua.pushcfunction(Lua, lua_traceback)
    msg_handler_idx := lua.gettop(Lua)

    lua.getglobal(Lua, cstring("runtime"))
    lua.getfield(Lua, -1, func_name)
    
    if lua.type(Lua, -1) != lua.Type.FUNCTION {
        // Pop the nil field, the runtime table, and the traceback handler
        lua.pop(Lua, 3) 
        return true
    }

    // 2. Execute pcall with msg_handler_idx as the 4th argument
    if lua.pcall(Lua, 0, 0, cast(c.int)msg_handler_idx) != lua.OK {
        fmt.eprintln("Lua error:\n", lua.tostring(Lua, -1))
        // Pop the error string, the runtime table, and the traceback handler
        lua.pop(Lua, 3) 
        return false
    }
    
    // Pop the runtime table and the traceback handler
    lua.pop(Lua, 2) 
    return true
}

// call_lua_number calls runtime[fn](x: number) and prints any Lua error.
call_lua_number :: proc(func_name: cstring, arg: f64) -> bool {
    // 1. Push the error handler
    lua.pushcfunction(Lua, lua_traceback)
    msg_handler_idx := lua.gettop(Lua)

    lua.getglobal(Lua, cstring("runtime"))
    lua.getfield(Lua, -1, func_name)
    
    if lua.type(Lua, -1) != lua.Type.FUNCTION {
        lua.pop(Lua, 3)
        return true
    }

    lua.pushnumber(Lua, lua.Number(arg))
    
    // 2. Execute pcall
    if lua.pcall(Lua, 1, 0, cast(c.int)msg_handler_idx) != lua.OK {
        fmt.eprintln("Lua error:\n", lua.tostring(Lua, -1))
        lua.pop(Lua, 3)
        return false
    }
    
    lua.pop(Lua, 2)
    return true
}

prepend_package_path :: proc(L: ^lua.State, exe_dir: string) {
	// Build:
	//   <exe_dir>/lua/?.lua;<exe_dir>/lua/?/init.lua;<old package.path>
	p1, err1 := os.join_path({exe_dir, "lua", "?.lua"}, context.temp_allocator)
	if err1 != os.ERROR_NONE {
		fmt.eprintln("join_path for lua/?.lua failed:", err1)
		return
	}
	p2, err2 := os.join_path({exe_dir, "lua", "?", "init.lua"}, context.temp_allocator)
	if err2 != os.ERROR_NONE {
		fmt.eprintln("join_path for lua/?/init.lua failed:", err2)
		return
	}

	p1_c := strings.clone_to_cstring(p1, context.temp_allocator)
	p2_c := strings.clone_to_cstring(p2, context.temp_allocator)

	// package.path = p1..";"..p2..";"..package.path
	lua.getglobal(L, cstring("package"))              // [package]
	lua.getfield(L, -1, cstring("path"))             // [package, old_path]

	old_len: c.size_t
	old_c := lua.tolstring(L, -1, &old_len)

	lua.remove(L, -1)                                 // [package]

	lua.pushstring(L, p1_c)                           // [package, p1]
	lua.pushstring(L, cstring(";"))                   // [package, p1, ";"]
	lua.pushstring(L, p2_c)                           // [package, p1, ";", p2]
	lua.pushstring(L, cstring(";"))                   // [package, p1, ";", p2, ";"]
	lua.pushlstring(L, old_c, old_len)                // [package, p1, ";", p2, ";", old]

	lua.concat(L, 5)                                  // [package, new_path]
	lua.setfield(L, -2, cstring("path"))              // package.path = new_path; pops value

	lua.settop(L, 0)                                  // []
}

//========================================================================================================================================
// MAIN RUNTIME ENTRY
//========================================================================================================================================
main :: proc() {
  context = runtime.default_context()

  // ---------------------------------------------------------------------
  // SDL
  // ---------------------------------------------------------------------
  // Initialize the platform layer. VIDEO is required for window and renderer creation.
  if !sdl.Init({.VIDEO}) {
    fmt.eprintln("SDL_Init failed:", sdl.GetError())
    return
  }
  defer sdl.Quit()

  // ---------------------------------------------------------------------
  // Lua: Initialization & API Binding
  // ---------------------------------------------------------------------
  // Spin up the LuaJIT virtual machine state.
  Lua = lua.L_newstate()
  if Lua == nil {
    fmt.eprintln("Lua L_newstate failed")
    return
  }
  
  // Load standard libraries (math, table, string, etc.) and bind engine modules.
  lua.L_openlibs(Lua)
  register_lua_api()

  init_graphics_state()

  // Resolve the executable path to ensure relative asset loading works across different OS environments.
  exe_dir, err := os.get_executable_directory(context.temp_allocator)
  if err != os.ERROR_NONE {
    fmt.eprintln("get_executable_directory failed:", err)
    return
  }
  
  // Inject the local /lua/ folder into the Lua package search path.
  prepend_package_path(Lua, exe_dir)

  // ---------------------------------------------------------------------
  // Pre-Flight Configuration (Captures audio config from global scope)
  // ---------------------------------------------------------------------
  // Execute the top-level scope of main.lua. This allows scripts to define 
  // hardware-level settings (like audio buffer sizes) before the hardware is actually opened.
  main_path, err2 := os.join_path({exe_dir, "lua", "main.lua"}, context.temp_allocator)
  if err2 != os.ERROR_NONE {
    fmt.eprintln("join_path for main.lua failed:", err2)
    return
  }

  main_path_c := strings.clone_to_cstring(main_path, context.temp_allocator)

  if lua.L_dofile(Lua, main_path_c) != lua.Status.OK {
    lua_err := lua.tostring(Lua, -1)
    fmt.printf("Lua load error:\n%s\n", lua_err)
    lua.settop(Lua, 0)
    return
  }
  lua.settop(Lua, 0)

  // Explicitly wipe boot-time temporary strings before entering the main systems.
  mem.free_all(context.temp_allocator)

  // ---------------------------------------------------------------------
  // Hardware Subsystems Boot
  // ---------------------------------------------------------------------
  // Open the audio device and initialize mixing groups using the config captured above.
  if !audio_init() {
    fmt.eprintln("Failed to initialize audio subsystem")
    return
  }
  
  input_init()

  // ---------------------------------------------------------------------
  // Client Application Initialization
  // ---------------------------------------------------------------------
  // Hand control to the user's runtime.init() for asset loading and window creation.
  if !call_lua_noargs(cstring("init")) { return }

  // Structural Guard: Ensure the user's script actually initialized a valid graphics context.
  if Window == nil || Renderer == nil {
    fmt.eprintln("runtime.init() did not call window.init(...)")
    return
  }
  
  // Finalize internal graphics state (e.g., base rect textures and default filtering).
  //init_graphics_state()

  // ---------------------------------------------------------------------
  // Timing
  // ---------------------------------------------------------------------
  // Query OS-level clock frequency for high-precision frame timing.
  perf_freq    := f64(sdl.GetPerformanceFrequency())
  last_counter := sdl.GetPerformanceCounter()
  
  // ---------------------------------------------------------------------
  // Event loop
  // ---------------------------------------------------------------------
  event: sdl.Event
  running := true

  for running {
    // Wipe all temporary allocations from the previous frame to maintain zero-leak steady state.
    mem.free_all(context.temp_allocator)

    // Calculate frame delta time (dt) by comparing performance counter ticks.
    now_counter := sdl.GetPerformanceCounter()
    delta_ticks := now_counter - last_counter
    last_counter = now_counter
    dt := f64(delta_ticks) / perf_freq

    // Hard limit on DT: Prevents systemic "teleportation" errors if the OS stalls.
    if dt > 0.1 { dt = 0.1 }
    
    // Begin input frame to swap current/previous key states.
    input_begin_frame()

    // Process OS messages and handle window events.
    for sdl.PollEvent(&event) {
      if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
        Quit_Requested = true
      }
      input_handle_event(&event)
    }

    input_end_frame()
    
    // Perform internal audio voice reclamation.
    audio_update()

    // Execute user logic and draw commands.
    if !call_lua_number(cstring("update"), dt) { break }

    // ---------------------------------------------------------
    // ENGINE AUTO-CLEAR (Anti-Garbage Baseline)
    // ---------------------------------------------------------
    // 1. Set hardware brush to Black
    sdl.SetRenderDrawColor(Renderer, 0, 0, 0, 255)
    
    // 2. Wipe the uninitialized VRAM
    sdl.RenderClear(Renderer)
    
    // 3. Sync your internal state tracker so it knows the brush is currently Black
    Gfx_Ctx.current_sdl_color = u32rgba(0x000000FF)
    // ---------------------------------------------------------

    // Execute user draw commands
    if !call_lua_noargs(cstring("draw")) { break }

    // Flip the backbuffer to the physical display.
    sdl.RenderPresent(Renderer)

    if Quit_Requested { running = false }
  }
  
  // ---------------------------------------------------------------------
  // SUBSYSTEM TEARDOWN STACK (Executes Bottom-to-Top / LIFO)
  // ---------------------------------------------------------------------
  // We declare these here to ensure Lua clears its assets (Sounds/Images)
  // while the Audio and Graphics backends are still valid.
  defer audio_shutdown()
  defer input_shutdown()
  defer window_shutdown()
  defer lua.close(Lua)   
}
