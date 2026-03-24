package main

import "core:fmt"
import "core:strings"
import "core:c"
import "base:runtime"
import "core:math"
import lua "luajit"
import ma "vendor:miniaudio"
import sdl "vendor:sdl3"

// =============================================================================
// Audio Data Structures
// =============================================================================

MAX_TRACKS :: 8
MAX_VOICES :: 64

// Pixels to Meters scaling for 3D spatialization.
// 100 pixels = 1.0 unit (meter) in Miniaudio.
AUDIO_SCALE :: 0.01

// Sound represents a loadable audio asset.
Sound :: struct {
	filepath:  cstring,
	is_stream: bool,
	cache_ref: ma.sound,
}

// Track represents a mixing bus (sound group) for categorized volume control.
Track :: struct {
	group:          ma.sound_group,
}

// Voice represents an active, playing sound node.
Voice :: struct {
	node:   ma.sound,
	active: bool,
	generation:     u32, // <--- Identity tracking
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

	// Tracks 1-7 attach to Track 0 (Master) as sub-buses.
	for i in 1..<8 {
		result = ma.sound_group_init(&audio_ctx.engine, {}, &audio_ctx.tracks[0].group, &audio_ctx.tracks[i].group)
		if result != .SUCCESS {
			fmt.eprintf("Failed to initialize Track %d: %v\n", i, result)
			return false
		}

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
audio_update :: proc() {
	for i in 0..<MAX_VOICES {
		voice := &audio_ctx.voices[i]
		if !voice.active do continue

		if bool(ma.sound_at_end(&voice.node)) {
			ma.sound_uninit(&voice.node)
			voice.active = false
		}
	}
}

// get_voice safely validates a packed handle from Lua and returns the Voice pointer.
// Returns nil if the voice is dead or the handle is stale.
get_voice :: proc(handle: u32) -> ^Voice {
	index := handle & 0xFFFF
	gen   := handle >> 16

	if index >= MAX_VOICES do return nil
	
	voice := &audio_ctx.voices[index]
	if voice.active && voice.generation == gen {
		return voice
	}
	return nil
}

// =============================================================================
// Audio API Procedures
// =============================================================================

// lua_audio_load_sound: audio.load_sound(filepath: string, mode?: string) -> Sound
lua_audio_load_sound :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	c_path := lua.L_checkstring(L, 1)
	mode := "static"
	if lua.gettop(L) >= 2 do mode = string(lua.L_checkstring(L, 2))

	sound := cast(^Sound)lua.newuserdata(L, size_of(Sound))
	sound.filepath = strings.clone_to_cstring(string(c_path))
	sound.is_stream = (mode == "stream")

	flags: ma.sound_flags = {}
	if !sound.is_stream {
		flags += {.DECODE} 
		result := ma.sound_init_from_file(&audio_ctx.engine, sound.filepath, flags, nil, nil, &sound.cache_ref)
		if result != .SUCCESS {
			delete(sound.filepath) 
			lua.L_error(L, cstring("Failed to load static sound: %s"), c_path)
			return 0
		}
	}

	lua.L_getmetatable(L, cstring("Sound_Meta"))
	lua.setmetatable(L, -2)
	return 1 
}

//LISTNER

// lua_audio_set_listener_position: audio.set_listener_position(x: number, y: number)
lua_audio_set_listener_position :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	x := f32(lua.L_checknumber(L, 1))
	y := f32(lua.L_checknumber(L, 2))
	ma.engine_listener_set_position(&audio_ctx.engine, 0, x * AUDIO_SCALE, y * AUDIO_SCALE, 0)
	return 0
}

// lua_audio_set_listener_rotation: audio.set_listener_rotation(degrees: number)
lua_audio_set_listener_rotation :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	deg := f32(lua.L_checknumber(L, 1))
	rad := deg * (math.PI / 180.0)

	// Calculate direction vector on the XY plane
	dx := math.cos(rad)
	dy := math.sin(rad)

	// Listener 0 is the default. We set direction, and keep 'up' as +Z (out of screen).
	ma.engine_listener_set_direction(&audio_ctx.engine, 0, dx, dy, 0)
	return 0
}

// lua_audio_set_listener_velocity: audio.set_listener_velocity(vx: number, vy: number)
lua_audio_set_listener_velocity :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	vx := f32(lua.L_checknumber(L, 2))
	vy := f32(lua.L_checknumber(L, 3))
	
	ma.engine_listener_set_velocity(&audio_ctx.engine, 0, vx * AUDIO_SCALE, vy * AUDIO_SCALE, 0)
	return 0
}

//PLAYBACK

// lua_audio_play: audio.play(sound: Sound, track: int, vol?: num, pitch?: num, pan?: num) -> handle
lua_audio_play :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	// 1. Fetch & Validate Lua Arguments
	sound := cast(^Sound)lua.L_checkudata(L, 1, cstring("Sound_Meta"))
	track_idx := lua.L_checkinteger(L, 2)
	
	if track_idx < 0 || track_idx >= MAX_TRACKS {
		lua.L_error(L, cstring("Invalid track index."))
		return 0
	}

	vol   := f32(lua.L_optnumber(L, 3, 1.0))
	pitch := f32(lua.L_optnumber(L, 4, 1.0))
	pan   := f32(lua.L_optnumber(L, 5, 0.0))

	// 2. Allocate Voice Node
	voice_idx := -1
	for i in 0..<MAX_VOICES {
		if !audio_ctx.voices[i].active {
			voice_idx = i
			break
		}
	}
	if voice_idx == -1 do return 0

	voice := &audio_ctx.voices[voice_idx]
	voice.node = {}        
	voice.generation += 1  

	// 3. Initialize Miniaudio Sound
	flags: ma.sound_flags = {}
	if sound.is_stream do flags += {.STREAM}

	result := ma.sound_init_from_file(&audio_ctx.engine, sound.filepath, flags, &audio_ctx.tracks[track_idx].group, nil, &voice.node)
	if result != .SUCCESS do return 0

	// 4. Mode Setup: 2D Global
	ma.sound_set_spatialization_enabled(&voice.node, false)
	ma.sound_set_pan(&voice.node, pan)

	// 5. Shared Setup & Playback
	ma.sound_set_volume(&voice.node, vol)
	ma.sound_set_pitch(&voice.node, pitch)
	ma.sound_start(&voice.node)

	// 6. Update Engine State & Return Handle
	voice.active = true

	handle := (voice.generation << 16) | u32(voice_idx)
	lua.pushinteger(L, lua.Integer(handle))
	return 1
}

// lua_audio_play_at: audio.play_at(sound: Sound, track: int, x: num, y: num, vol?: num, pitch?: num) -> handle
lua_audio_play_at :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	// 1. Fetch & Validate Lua Arguments
	sound := cast(^Sound)lua.L_checkudata(L, 1, cstring("Sound_Meta"))
	track_idx := lua.L_checkinteger(L, 2)
	
	if track_idx < 0 || track_idx >= MAX_TRACKS {
		lua.L_error(L, cstring("Invalid track index."))
		return 0
	}

	x     := f32(lua.L_checknumber(L, 3))
	y     := f32(lua.L_checknumber(L, 4))
	vol   := f32(lua.L_optnumber(L, 5, 1.0))
	pitch := f32(lua.L_optnumber(L, 6, 1.0))

	// 2. Allocate Voice Node
	voice_idx := -1
	for i in 0..<MAX_VOICES {
		if !audio_ctx.voices[i].active {
			voice_idx = i
			break
		}
	}
	if voice_idx == -1 do return 0

	voice := &audio_ctx.voices[voice_idx]
	voice.node = {}
	voice.generation += 1

	// 3. Initialize Miniaudio Sound
	flags: ma.sound_flags = {}
	if sound.is_stream do flags += {.STREAM}

	result := ma.sound_init_from_file(&audio_ctx.engine, sound.filepath, flags, &audio_ctx.tracks[track_idx].group, nil, &voice.node)
	if result != .SUCCESS do return 0

	// 4. Mode Setup: 3D Spatial
	ma.sound_set_spatialization_enabled(&voice.node, true)
	ma.sound_set_position(&voice.node, x * AUDIO_SCALE, y * AUDIO_SCALE, 0)
	
	// 5. Shared Setup & Playback
	ma.sound_set_volume(&voice.node, vol)
	ma.sound_set_pitch(&voice.node, pitch)
	ma.sound_start(&voice.node)

	// 6. Update Engine State & Return Handle
	voice.active = true

	handle := (voice.generation << 16) | u32(voice_idx)
	lua.pushinteger(L, lua.Integer(handle))
	return 1
}

//VOICE

// lua_audio_set_voice_volume: audio.set_voice_volume(handle: int, volume: number)
lua_audio_set_voice_volume :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	vol := f32(lua.L_checknumber(L, 2))
	ma.sound_set_volume(&voice.node, vol)

	return 0
}

// lua_audio_set_voice_pitch: audio.set_voice_pitch(handle: int, pitch: number)
lua_audio_set_voice_pitch :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	ma.sound_set_pitch(&voice.node, f32(lua.L_checknumber(L, 2)))
	return 0
}

// lua_audio_set_voice_pan: audio.set_voice_pan(handle: int, pan: number)
lua_audio_set_voice_pan :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice == nil do return 0

    pan := f32(lua.L_checknumber(L, 2))
    // Drop back to 2D mode to honor the manual pan
    ma.sound_set_spatialization_enabled(&voice.node, false)
    ma.sound_set_pan(&voice.node, pan)
    return 0
}

// lua_audio_set_voice_position: audio.set_voice_position(handle: int, x: number, y: number)
lua_audio_set_voice_position :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice == nil do return 0

    x := f32(lua.L_checknumber(L, 2))
    y := f32(lua.L_checknumber(L, 3))
    
    // Switch to Spatial mode to honor world-space coordinates
    ma.sound_set_spatialization_enabled(&voice.node, true)
    ma.sound_set_position(&voice.node, x * AUDIO_SCALE, y * AUDIO_SCALE, 0)
    return 0
}

// lua_audio_set_voice_looping: audio.set_voice_looping(handle: int, loop: bool)
lua_audio_set_voice_looping :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	ma.sound_set_looping(&voice.node, b32(lua.toboolean(L, 2)))
	return 0
}

// lua_audio_fade_voice: audio.fade_voice(handle: int, target: number, duration: number)
lua_audio_fade_voice :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	target := f32(lua.L_checknumber(L, 2))
	duration_seconds := f32(lua.L_checknumber(L, 3))
	
	// Miniaudio expects milliseconds for fades
	duration_ms := u64(duration_seconds * 1000.0)
	
	// Grab exact volume at this microsecond
	current_vol := ma.sound_get_current_fade_volume(&voice.node) 
	
	ma.sound_set_fade_in_milliseconds(&voice.node, current_vol, target, duration_ms)
	return 0
}

// lua_audio_pause_voice: audio.pause_voice(handle: int)
lua_audio_pause_voice  :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice != nil do ma.sound_stop(&voice.node)
	return 0
}

// lua_audio_resume_voice: audio.resume_voice(handle: int)
lua_audio_resume_voice :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice != nil do ma.sound_start(&voice.node)
	return 0
}

// lua_audio_stop_voice: audio.stop_voice(handle: int)
lua_audio_stop_voice   :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice != nil {
		ma.sound_uninit(&voice.node)
		voice.active = false
	}
	return 0
}

//Voice Distance & Physics

// lua_audio_set_voice_min_distance: audio.set_voice_min_distance(handle: int, pixels: number)
lua_audio_set_voice_min_distance :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	pixels := f32(lua.L_checknumber(L, 2))
	ma.sound_set_min_distance(&voice.node, pixels * AUDIO_SCALE)
	return 0
}

// lua_audio_set_voice_max_distance: audio.set_voice_max_distance(handle: int, pixels: number)
lua_audio_set_voice_max_distance :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	pixels := f32(lua.L_checknumber(L, 2))
	ma.sound_set_max_distance(&voice.node, pixels * AUDIO_SCALE)
	return 0
}

// lua_audio_set_voice_rolloff: audio.set_voice_rolloff(handle: int, factor: number)
lua_audio_set_voice_rolloff :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	factor := f32(lua.L_checknumber(L, 2))
	ma.sound_set_rolloff(&voice.node, factor)
	return 0
}

// lua_audio_set_voice_velocity: audio.set_voice_velocity(handle: int, vx: number, vy: number)
lua_audio_set_voice_velocity :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	vx := f32(lua.L_checknumber(L, 2))
	vy := f32(lua.L_checknumber(L, 3))
	ma.sound_set_velocity(&voice.node, vx * AUDIO_SCALE, vy * AUDIO_SCALE, 0)
	return 0
}

// lua_audio_set_voice_distance_curve: audio.set_voice_distance_curve(handle: int, mode: string)
// Modes: "none", "inverse" (Default), "linear", "exponential"
lua_audio_set_voice_distance_curve :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	mode_str := string(lua.L_checkstring(L, 2))
	model := ma.attenuation_model.none

	switch mode_str {
	case "none":        model = .none
	case "inverse":     model = .inverse
	case "linear":      model = .linear
	case "exponential": model = .exponential
	case:
		lua.L_error(L, cstring("Invalid distance curve. Use 'none', 'inverse', 'linear', or 'exponential'."))
		return 0
	}

	ma.sound_set_attenuation_model(&voice.node, model)
	return 0
}

// lua_audio_set_voice_pan_mode: audio.set_voice_pan_mode(handle: int, mode: string)
// Modes: "balance" (Default), "pan"
lua_audio_set_voice_pan_mode :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	mode_str := string(lua.L_checkstring(L, 2))
	mode := ma.pan_mode.balance

	switch mode_str {
	case "balance": mode = .balance
	case "pan":     mode = .pan
	case:
		lua.L_error(L, cstring("Invalid pan mode. Use 'balance' or 'pan'."))
		return 0
	}

	ma.sound_set_pan_mode(&voice.node, mode)
	return 0
}

//track/mixer

// lua_audio_set_track_volume: audio.set_track_volume(track: int, volume: number)
lua_audio_set_track_volume :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	idx := lua.L_checkinteger(L, 1)
	if idx < 0 || idx >= MAX_TRACKS do return 0

	vol := f32(lua.L_checknumber(L, 2))
	ma.sound_group_set_volume(&audio_ctx.tracks[idx].group, vol)

	return 0
}

// lua_audio_fade_track: audio.fade_track(track: int, target: number, duration: number)
lua_audio_fade_track :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	idx := lua.L_checkinteger(L, 1)
	if idx < 0 || idx >= MAX_TRACKS do return 0

	target := f32(lua.L_checknumber(L, 2))
	duration_seconds := f32(lua.L_checknumber(L, 3))
	duration_ms := u64(duration_seconds * 1000.0)

	current_vol := ma.sound_group_get_current_fade_volume(&audio_ctx.tracks[idx].group)
	ma.sound_group_set_fade_in_milliseconds(&audio_ctx.tracks[idx].group, current_vol, target, duration_ms)
	return 0
}

// lua_audio_set_track_pitch: audio.set_track_pitch(track: int, pitch: number)
lua_audio_set_track_pitch :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	idx := lua.L_checkinteger(L, 1)
	if idx < 0 || idx >= MAX_TRACKS do return 0
	ma.sound_group_set_pitch(&audio_ctx.tracks[idx].group, f32(lua.L_checknumber(L, 2)))
	return 0
}

// lua_audio_set_track_pan: audio.set_track_pan(track: int, pan: number)
lua_audio_set_track_pan :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	idx := lua.L_checkinteger(L, 1)
	if idx < 0 || idx >= MAX_TRACKS do return 0
	ma.sound_group_set_pan(&audio_ctx.tracks[idx].group, f32(lua.L_checknumber(L, 2)))
	return 0
}

// lua_audio_pause_track: audio.pause_track(track_idx: int)
lua_audio_pause_track :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_TRACKS do return 0
    ma.sound_group_stop(&audio_ctx.tracks[idx].group)
    return 0
}

// lua_audio_resume_track: audio.resume_track(track_idx: int)
lua_audio_resume_track :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_TRACKS do return 0
    ma.sound_group_start(&audio_ctx.tracks[idx].group)
    return 0
}

// lua_audio_stop_track: audio.stop_track(track_idx: int)
lua_audio_stop_track :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_TRACKS do return 0
    // Stop group immediately. Individual voices in this group will be 
    // reclaimed by audio_update() on the next frame as they hit their end.
    ma.sound_group_stop(&audio_ctx.tracks[idx].group)
    return 0
}

// =============================================================================
// Memory Management & Metatables
// =============================================================================

// lua_sound_gc is triggered by Lua's GC or manual release().
// It unpins the RAM cache and frees the cloned filepath string.
lua_sound_gc :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	sound := cast(^Sound)lua.L_checkudata(L, 1, cstring("Sound_Meta"))

	if sound != nil && sound.filepath != nil {
		// 1. Unpin RAM cache if static
		if !sound.is_stream {
			ma.sound_uninit(&sound.cache_ref)
		}

		// 2. Free the heap-allocated cstring
		delete(sound.filepath)
		sound.filepath = nil 
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
// Engine Registration
// =============================================================================

// register_audio_api exposes the full audio module to the Lua environment.
register_audio_api :: proc(L: ^lua.State) {
	setup_audio_metatables(L)

	lua.newtable(L)

	// Assets
	lua.pushcfunction(L, lua_audio_load_sound)
	lua.setfield(L, -2, cstring("load_sound"))

	// Listener Mutators
	lua.pushcfunction(L, lua_audio_set_listener_position)
	lua.setfield(L, -2, cstring("set_listener_position"))
	lua.pushcfunction(L, lua_audio_set_listener_rotation)
	lua.setfield(L, -2, cstring("set_listener_rotation"))
	lua.pushcfunction(L, lua_audio_set_listener_velocity)
	lua.setfield(L, -2, cstring("set_listener_velocity"))

	// Playback
	lua.pushcfunction(L, lua_audio_play)
	lua.setfield(L, -2, cstring("play"))
	lua.pushcfunction(L, lua_audio_play_at)
	lua.setfield(L, -2, cstring("play_at"))

	// Voice Mutation
	lua.pushcfunction(L, lua_audio_set_voice_volume)
	lua.setfield(L, -2, cstring("set_voice_volume"))
	lua.pushcfunction(L, lua_audio_set_voice_pitch)
	lua.setfield(L, -2, cstring("set_voice_pitch"))
	lua.pushcfunction(L, lua_audio_set_voice_pan)
	lua.setfield(L, -2, cstring("set_voice_pan"))
	lua.pushcfunction(L, lua_audio_set_voice_position)
	lua.setfield(L, -2, cstring("set_voice_position"))
	lua.pushcfunction(L, lua_audio_set_voice_looping)
	lua.setfield(L, -2, cstring("set_voice_looping"))
	lua.pushcfunction(L, lua_audio_fade_voice)
	lua.setfield(L, -2, cstring("fade_voice"))

	// Voice Lifecycle
	lua.pushcfunction(L, lua_audio_pause_voice)
	lua.setfield(L, -2, cstring("pause_voice"))
	lua.pushcfunction(L, lua_audio_resume_voice)
	lua.setfield(L, -2, cstring("resume_voice"))
	lua.pushcfunction(L, lua_audio_stop_voice)
	lua.setfield(L, -2, cstring("stop_voice"))
	
	// Spatial Voice Mutators
	lua.pushcfunction(L, lua_audio_set_voice_min_distance)
	lua.setfield(L, -2, cstring("set_voice_min_distance"))
	lua.pushcfunction(L, lua_audio_set_voice_max_distance)
	lua.setfield(L, -2, cstring("set_voice_max_distance"))
	lua.pushcfunction(L, lua_audio_set_voice_rolloff)
	lua.setfield(L, -2, cstring("set_voice_rolloff"))
	lua.pushcfunction(L, lua_audio_set_voice_velocity)
	lua.setfield(L, -2, cstring("set_voice_velocity"))
	lua.pushcfunction(L, lua_audio_set_voice_distance_curve)
	lua.setfield(L, -2, cstring("set_voice_distance_curve"))
	lua.pushcfunction(L, lua_audio_set_voice_pan_mode)
  lua.setfield(L, -2, cstring("set_voice_pan_mode"))

	// Track Control
	lua.pushcfunction(L, lua_audio_set_track_volume)
	lua.setfield(L, -2, cstring("set_track_volume"))
	lua.pushcfunction(L, lua_audio_set_track_pitch)
	lua.setfield(L, -2, cstring("set_track_pitch"))
	lua.pushcfunction(L, lua_audio_set_track_pan)
	lua.setfield(L, -2, cstring("set_track_pan"))
	lua.pushcfunction(L, lua_audio_pause_track)
  lua.setfield(L, -2, cstring("pause_track"))
  lua.pushcfunction(L, lua_audio_resume_track)
  lua.setfield(L, -2, cstring("resume_track"))
  lua.pushcfunction(L, lua_audio_stop_track)
  lua.setfield(L, -2, cstring("stop_track"))
	lua.pushcfunction(L, lua_audio_fade_track)
	lua.setfield(L, -2, cstring("fade_track"))
	


	lua.setglobal(L, cstring("audio"))
}
