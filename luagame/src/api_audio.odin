package main

import "core:fmt"
import "core:strings"
import "core:c"
import "base:runtime"
import "core:math"
import lua "luajit"
import ma "vendor:miniaudio"
import sdl "vendor:sdl3"

//TODO: look into reverb/distortion. figure out if 'stop' is a bad word. GROUP/BUS/TRACK what to call them?

// # Audio API - audio.function()
//
// ### Engine Configuration (Call BEFORE Engine Init)
// - `.config_track_delay_times(table)` — e.g., { [1] = 0.5, [4] = 2.0 }
//
// ### Global Listener & Defaults
// - `.set_listener_position(x, y)`
// - `.set_listener_rotation(degrees)`
// - `.set_listener_velocity(vx, vy)`
// - `.set_default_falloff(min_px, max_px?)`
// - `.set_default_falloff_mode(mode)` — modes: "none", "inverse", "linear", "exponential"
//
// ### Asset Management
// - `.load_sound(filepath, mode?)` — returns a `Sound` object
// - `.get_sound_info(sound)` — returns `duration`, `path`, `mode`
//
// ### Playback Entry Points
// - `.play(sound, track_id, volume?, pitch?, pan?)` — returns an integer `handle`
// - `.play_at(sound, track_id, x, y, volume?, pitch?)` — returns an integer `handle`
//
// ### Instance Control (Common)
// - `.set_voice_volume(handle, volume)`
// - `.set_voice_pitch(handle, pitch)`
// - `.set_voice_pan(handle, pan)`
// - `.set_voice_looping(handle, is_looping)`
// - `.seek_voice(handle, offset, unit?)` — units: "seconds" (default), "samples"
// - `.fade_voice(handle, target_volume, duration)`
// - `.get_voice_info(handle)` — returns `time_in_seconds`, `duration_in_seconds`
// - `.is_voice_playing(handle)` — returns `bool`
//
// ### Instance Control (Spatial)
// - `.set_voice_position(handle, x, y)`
// - `.set_voice_velocity(handle, vx, vy)`
// - `.set_voice_falloff(handle, min_px, max_px?)`
// - `.set_voice_rolloff(handle, factor)`
// - `.set_voice_falloff_mode(handle, mode)`
// - `.set_voice_pan_mode(handle, mode)` — modes: "balance", "pan"
//
// ### Instance Lifecycle
// - `.pause_voice(handle)`
// - `.resume_voice(handle)`
// - `.stop_voice(handle)` — halts and reclaims the voice slot
//
// ### Track Mixing
// - `.set_track_volume(track_id, volume)`
// - `.set_track_pitch(track_id, pitch)`
// - `.set_track_pan(track_id, pan)`
// - `.fade_track(track_id, target_volume, duration)`
// - `.set_track_lpf(track_id, hz)`
// - `.set_track_hpf(track_id, hz)`
// - `.set_track_delay_mix(track_id, wet, dry?)`
// - `.set_track_delay_feedback(track_id, amount)`
// - `.pause_track(track_id)`
// - `.resume_track(track_id)`
// - `.stop_track(track_id)` — halts track and destroys all active voices on it
// - `.stop_all_voices()`

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
	group: ma.sound_group,
	lpf:   ma.lpf_node, // <--- Persistent memory for the LPF
	hpf:   ma.hpf_node, // <--- Persistent memory for the HPF
	delay: ma.delay_node, // <--- Added delay node
}

// Voice represents an active, playing sound node.
Voice :: struct {
	node:   ma.sound,
	active: bool,
	generation:     u32, // <--- Identity tracking
	track_idx: int,
}

// =============================================================================
// Global Audio Context
// =============================================================================

// Global Audio Context
audio_ctx: struct {
	engine: ma.engine,
	tracks: [MAX_TRACKS]Track,
	voices: [MAX_VOICES]Voice,
	
	//default state
	default_min_dist: f32, 
	default_max_dist: f32,
	default_attenuation_model: ma.attenuation_model,
	
	// Config state populated by Lua before audio_init() runs
	track_delay_times: [MAX_TRACKS]f32,
}

// =============================================================================
// Audio Core Procedures
// =============================================================================

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
  channels    := ma.engine_get_channels(&audio_ctx.engine)
  sample_rate := ma.engine_get_sample_rate(&audio_ctx.engine)
  graph       := ma.engine_get_node_graph(&audio_ctx.engine)
  endpoint    := ma.engine_get_endpoint(&audio_ctx.engine)

  // Tracks 0-7 all get DSP filters.
  for i in 0..<MAX_TRACKS {
    // Init Group (Starts unattached so we can manually wire the chain)
    result = ma.sound_group_init(&audio_ctx.engine, {}, nil, &audio_ctx.tracks[i].group)
    if result != .SUCCESS {
      fmt.eprintf("Failed to initialize Track %d Group: %v\n", i, result)
      return false
    }

    // Init Delay (Reads from Lua config, fallback to 250ms)
    delay_sec := audio_ctx.track_delay_times[i]
    if delay_sec <= 0.0 do delay_sec = 0.25 
    delay_frames := u32(delay_sec * f32(sample_rate))
    delay_cfg := ma.delay_node_config_init(channels, sample_rate, delay_frames, 0.0)
    result = ma.delay_node_init(graph, &delay_cfg, nil, &audio_ctx.tracks[i].delay)
    if result != .SUCCESS {
      fmt.eprintf("Failed to initialize Track %d Delay: %v\n", i, result)
      return false
    }

    // Init HPF (Starts at 10Hz to prevent NaN singularity)
    hpf_cfg := ma.hpf_node_config_init(channels, sample_rate, 10.0, 2)
    result = ma.hpf_node_init(graph, &hpf_cfg, nil, &audio_ctx.tracks[i].hpf)
    if result != .SUCCESS {
      fmt.eprintf("Failed to initialize Track %d HPF: %v\n", i, result)
      return false
    }

    // Init LPF (Starts fully open at 20000Hz)
    lpf_cfg := ma.lpf_node_config_init(channels, sample_rate, 20000.0, 2)
    result = ma.lpf_node_init(graph, &lpf_cfg, nil, &audio_ctx.tracks[i].lpf)
    if result != .SUCCESS {
      fmt.eprintf("Failed to initialize Track %d LPF: %v\n", i, result)
      return false
    }

    // Daisy Chain Wiring: Group -> Delay -> HPF -> LPF
    base_group  := cast(^ma.node)&audio_ctx.tracks[i].group
    base_delay  := cast(^ma.node)&audio_ctx.tracks[i].delay
    base_hpf    := cast(^ma.node)&audio_ctx.tracks[i].hpf
    base_lpf    := cast(^ma.node)&audio_ctx.tracks[i].lpf

    ma.node_attach_output_bus(base_group, 0, base_delay, 0)
    ma.node_attach_output_bus(base_delay, 0, base_hpf,   0)
    ma.node_attach_output_bus(base_hpf,   0, base_lpf,   0)

    if i == 0 {
      // Track 0 is the Master Track. It attaches directly to the engine output.
      ma.node_attach_output_bus(base_lpf, 0, endpoint, 0)
    } else {
      // Tracks 1-7 attach to Track 0 (Master) as sub-buses via DSP filters.
      base_master := cast(^ma.node)&audio_ctx.tracks[0].group
      ma.node_attach_output_bus(base_lpf, 0, base_master, 0)
    }
  }

  // 3. Set Voice pool to inactive
  for i in 0..<MAX_VOICES {
    audio_ctx.voices[i].active = false
  }

  // Default to 100px Inner Sphere, 10,000px Max (Infinite for 2D)
  audio_ctx.default_min_dist = 100.0 * AUDIO_SCALE
  audio_ctx.default_max_dist = 10000.0 * AUDIO_SCALE
  audio_ctx.default_attenuation_model = .inverse 

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

	// 3. Teardown tracks in reverse order
	for i := MAX_TRACKS - 1; i >= 0; i -= 1 {
    ma.lpf_node_uninit(&audio_ctx.tracks[i].lpf, nil)
    ma.hpf_node_uninit(&audio_ctx.tracks[i].hpf, nil)
    ma.delay_node_uninit(&audio_ctx.tracks[i].delay, nil)
    ma.sound_group_uninit(&audio_ctx.tracks[i].group)
  }
	ma.sound_group_uninit(&audio_ctx.tracks[0].group)
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
	ma.engine_listener_set_position(&audio_ctx.engine, 0, x * AUDIO_SCALE, y * AUDIO_SCALE, -1)
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
	// Change these indices from 2/3 to 1/2
	vx := f32(lua.L_checknumber(L, 1)) 
	vy := f32(lua.L_checknumber(L, 2))
	
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
  // Mask to 16 bits so it safely wraps from 65535 back to 0
	voice.generation = (voice.generation + 1) & 0xFFFF 
	voice.track_idx = int(track_idx)

	// ---------------------------------------------------------------------
  // 3. Initialize Miniaudio Sound
  // ---------------------------------------------------------------------
  result: ma.result
  flags: ma.sound_flags = {}
  if sound.is_stream do flags += {.STREAM}

  if sound.is_stream {
    // Streams need a new file handle/unique read head
    result = ma.sound_init_from_file(&audio_ctx.engine, sound.filepath, flags, &audio_ctx.tracks[track_idx].group, nil, &voice.node)
  } else {
    // Static sounds just "clone" the existing RAM buffer (Instant/No String Hashing)
    result = ma.sound_init_copy(&audio_ctx.engine, &sound.cache_ref, flags, &audio_ctx.tracks[track_idx].group, &voice.node)
  }

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
  // Mask to 16 bits so it safely wraps from 65535 back to 0
	voice.generation = (voice.generation + 1) & 0xFFFF 
	voice.track_idx = int(track_idx)

	// ---------------------------------------------------------------------
  // 3. Initialize Miniaudio Sound
  // ---------------------------------------------------------------------
  result: ma.result
  flags: ma.sound_flags = {}
  if sound.is_stream do flags += {.STREAM}

  if sound.is_stream {
    // Streams need a new file handle/unique read head
    result = ma.sound_init_from_file(&audio_ctx.engine, sound.filepath, flags, &audio_ctx.tracks[track_idx].group, nil, &voice.node)
  } else {
    // Static sounds just "clone" the existing RAM buffer (Instant/No String Hashing)
    result = ma.sound_init_copy(&audio_ctx.engine, &sound.cache_ref, flags, &audio_ctx.tracks[track_idx].group, &voice.node)
  }

  if result != .SUCCESS do return 0

  // 4. Mode Setup: 3D Spatial
	ma.sound_set_spatialization_enabled(&voice.node, true)
	ma.sound_set_position(&voice.node, x * AUDIO_SCALE, y * AUDIO_SCALE, 0)
	
  // Apply engine defaults automatically
	ma.sound_set_min_distance(&voice.node, audio_ctx.default_min_dist)
	ma.sound_set_max_distance(&voice.node, audio_ctx.default_max_dist)
	ma.sound_set_attenuation_model(&voice.node, audio_ctx.default_attenuation_model) 

	
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

// lua_audio_seek_voice: audio.seek_voice(handle: int, offset: number, unit?: string)
// units: "seconds" (default), "samples"
lua_audio_seek_voice :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	offset := f64(lua.L_checknumber(L, 2))
	if offset < 0.0 do offset = 0.0

	// Default to seconds if no unit is provided
	unit := "seconds"
	if lua.gettop(L) >= 3 {
		unit = string(lua.L_checkstring(L, 3))
	}

	target_frame: u64

	if unit == "samples" {
		// Bypass math, treat the offset as an exact integer frame
		target_frame = u64(offset)
	} else {
		// Handle standard seconds
		format: ma.format
		channels: u32
		sample_rate: u32
		
		ma.sound_get_data_format(&voice.node, &format, &channels, &sample_rate, nil, 0)
		target_frame = u64(offset * f64(sample_rate))
	}

	ma.sound_seek_to_pcm_frame(&voice.node, target_frame)
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
lua_audio_stop_voice :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	
	if voice != nil {
		ma.sound_stop(&voice.node)   // 1. Thread-safe halt
		ma.sound_uninit(&voice.node) // 2. Safe memory destruction
		voice.active = false         // 3. Reclaim pool slot
	}
	
	return 0
}

//Voice Distance & Physics

// lua_audio_set_default_falloff: audio.set_default_falloff(min_px: number, max_px?: number)
// Sets the global default radius for all FUTURE play_at calls.
lua_audio_set_default_falloff :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	// Arg 1: min_px (Required)
	min_px := f32(lua.L_checknumber(L, 1))
	audio_ctx.default_min_dist = min_px * AUDIO_SCALE

	// Arg 2: max_px (Optional)
	if lua.gettop(L) >= 2 {
		max_px := f32(lua.L_checknumber(L, 2))
		audio_ctx.default_max_dist = max_px * AUDIO_SCALE
	}
	
	return 0
}

// lua_audio_set_voice_falloff: audio.set_voice_falloff(handle: int, min_px: number, max_px?: number)
lua_audio_set_voice_falloff :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	voice := get_voice(u32(lua.L_checkinteger(L, 1)))
	if voice == nil do return 0

	// Arg 2: min_px (Required)
	min_px := f32(lua.L_checknumber(L, 2))
	ma.sound_set_min_distance(&voice.node, min_px * AUDIO_SCALE)

	// Arg 3: max_px (Optional)
	if lua.gettop(L) >= 3 {
		max_px := f32(lua.L_checknumber(L, 3))
		ma.sound_set_max_distance(&voice.node, max_px * AUDIO_SCALE)
	}
	
	return 0
}

// lua_audio_set_default_falloff_mode: audio.set_default_falloff_mode(mode: string)
lua_audio_set_default_falloff_mode :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	mode_str := string(lua.L_checkstring(L, 1))

	switch mode_str {
	case "none":        audio_ctx.default_attenuation_model = .none
	case "inverse":     audio_ctx.default_attenuation_model = .inverse
	case "linear":      audio_ctx.default_attenuation_model = .linear
	case "exponential": audio_ctx.default_attenuation_model = .exponential
	case:
		lua.L_error(L, cstring("Invalid distance curve. Use 'none', 'inverse', 'linear', or 'exponential'."))
	}

	return 0
}

// lua_audio_set_voice_falloff_mode: audio.set_voice_falloff_mode(handle: int, mode: string)
// Modes: "none", "inverse" (Default), "linear", "exponential"
lua_audio_set_voice_falloff_mode :: proc "c" (L: ^lua.State) -> c.int {
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

// lua_audio_set_track_lpf: audio.set_track_lpf(track: int, hz: number)
lua_audio_set_track_lpf :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	idx := lua.L_checkinteger(L, 1)
	if idx < 0 || idx >= MAX_TRACKS do return 0

	hz := f64(lua.L_checknumber(L, 2))
	
	// DSP SAFETY CLAMPS
	if hz < 10.0 do hz = 10.0
	if hz > 22000.0 do hz = 22000.0

	channels    := ma.engine_get_channels(&audio_ctx.engine)
	sample_rate := ma.engine_get_sample_rate(&audio_ctx.engine)
	
	format := ma.format.f32
	if audio_ctx.engine.pDevice != nil {
		format = audio_ctx.engine.pDevice.playback.playback_format
	}

	cfg := ma.lpf_config_init(format, channels, sample_rate, hz, 2)
	ma.lpf_node_reinit(&cfg, &audio_ctx.tracks[idx].lpf)
	return 0
}

// lua_audio_set_track_hpf: audio.set_track_hpf(track: int, hz: number)
lua_audio_set_track_hpf :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	idx := lua.L_checkinteger(L, 1)
	if idx < 0 || idx >= MAX_TRACKS do return 0

	hz := f64(lua.L_checknumber(L, 2))
	
	// DSP SAFETY CLAMPS: A 0Hz HPF creates a NaN singularity.
	if hz < 10.0 do hz = 10.0
	if hz > 22000.0 do hz = 22000.0

	channels    := ma.engine_get_channels(&audio_ctx.engine)
	sample_rate := ma.engine_get_sample_rate(&audio_ctx.engine)
	
	format := ma.format.f32
	if audio_ctx.engine.pDevice != nil {
		format = audio_ctx.engine.pDevice.playback.playback_format
	}

	cfg := ma.hpf_config_init(format, channels, sample_rate, hz, 2)
	ma.hpf_node_reinit(&cfg, &audio_ctx.tracks[idx].hpf)
	return 0
}

// lua_audio_set_track_delay_feedback: audio.set_track_delay_feedback(track: int, amount: number)
// amount is the decay feedback (0.0 to 1.0). 0.0 is off, 0.5 is a medium echo tail.
lua_audio_set_track_delay_feedback :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	idx := lua.L_checkinteger(L, 1)
	if idx < 0 || idx >= MAX_TRACKS do return 0

	amount := f32(lua.L_checknumber(L, 2))
	
	if amount < 0.0 do amount = 0.0
	if amount > 1.0 do amount = 1.0

	ma.delay_node_set_decay(&audio_ctx.tracks[idx].delay, amount)
	return 0
}

// lua_audio_set_track_delay_mix: audio.set_track_delay_mix(track: int, wet: number, dry?: number)
lua_audio_set_track_delay_mix :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    
    // 1. Fetch and validate track index
    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_TRACKS do return 0 // Silently reject Track 0 or out-of-bounds

    // 2. Fetch wet mix (required) and dry mix (optional, defaults to 1.0)
    wet := f32(lua.L_checknumber(L, 2))
    dry := f32(lua.L_optnumber(L, 3, 1.0)) 

    // 3. Mutate the active miniaudio node
    ma.delay_node_set_wet(&audio_ctx.tracks[idx].delay, wet)
    ma.delay_node_set_dry(&audio_ctx.tracks[idx].delay, dry)

    return 0
}

// lua_audio_config_track_delay_times: audio.config_track_delay_times({ [1] = 0.5, [4] = 2.0 })
lua_audio_config_track_delay_times :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    
    // 1. Validate the input is a table
    lua.L_checktype(L, 1, lua.TTABLE)

    // 2. Iterate only over valid sub-tracks (Master track 0 has no delay node)
    for i in 0..<MAX_TRACKS {
        // Push the integer key we want to look up (e.g., 1, then 2, etc.)
        lua.pushinteger(L, lua.Integer(i))
        
        // gettable pops the key we just pushed, and pushes the value at table[key]
        // The table is at absolute index 1 on the Lua stack
        lua.gettable(L, 1)

        // 3. Check if the value exists and is a number
        // -1 is the top of the stack (the value we just fetched)
        if lua.type(L, -1) == lua.TNUMBER {
            audio_ctx.track_delay_times[i] = f32(lua.tonumber(L, -1))
        }
        
        // 4. Clean up the stack
        // Pop the value so the stack is perfectly clean for the next loop iteration
        lua.pop(L, 1)
    }
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

	// 1. Pause the track DSP immediately to stop audio output
	ma.sound_group_stop(&audio_ctx.tracks[idx].group)

	// 2. Destroy all active voices assigned to this track to reclaim their pool slots
	for i in 0..<MAX_VOICES {
		voice := &audio_ctx.voices[i]
		if voice.active && voice.track_idx == int(idx) {
			ma.sound_stop(&voice.node)
			ma.sound_uninit(&voice.node)
			voice.active = false
		}
	}

	return 0
}

/////////////////

// lua_audio_get_voice_info: audio.get_voice_info(handle) -> time, duration
lua_audio_get_voice_info :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle := u32(lua.L_checkinteger(L, 1))
	
	voice := get_voice(handle)
	if voice == nil do return 0 // Returns nil, nil to Lua

	t, d: f32
	// Both write to the pointer and return a ma.result
	ma.sound_get_cursor_in_seconds(&voice.node, &t)
	ma.sound_get_length_in_seconds(&voice.node, &d)

	lua.pushnumber(L, auto_cast t)
	lua.pushnumber(L, auto_cast d)
	return 2
}

// lua_audio_is_voice_playing: audio.is_voice_playing(handle: int) -> bool
lua_audio_is_voice_playing :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	handle := u32(lua.L_checkinteger(L, 1))
	
	voice := get_voice(handle)
	if voice == nil {
		lua.pushboolean(L, false)
		return 1
	}

	// ma.sound_is_playing returns false if the sound has reached the end or is paused
	is_playing := ma.sound_is_playing(&voice.node)
	lua.pushboolean(L, b32(is_playing))
	return 1
}

// lua_audio_stop_all_voices: audio.stop_all_voices()
// Immediately halts and destroys every active voice in the engine.
lua_audio_stop_all_voices :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()

  for i in 0..<MAX_VOICES {
    voice := &audio_ctx.voices[i]
    if voice.active {
      ma.sound_stop(&voice.node)
      ma.sound_uninit(&voice.node)
      voice.active = false
    }
  }

  return 0
}

// lua_audio_get_sound_info: audio.get_sound_info(sound) -> (path, duration, is_stream)
lua_audio_get_sound_info :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  sound := cast(^Sound)lua.L_checkudata(L, 1, cstring("Sound_Meta"))
  if sound == nil do return 0

  duration: f32
  // Queries length from your pinned cache_ref instance
  ma.sound_get_length_in_seconds(&sound.cache_ref, &duration)

  lua.pushstring(L, sound.filepath)
  lua.pushnumber(L, lua.Number(duration)) // <--- Fixed Cast
  lua.pushboolean(L, b32(sound.is_stream))

  return 3
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

    // --- Engine Configuration (Call BEFORE Engine Init) ---
    lua.pushcfunction(L, lua_audio_config_track_delay_times)
    lua.setfield(L, -2, cstring("config_track_delay_times"))

    // --- Global Listener & Defaults ---
    lua.pushcfunction(L, lua_audio_set_listener_position)
    lua.setfield(L, -2, cstring("set_listener_position"))
    lua.pushcfunction(L, lua_audio_set_listener_rotation)
    lua.setfield(L, -2, cstring("set_listener_rotation"))
    lua.pushcfunction(L, lua_audio_set_listener_velocity)
    lua.setfield(L, -2, cstring("set_listener_velocity"))
    lua.pushcfunction(L, lua_audio_set_default_falloff)
    lua.setfield(L, -2, cstring("set_default_falloff"))
    lua.pushcfunction(L, lua_audio_set_default_falloff_mode)
    lua.setfield(L, -2, cstring("set_default_falloff_mode"))

    // --- Asset Management ---
    lua.pushcfunction(L, lua_audio_load_sound)
    lua.setfield(L, -2, cstring("load_sound"))
    lua.pushcfunction(L, lua_audio_get_sound_info)
    lua.setfield(L, -2, cstring("get_sound_info"))

    // --- Playback Entry Points ---
    lua.pushcfunction(L, lua_audio_play)
    lua.setfield(L, -2, cstring("play"))
    lua.pushcfunction(L, lua_audio_play_at)
    lua.setfield(L, -2, cstring("play_at"))

    // --- Instance Control (Common) ---
    lua.pushcfunction(L, lua_audio_set_voice_volume)
    lua.setfield(L, -2, cstring("set_voice_volume"))
    lua.pushcfunction(L, lua_audio_set_voice_pitch)
    lua.setfield(L, -2, cstring("set_voice_pitch"))
    lua.pushcfunction(L, lua_audio_set_voice_pan)
    lua.setfield(L, -2, cstring("set_voice_pan"))
    lua.pushcfunction(L, lua_audio_set_voice_looping)
    lua.setfield(L, -2, cstring("set_voice_looping"))
    lua.pushcfunction(L, lua_audio_seek_voice)
    lua.setfield(L, -2, cstring("seek_voice"))
    lua.pushcfunction(L, lua_audio_fade_voice)
    lua.setfield(L, -2, cstring("fade_voice"))
    lua.pushcfunction(L, lua_audio_get_voice_info)
    lua.setfield(L, -2, cstring("get_voice_info"))
    lua.pushcfunction(L, lua_audio_is_voice_playing)
    lua.setfield(L, -2, cstring("is_voice_playing"))

    // --- Instance Control (Spatial) ---
    lua.pushcfunction(L, lua_audio_set_voice_position)
    lua.setfield(L, -2, cstring("set_voice_position"))
    lua.pushcfunction(L, lua_audio_set_voice_velocity)
    lua.setfield(L, -2, cstring("set_voice_velocity"))
    lua.pushcfunction(L, lua_audio_set_voice_falloff)
    lua.setfield(L, -2, cstring("set_voice_falloff"))
    lua.pushcfunction(L, lua_audio_set_voice_rolloff)
    lua.setfield(L, -2, cstring("set_voice_rolloff"))
    lua.pushcfunction(L, lua_audio_set_voice_falloff_mode)
    lua.setfield(L, -2, cstring("set_voice_falloff_mode"))
    lua.pushcfunction(L, lua_audio_set_voice_pan_mode)
    lua.setfield(L, -2, cstring("set_voice_pan_mode"))

    // --- Instance Lifecycle ---
    lua.pushcfunction(L, lua_audio_pause_voice)
    lua.setfield(L, -2, cstring("pause_voice"))
    lua.pushcfunction(L, lua_audio_resume_voice)
    lua.setfield(L, -2, cstring("resume_voice"))
    lua.pushcfunction(L, lua_audio_stop_voice)
    lua.setfield(L, -2, cstring("stop_voice"))

    // --- Track Mixing & DSP ---
    lua.pushcfunction(L, lua_audio_set_track_volume)
    lua.setfield(L, -2, cstring("set_track_volume"))
    lua.pushcfunction(L, lua_audio_set_track_pitch)
    lua.setfield(L, -2, cstring("set_track_pitch"))
    lua.pushcfunction(L, lua_audio_set_track_pan)
    lua.setfield(L, -2, cstring("set_track_pan"))
    lua.pushcfunction(L, lua_audio_fade_track)
    lua.setfield(L, -2, cstring("fade_track"))
    lua.pushcfunction(L, lua_audio_set_track_lpf)
    lua.setfield(L, -2, cstring("set_track_lpf"))
    lua.pushcfunction(L, lua_audio_set_track_hpf)
    lua.setfield(L, -2, cstring("set_track_hpf"))
    lua.pushcfunction(L, lua_audio_set_track_delay_mix)
    lua.setfield(L, -2, cstring("set_track_delay_mix"))
    lua.pushcfunction(L, lua_audio_set_track_delay_feedback)
    lua.setfield(L, -2, cstring("set_track_delay_feedback"))
    lua.pushcfunction(L, lua_audio_pause_track)
    lua.setfield(L, -2, cstring("pause_track"))
    lua.pushcfunction(L, lua_audio_resume_track)
    lua.setfield(L, -2, cstring("resume_track"))
    lua.pushcfunction(L, lua_audio_stop_track)
    lua.setfield(L, -2, cstring("stop_track"))
    
    lua.pushcfunction(L, lua_audio_stop_all_voices)
		lua.setfield(L, -2, cstring("stop_all_voices"))

    lua.setglobal(L, cstring("audio"))
}
