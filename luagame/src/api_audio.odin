package main

import "core:fmt"
import "core:strings"
import "core:c"
import "base:runtime"
import lua "luajit"
import ma "vendor:miniaudio"
import sdl "vendor:sdl3"

// =============================================================================
// Audio Data Structures
// =============================================================================

MAX_TRACKS :: 8
MAX_VOICES :: 64

// Sound represents a loadable audio asset.
Sound :: struct {
	filepath:  string,
	is_stream: bool,
	cache_ref: ma.sound,
}

// Track represents a mixing bus (sound group) for categorized volume control.
Track :: struct {
	group:          ma.sound_group,
	current_volume: f32,
	target_volume:  f32,
	fade_speed:     f32,
}

// Voice represents an active, playing sound node.
Voice :: struct {
	node:   ma.sound,
	active: bool,
}

// =============================================================================
// Global Audio Context
// =============================================================================

// audio_ctx is the singleton holding the engine, mixing buses, and voice pool.
audio_ctx: struct {
	engine: ma.engine,
	tracks: [MAX_TRACKS]Track,
	voices: [MAX_VOICES]Voice,
}

// =============================================================================
// Audio Core Procedures
// =============================================================================

// audio_init initializes the miniaudio engine, master/sub tracks, and voice pool.
// Returns true if initialization succeeds, false otherwise.
audio_init :: proc() -> bool {
	// 1. Initialize the core Miniaudio engine
	config := ma.engine_config_init()
	
	result := ma.engine_init(&config, &audio_ctx.engine)
	if result != .SUCCESS {
		fmt.eprintf("Failed to initialize audio engine: %v\n", result)
		return false
	}

	// 2. Initialize the Tracks (Mixing Buses)
	// Track 0 is the Master Track. It attaches directly to the engine output.
	result = ma.sound_group_init(&audio_ctx.engine, {}, nil, &audio_ctx.tracks[0].group)
	if result != .SUCCESS {
		fmt.eprintf("Failed to initialize Master Track: %v\n", result)
		return false
	}
	audio_ctx.tracks[0].current_volume = 1.0
	audio_ctx.tracks[0].target_volume = 1.0

	// Tracks 1-7 attach to Track 0 (Master) as sub-buses.
	for i in 1..<8 {
		result = ma.sound_group_init(&audio_ctx.engine, {}, &audio_ctx.tracks[0].group, &audio_ctx.tracks[i].group)
		if result != .SUCCESS {
			fmt.eprintf("Failed to initialize Track %d: %v\n", i, result)
			return false
		}
		audio_ctx.tracks[i].current_volume = 1.0
		audio_ctx.tracks[i].target_volume = 1.0
	}

	// 3. Set Voice pool to inactive
	// ma.sound nodes are initialized on-the-fly inside playback procs.
	for i in 0..<MAX_VOICES {
		audio_ctx.voices[i].active = false
	}

	return true
}

// audio_shutdown uninitializes all active voices, tracks, and the miniaudio engine.
// Must be called on application shutdown.
audio_shutdown :: proc() {
	// 1. Halt and destroy all active voices.
	// This gracefully drops the Master track's input to pure silence.
	for i in 0..<MAX_VOICES {
		if audio_ctx.voices[i].active {
			ma.sound_stop(&audio_ctx.voices[i].node) 
			ma.sound_uninit(&audio_ctx.voices[i].node)
		}
	}

	// 2. The Hardware Flush.
	// The core engine is still ticking. We sleep the main thread for 50ms to allow 
	// the now-silent Master track to overwrite WASAPI's hardware ring buffer.
	sdl.Delay(50)

	// 3. Teardown tracks in reverse order of creation (children before master).
	for i := MAX_TRACKS - 1; i >= 0; i -= 1 {
		ma.sound_group_uninit(&audio_ctx.tracks[i].group)
	}

	// 4. Kill the core engine.
	ma.engine_uninit(&audio_ctx.engine)
}

// audio_update polls the voice pool and reclaims slots that have finished playing.
// This must be called once per frame in the main engine loop.
audio_update :: proc() {
	for i in 0..<MAX_VOICES {
		if audio_ctx.voices[i].active {
			// Cast the ma_bool32 to an Odin boolean
			if bool(ma.sound_at_end(&audio_ctx.voices[i].node)) {
				ma.sound_uninit(&audio_ctx.voices[i].node)
				audio_ctx.voices[i].active = false
			}
		}
	}
}

// =============================================================================
// Memory Management & Metatables
// =============================================================================

// lua_sound_gc is triggered by Lua's GC or manual release().
// It unpins the RAM cache and frees the cloned filepath string.
lua_sound_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	// 1. Retrieve the userdata, strictly enforcing the metatable type
	sound := cast(^Sound)lua.L_checkudata(L, 1, cstring("Sound_Meta"))

	// 2. Double-Free Guard: We use the filepath string as our flag. 
	// If it has length, we haven't destroyed this object yet.
	if sound != nil && len(sound.filepath) > 0 {
		
		// 3. Unpin RAM: Only call uninit if this was a static file.
		// Streamed files don't use the cache_ref.
		if !sound.is_stream {
			ma.sound_uninit(&sound.cache_ref)
		}

		// 4. Free the Odin-owned string to prevent a memory leak
		delete(sound.filepath)
		
		// 5. Mark as dead so manual release() doesn't double-free
		sound.filepath = "" 
	}

	return 0
}

// setup_audio_metatables initializes the hidden registry tables for audio userdata.
setup_audio_metatables :: proc(L: ^lua.State) {
	lua.L_newmetatable(L, cstring("Sound_Meta"))
	lua.pushcfunction(L, lua_sound_gc)
	lua.setfield(L, -2, cstring("__gc"))
	lua.pop(L, 1)
}

// =============================================================================
// Audio API Procedures
// =============================================================================

// lua_audio_load_sound implements: audio.load_sound(filepath: string, mode?: string) -> Sound
lua_audio_load_sound :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	// 1. Argument Parsing
	c_filepath := lua.L_checkstring(L, 1)
	mode := "static"
	if lua.gettop(L) >= 2 {
		mode = string(lua.L_checkstring(L, 2))
	}

	// 2. Allocation
	sound := cast(^Sound)lua.newuserdata(L, size_of(Sound))
	
	// 3. String Ownership
	// lua.L_checkstring returns memory owned by Lua. If we don't clone it, 
	// Lua's GC will eventually delete the string and corrupt our `filepath`.
	sound.filepath = strings.clone_from_cstring(c_filepath)
	sound.is_stream = (mode == "stream")

	// 4. Bit-Set Flags
	// Odin enforces strict bit_sets instead of C-style bitwise ORs on integers.
	flags: ma.sound_flags = {}
	if !sound.is_stream {
		flags += {.DECODE} // Forces full PCM decode to RAM
	} else {
		flags += {.STREAM} // Prepares for disk streaming
	}

	// 5. The Cache Pin
	if !sound.is_stream {
		result := ma.sound_init_from_file(&audio_ctx.engine, c_filepath, flags, nil, nil, &sound.cache_ref)
		if result != .SUCCESS {
			// Memory Safety: Free the string before aborting via Lua error
			delete(sound.filepath) 
			sound.filepath = ""
			lua.L_error(L, cstring("Failed to load static sound: %s"), c_filepath)
			return 0
		}
	} else {
		// Explicitly zero the struct if we are streaming, just to be safe.
		sound.cache_ref = {}
	}

	// 6. Bind the GC Metatable
	lua.L_getmetatable(L, cstring("Sound_Meta"))
	lua.setmetatable(L, -2)

	return 1 // Return the userdata to Lua
}

// lua_audio_play implements: audio.play(sound: Sound, track: int, vol?: num, pitch?: num, pan?: num) -> int
// Spawns a non-spatial voice from the pool and routes it to the specified track.
lua_audio_play :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	// 1. Argument Parsing & Defaults
	sound := cast(^Sound)lua.L_checkudata(L, 1, cstring("Sound_Meta"))
	track_idx := lua.L_checkinteger(L, 2)
	
  if track_idx < 1 || track_idx > 7 {
		lua.L_error(L, cstring("Invalid track index. Must be 1-7. (Track 0 is Master bus)"))
		return 0
	}

	vol   := lua.L_optnumber(L, 3, 1.0)
	pitch := lua.L_optnumber(L, 4, 1.0)
	pan   := lua.L_optnumber(L, 5, 0.0)

	// 2. Query the Voice Pool
	voice_idx := -1
	for i in 0..<MAX_VOICES {
		if !audio_ctx.voices[i].active {
			voice_idx = i
			break
		}
	}

	// If the pool is full (32 overlapping sounds), we safely drop the playback request
	if voice_idx == -1 {
		return 0 
	}

	voice := &audio_ctx.voices[voice_idx]
	voice.node = {} 

	// 3. Configure Resource Flags
	flags: ma.sound_flags = {}
	if sound.is_stream {
		flags += {.STREAM}
	}

	// 4. Temporarily clone the Odin string to a C-string for Miniaudio
	c_path := strings.clone_to_cstring(sound.filepath)
	defer delete(c_path)

	// Note: Because we pass the exact same c_path that we used in load_sound, 
	// Miniaudio's internal ResourceManager sees it and instantly points this new
	// voice node to the already-decoded RAM cache. Zero disk I/O happens here.
	result := ma.sound_init_from_file(
		&audio_ctx.engine, 
		c_path, 
		flags, 
		&audio_ctx.tracks[track_idx].group, 
		nil, 
		&voice.node,
	)

	if result != .SUCCESS {
		fmt.eprintf("Failed to play sound: %v\n", result)
		return 0
	}

	// 5. Apply Initial State (Frame 0 Configuration)
	ma.sound_set_volume(&voice.node, f32(vol))
	ma.sound_set_pitch(&voice.node, f32(pitch))
	ma.sound_set_pan(&voice.node, f32(pan))
	ma.sound_set_spatialization_enabled(&voice.node, false) // Explicitly global/2D

	// 6. Fire & Mark Active
	ma.sound_start(&voice.node)
	voice.active = true

	// 7. Return the Voice ID (The pool index)
	lua.pushinteger(L, lua.Integer(voice_idx))
	return 1
}

// =============================================================================
// Engine Registration
// =============================================================================

// register_audio_api exposes the audio module to the Lua environment.
register_audio_api :: proc(L: ^lua.State) {
	// 1. Create the hidden metatables for memory management
	setup_audio_metatables(L)

	// 2. Create the global `audio` table
	lua.newtable(L)

	// 3. Bind functions
	lua.pushcfunction(L, lua_audio_load_sound)
	lua.setfield(L, -2, cstring("load_sound"))
	
	lua.pushcfunction(L, lua_audio_play)
	lua.setfield(L, -2, cstring("play"))

	// 4. Register the table globally
	lua.setglobal(L, cstring("audio"))
}
