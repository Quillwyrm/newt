package main

import "base:runtime"
import "core:mem"	
import "core:fmt"
import "core:strings"
import "core:c"
import os  "core:os/os2"
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

// lua_engine_global_release implements: release(userdata)
// This is the universal garbage disposal verb. It looks up the __gc metamethod
// of any userdata passed to it and executes it immediately, freeing backend resources.
lua_engine_global_release :: proc "c" (L: ^lua.State) -> c.int {
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

// register_engine_global_api registers top-level engine builtins like `release`.
// These are injected directly into the global namespace, side-by-side with `print`.
register_engine_global_api :: proc(L: ^lua.State) {
	lua.pushcfunction(L, lua_engine_global_release)
	lua.setglobal(L, cstring("release"))
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

  if !sdl.Init({.VIDEO}) {
    fmt.eprintln("SDL_Init failed:", sdl.GetError())
    return
  }
  defer sdl.Quit()
  
  // ---------------------------------------------------------------------
  // Audio
  // ---------------------------------------------------------------------
  if !audio_init() {
    fmt.eprintln("Failed to initialize audio subsystem")
    return
  }
  defer audio_shutdown()

  // ---------------------------------------------------------------------
  // Lua: load main.lua and run runtime.init()
  // ---------------------------------------------------------------------
  Lua = lua.L_newstate()
  if Lua == nil {
    fmt.eprintln("Lua L_newstate failed")
    return
  }
  defer lua.close(Lua)

  lua.L_openlibs(Lua)
  register_lua_api()

  exe_dir, err := os.get_executable_directory(context.temp_allocator)
  if err != os.ERROR_NONE {
    fmt.eprintln("get_executable_directory failed:", err)
    return
  }
  
  prepend_package_path(Lua, exe_dir)

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

  // Handled by free_all in loop start, but kept for clarity here
  mem.free_all(context.temp_allocator)

  if !call_lua_noargs(cstring("init")) { return }

  // runtime.init() must call window.init(...)
  if Window == nil || Renderer == nil {
    fmt.eprintln("runtime.init() did not call window.init(...)")
    return
  }
  
  //setup base texture for rect draws + other gfx_ctx bookeeping
  init_graphics_state()


  // Window/module owns window teardown. Host calls once.
  defer window_shutdown()
  
  // ---------------------------------------------------------------------
  // Input
  // ---------------------------------------------------------------------
  input_init()
  defer input_shutdown()

  // ---------------------------------------------------------------------
  // Timing
  // ---------------------------------------------------------------------
  perf_freq    := f64(sdl.GetPerformanceFrequency())
  last_counter := sdl.GetPerformanceCounter()
  

  // ---------------------------------------------------------------------
  // Event loop
  // ---------------------------------------------------------------------
  event: sdl.Event
  running := true

  for running {
    // Consolidated temp cleanup
    mem.free_all(context.temp_allocator)

    now_counter := sdl.GetPerformanceCounter()
    delta_ticks := now_counter - last_counter
    last_counter = now_counter
    dt := f64(delta_ticks) / perf_freq

    // Safety clamp: prevents OS spikes from breaking game math
    if dt > 0.1 { dt = 0.1 }
    
    input_begin_frame()

    for sdl.PollEvent(&event) {
      if event.type == .QUIT || event.type == .WINDOW_CLOSE_REQUESTED {
        Quit_Requested = true
      }
      input_handle_event(&event)
    }

    input_end_frame()
    
    audio_update()

    if !call_lua_number(cstring("update"), dt) { break }
    if !call_lua_noargs(cstring("draw")) { break }

    sdl.RenderPresent(Renderer)

    if Quit_Requested { running = false }
  }
}

