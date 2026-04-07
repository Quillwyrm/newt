package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import lua "luajit"
import ma "vendor:miniaudio"
import sdl "vendor:sdl3"

//TODO: look into reverb/distortion. figure out if 'stop' is a bad word.

//

// # Audio API - audio.function()
//
// ### Engine Configuration (Call BEFORE Engine Init)
// - `.config_bus_delay_times(table)` — configure per-bus delay times before audio init.
//   Example: `{ [1] = 0.5, [4] = 2.0 }`
//   Only buses `1..MAX_AUDIO_BUSES-1` are configurable here. Bus `0` is the master bus.
//
// ### Global Listener & Defaults
// - `.set_listener_position(x, y)`
// - `.set_listener_rotation(degrees)`
// - `.set_listener_velocity(vx, vy)`
// - `.set_default_falloff(min_px, max_px?)`
// - `.set_default_falloff_mode(mode)` — modes: `"none"`, `"inverse"`, `"linear"`, `"exponential"`
//
// ### Asset Management
// - `.load_sound(filepath, mode?) -> Sound | nil, err`
//   `mode` must be `"static"` or `"stream"`.
// - `.get_sound_info(sound) -> path, duration, is_stream`
//   Returns `nil, nil, nil` if the sound has been freed.
//
// ### Playback Entry Points
// - `.play(sound, bus_id, volume?, pitch?, pan?) -> handle | nil, err`
//   Plays a non-spatialized 2D voice on the given bus.
// - `.play_at(sound, bus_id, x, y, volume?, pitch?) -> handle | nil, err`
//   Plays a spatialized voice at world position `(x, y)` on the given bus.
//
// ### Instance Control (Common)
// - `.set_voice_volume(handle, volume)`
// - `.set_voice_pitch(handle, pitch)`
// - `.set_voice_pan(handle, pan)`
// - `.set_voice_looping(handle, is_looping)`
// - `.seek_voice(handle, offset, unit?)` — units: `"seconds"` (default), `"samples"`
// - `.fade_voice(handle, target_volume, duration)`
// - `.get_voice_info(handle) -> time_in_seconds, duration_in_seconds`
//   Returns `nil, nil` for a dead or stale voice handle.
// - `.is_voice_playing(handle) -> bool`
//   Returns `false` for a dead or stale voice handle.
//
// ### Instance Control (Spatial)
// - `.set_voice_position(handle, x, y)`
// - `.set_voice_velocity(handle, vx, vy)`
// - `.set_voice_falloff(handle, min_px, max_px?)`
// - `.set_voice_rolloff(handle, factor)`
// - `.set_voice_falloff_mode(handle, mode)` — modes: `"none"`, `"inverse"`, `"linear"`, `"exponential"`
// - `.set_voice_pan_mode(handle, mode)` — modes: `"balance"`, `"pan"`
//
// ### Instance Lifecycle
// - `.pause_voice(handle)`
// - `.resume_voice(handle)`
// - `.stop_voice(handle)` — halts playback and reclaims the voice slot
//
// ### Bus Mixing
// - `.set_bus_volume(bus_id, volume)`
// - `.set_bus_pitch(bus_id, pitch)`
// - `.set_bus_pan(bus_id, pan)`
// - `.fade_bus(bus_id, target_volume, duration)`
// - `.set_bus_lpf(bus_id, hz)`
// - `.set_bus_hpf(bus_id, hz)`
// - `.set_bus_delay_mix(bus_id, wet, dry?)`
// - `.set_bus_delay_feedback(bus_id, amount)`
// - `.pause_bus(bus_id)`
// - `.resume_bus(bus_id)`
// - `.stop_bus(bus_id)` — halts the bus and destroys all active voices assigned to it
// - `.stop_all_voices()`
//
// ### Bus Rules
// - Bus `0` is the master bus.
// - Bus `0` is valid for volume/pitch/pan/fade/pause/resume/stop.
// - Bus `0` is invalid for LPF/HPF/delay controls.
// - DSP buses are `1..MAX_AUDIO_BUSES-1`.

// =============================================================================
// Audio Data Structures
// =============================================================================

MAX_AUDIO_BUSES :: 8
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

// Bus represents a mixing bus (sound group) for categorized volume control.
AudioBus :: struct {
    group: ma.sound_group,
    lpf:   ma.lpf_node, // <--- Persistent memory for the LPF
    hpf:   ma.hpf_node, // <--- Persistent memory for the HPF
    delay: ma.delay_node, // <--- Added delay node
}

// Voice represents an active, playing sound node.
Voice :: struct {
    node:         ma.sound,
    active:       bool,
    generation:   u64, // <--- Identity tracking
    bus_idx:      int,
    source_sound: ^Sound,
}

// =============================================================================
// Global Audio Context
// =============================================================================

// Global Audio Context
audio_ctx: struct {
    engine:                    ma.engine,
    mixer:                     [MAX_AUDIO_BUSES]AudioBus,
    voices:                    [MAX_VOICES]Voice,
    initialized:               bool,

    //default state
    default_min_dist:          f32,
    default_max_dist:          f32,
    default_attenuation_model: ma.attenuation_model,

    // Config state populated by Lua before audio_init() runs
    bus_delay_times:           [MAX_AUDIO_BUSES]f32,

    // Generation counter
    next_generation:           u64,
}

// =============================================================================
// Audio Core Procedures
// =============================================================================

check_audio_safety :: #force_inline proc(L: ^lua.State, fn_name: cstring) {
    if !audio_ctx.initialized {
        lua.L_error(L, "%s: audio system not initialized", fn_name)
    }
}


// audio_init initializes the miniaudio engine, master bus, sub-bus DSP chains, and voice pool.
// Returns true on full success. On any failure, partially initialized state is rolled back.
audio_init :: proc() -> bool {
    if audio_ctx.initialized do return true

    config := ma.engine_config_init()

    result := ma.engine_init(&config, &audio_ctx.engine)
    if result != .SUCCESS {
        fmt.eprintf("Failed to initialize audio engine: %v\n", result)
        return false
    }

    master_ok := false
    buses_built := 0
    init_ok := false

    defer {
        if !init_ok {
            for j := buses_built; j >= 1; j -= 1 {
                ma.lpf_node_uninit(&audio_ctx.mixer[j].lpf, nil)
                ma.hpf_node_uninit(&audio_ctx.mixer[j].hpf, nil)
                ma.delay_node_uninit(&audio_ctx.mixer[j].delay, nil)
                ma.sound_group_uninit(&audio_ctx.mixer[j].group)
            }

            if master_ok {
                ma.sound_group_uninit(&audio_ctx.mixer[0].group)
            }

            ma.engine_uninit(&audio_ctx.engine)
        }
    }

    // Initialize master bus and shared graph info.
    channels := ma.engine_get_channels(&audio_ctx.engine)
    sample_rate := ma.engine_get_sample_rate(&audio_ctx.engine)
    graph := ma.engine_get_node_graph(&audio_ctx.engine)

    result = ma.sound_group_init(&audio_ctx.engine, {}, nil, &audio_ctx.mixer[0].group)
    if result != .SUCCESS {
        fmt.eprintf("Failed to initialize Master Bus: %v\n", result)
        return false
    }
    master_ok = true

    // Buses 1..N-1 each get: Group -> Delay -> HPF -> LPF -> Master
    for i in 1 ..< MAX_AUDIO_BUSES {
        result = ma.sound_group_init(&audio_ctx.engine, {}, nil, &audio_ctx.mixer[i].group)
        if result != .SUCCESS {
            fmt.eprintf("Failed to initialize Bus %d Group: %v\n", i, result)
            return false
        }

        delay_sec := audio_ctx.bus_delay_times[i]
        if delay_sec <= 0.0 do delay_sec = 0.25

        delay_frames := u32(delay_sec * f32(sample_rate))
        delay_cfg := ma.delay_node_config_init(channels, sample_rate, delay_frames, 0.0)
        result = ma.delay_node_init(graph, &delay_cfg, nil, &audio_ctx.mixer[i].delay)
        if result != .SUCCESS {
            fmt.eprintf("Failed to initialize Bus %d Delay: %v\n", i, result)
            ma.sound_group_uninit(&audio_ctx.mixer[i].group)
            return false
        }

        hpf_cfg := ma.hpf_node_config_init(channels, sample_rate, 10.0, 2)
        result = ma.hpf_node_init(graph, &hpf_cfg, nil, &audio_ctx.mixer[i].hpf)
        if result != .SUCCESS {
            fmt.eprintf("Failed to initialize Bus %d HPF: %v\n", i, result)
            ma.delay_node_uninit(&audio_ctx.mixer[i].delay, nil)
            ma.sound_group_uninit(&audio_ctx.mixer[i].group)
            return false
        }

        lpf_cfg := ma.lpf_node_config_init(channels, sample_rate, 20000.0, 2)
        result = ma.lpf_node_init(graph, &lpf_cfg, nil, &audio_ctx.mixer[i].lpf)
        if result != .SUCCESS {
            fmt.eprintf("Failed to initialize Bus %d LPF: %v\n", i, result)
            ma.hpf_node_uninit(&audio_ctx.mixer[i].hpf, nil)
            ma.delay_node_uninit(&audio_ctx.mixer[i].delay, nil)
            ma.sound_group_uninit(&audio_ctx.mixer[i].group)
            return false
        }

        base_group := cast(^ma.node)&audio_ctx.mixer[i].group
        base_delay := cast(^ma.node)&audio_ctx.mixer[i].delay
        base_hpf := cast(^ma.node)&audio_ctx.mixer[i].hpf
        base_lpf := cast(^ma.node)&audio_ctx.mixer[i].lpf
        base_master := cast(^ma.node)&audio_ctx.mixer[0].group

        ma.node_attach_output_bus(base_group, 0, base_delay, 0)
        ma.node_attach_output_bus(base_delay, 0, base_hpf, 0)
        ma.node_attach_output_bus(base_hpf, 0, base_lpf, 0)
        ma.node_attach_output_bus(base_lpf, 0, base_master, 0)

        buses_built = i
    }

    // Reset voice pool state.
    for i in 0 ..< MAX_VOICES {
        audio_ctx.voices[i].node = {}
        audio_ctx.voices[i].active = false
        audio_ctx.voices[i].generation = 0
        audio_ctx.voices[i].bus_idx = 0
        audio_ctx.voices[i].source_sound = nil
    }

    // Reset runtime defaults.
    audio_ctx.default_min_dist = 100.0 * AUDIO_SCALE
    audio_ctx.default_max_dist = 10000.0 * AUDIO_SCALE
    audio_ctx.default_attenuation_model = .inverse
    audio_ctx.next_generation = 0

    init_ok = true
    audio_ctx.initialized = true
    return true
}

// audio_shutdown uninitializes all active voices, buses, and the miniaudio engine.
// Safe to call multiple times.
audio_shutdown :: proc() {
    if !audio_ctx.initialized do return

    // Halt and destroy all active voices first so the mixer graph goes silent.
    for i in 0 ..< MAX_VOICES {
        if audio_ctx.voices[i].active {
            ma.sound_stop(&audio_ctx.voices[i].node)
            ma.sound_uninit(&audio_ctx.voices[i].node)
            audio_ctx.voices[i].active = false
            audio_ctx.voices[i].source_sound = nil
            audio_ctx.voices[i].generation = 0
            audio_ctx.voices[i].bus_idx = 0
            audio_ctx.voices[i].node = {}
        }
    }

    // Give the backend a brief moment to flush silence to the hardware ring buffer.
    sdl.Delay(50)

    // Tear down sub-buses in reverse order, then the master bus, then the engine.
    for i := MAX_AUDIO_BUSES - 1; i >= 1; i -= 1 {
        ma.lpf_node_uninit(&audio_ctx.mixer[i].lpf, nil)
        ma.hpf_node_uninit(&audio_ctx.mixer[i].hpf, nil)
        ma.delay_node_uninit(&audio_ctx.mixer[i].delay, nil)
        ma.sound_group_uninit(&audio_ctx.mixer[i].group)
    }

    ma.sound_group_uninit(&audio_ctx.mixer[0].group)
    ma.engine_uninit(&audio_ctx.engine)

    audio_ctx.initialized = false
    audio_ctx.next_generation = 0
}


// audio_update polls the voice pool and reclaims slots that have finished playing.
audio_update :: proc() {
    for i in 0 ..< MAX_VOICES {
        voice := &audio_ctx.voices[i]
        if !voice.active do continue

        if bool(ma.sound_at_end(&voice.node)) {
            ma.sound_uninit(&voice.node)
            voice.active = false
            voice.source_sound = nil // <--- Clear the dangling pointer
        }
    }
}

// get_voice safely validates a packed handle from Lua and returns the Voice pointer.
// Returns nil if the voice is dead or the handle is stale.
get_voice :: proc(handle: u32) -> ^Voice {
    index := handle & 0xFFFF
    gen := handle >> 16

    if index >= MAX_VOICES do return nil

    voice := &audio_ctx.voices[index]

    // Mask the 64-bit generation down to 16 bits to compare against Lua's stamp
    if voice.active && u32(voice.generation & 0xFFFF) == gen {
        return voice
    }
    return nil
}

// claim_and_init_voice handles pool allocation, voice stealing, and miniaudio node initialization.
// Returns (voice, handle, nil, true) on success.
// Returns (nil, 0, err, false) on allocation or backend init failure.
claim_and_init_voice :: proc(sound: ^Sound, bus_idx: int) -> (^Voice, u32, cstring, bool) {
    voice_idx := -1
    oldest_idx := -1
    oldest_gen: u64 = ~u64(0) // Max u64 value

    // 1. Scan for free slot or oldest stealable target
    for i in 0 ..< MAX_VOICES {
        v := &audio_ctx.voices[i]

        if !v.active {
            voice_idx = i
            break
        }

        if !v.source_sound.is_stream {
            if v.generation < oldest_gen {
                oldest_gen = v.generation
                oldest_idx = i
            }
        }
    }

    // 2. Execute Voice Stealing if pool is full
    if voice_idx == -1 {
        if oldest_idx != -1 {
            voice_idx = oldest_idx
            stolen := &audio_ctx.voices[voice_idx]

            ma.sound_stop(&stolen.node)
            ma.sound_uninit(&stolen.node)
            stolen.active = false
            stolen.source_sound = nil
        } else {
            // Pathological edge case: 64 streams playing simultaneously.
            return nil, 0, "voice pool exhausted (all active voices are streaming)", false
        }
    }

    // 3. Claim the slot
    voice := &audio_ctx.voices[voice_idx]
    voice.node = {} // Zero state
    voice.bus_idx = bus_idx
    voice.source_sound = sound

    // 4. Initialize Miniaudio Node
    result: ma.result
    flags: ma.sound_flags = {}
    if sound.is_stream do flags += {.STREAM}

    if sound.is_stream {
        result = ma.sound_init_from_file(&audio_ctx.engine, sound.filepath, flags, &audio_ctx.mixer[bus_idx].group, nil, &voice.node)
    } else {
        result = ma.sound_init_copy(&audio_ctx.engine, &sound.cache_ref, flags, &audio_ctx.mixer[bus_idx].group, &voice.node)
    }

    if result != .SUCCESS {
        voice.source_sound = nil

        if sound.is_stream {
            return nil, 0, fmt.caprintf("failed to initialize streaming voice from '%s': %s", sound.filepath, ma.result_description(result)), false
        } else {
            return nil, 0, fmt.caprintf("failed to initialize cached voice from '%s': %s", sound.filepath, ma.result_description(result)), false
        }
    }

    // 5. Assign chronological generation and pack handle
    audio_ctx.next_generation += 1
    voice.generation = audio_ctx.next_generation
    voice.active = true

    handle := (u32(voice.generation & 0xFFFF) << 16) | u32(voice_idx)
    return voice, handle, nil, true
}

// =============================================================================
// Audio API Procedures
// =============================================================================

// lua_audio_load_sound: audio.load_sound(filepath: string, mode?: string) -> Sound | nil, err
lua_audio_load_sound :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.load_sound")

    c_path := lua.L_checkstring(L, 1)
    mode := "static"
    if lua.gettop(L) >= 2 do mode = string(lua.L_checkstring(L, 2))
    if mode != "static" && mode != "stream" {
        lua.L_error(L, "audio.load_sound: expected mode 'static' or 'stream'")
        return 0
    }

    sound := cast(^Sound)lua.newuserdata(L, size_of(Sound))
    sound.filepath = strings.clone_to_cstring(string(c_path))
    sound.is_stream = (mode == "stream")

    flags: ma.sound_flags = {}
    if !sound.is_stream {
        result := ma.sound_init_from_file(&audio_ctx.engine, sound.filepath, {.DECODE}, nil, nil, &sound.cache_ref)
        if result != .SUCCESS {
            delete(sound.filepath)
            sound.filepath = nil
            lua.pushnil(L)
            lua.pushfstring(L, "audio.load_sound: failed to load static sound '%s': %s", c_path, ma.result_description(result))
            return 2
        }
    }

    lua.L_getmetatable(L, "Sound")
    lua.setmetatable(L, -2)
    return 1
}

//LISTNER

// lua_audio_set_listener_position: audio.set_listener_position(x: number, y: number)
lua_audio_set_listener_position :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_listener_position")
    x := f32(lua.L_checknumber(L, 1))
    y := f32(lua.L_checknumber(L, 2))
    ma.engine_listener_set_position(&audio_ctx.engine, 0, x * AUDIO_SCALE, y * AUDIO_SCALE, -1)
    return 0
}

// lua_audio_set_listener_rotation: audio.set_listener_rotation(degrees: number)
lua_audio_set_listener_rotation :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_listener_rotation")

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
    check_audio_safety(L, "audio.set_listener_velocity")

    vx := f32(lua.L_checknumber(L, 1))
    vy := f32(lua.L_checknumber(L, 2))

    ma.engine_listener_set_velocity(&audio_ctx.engine, 0, vx * AUDIO_SCALE, vy * AUDIO_SCALE, 0)
    return 0
}

//PLAYBACK

// lua_audio_play: audio.play(sound: Sound, bus: int, vol?: num, pitch?: num, pan?: num) -> handle | nil, err
lua_audio_play :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.play")
    // 1. Fetch & Validate Lua Arguments
    sound := cast(^Sound)lua.L_testudata(L, 1, "Sound")
    if sound == nil {
        if lua.isnil(L, 1) {
            lua.L_error(L, "audio.play: expected Sound, got nil (did audio.load_sound fail?)")
        } else {
            lua.L_error(L, "audio.play: expected Sound")
        }
        return 0
    }

    if sound.filepath == nil {
        lua.pushnil(L)
        lua.pushstring(L, "audio.play: sound has been freed")
        return 2
    }

    bus_idx := lua.L_checkinteger(L, 2)

    if bus_idx < 0 || bus_idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.play: invalid bus index %d", bus_idx)
        return 0
    }

    vol := f32(lua.L_optnumber(L, 3, 1.0))
    pitch := f32(lua.L_optnumber(L, 4, 1.0))
    pan := f32(lua.L_optnumber(L, 5, 0.0))

    // 2. Delegate Allocation & MA Graph Initialization
    voice, handle, err, ok := claim_and_init_voice(sound, int(bus_idx))
    if !ok {
        lua.pushnil(L)
        lua.pushfstring(L, "audio.play: %s", err)
        return 2
    }

    // 3. Mode Setup: 2D Global
    ma.sound_set_spatialization_enabled(&voice.node, false)
    ma.sound_set_pan(&voice.node, pan)

    // 4. Shared Setup & Playback
    ma.sound_set_volume(&voice.node, vol)
    ma.sound_set_pitch(&voice.node, pitch)
    ma.sound_start(&voice.node)

    lua.pushinteger(L, lua.Integer(handle))
    return 1
}

// lua_audio_play_at: audio.play_at(sound: Sound, bus: int, x: num, y: num, vol?: num, pitch?: num) -> handle | nil, err
lua_audio_play_at :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.play_at")

    // 1. Fetch & Validate Lua Arguments
    sound := cast(^Sound)lua.L_testudata(L, 1, "Sound")
    if sound == nil {
        if lua.isnil(L, 1) {
            lua.L_error(L, "audio.play_at: expected Sound, got nil (did audio.load_sound fail?)")
        } else {
            lua.L_error(L, "audio.play_at: expected Sound")
        }
        return 0
    }

    if sound.filepath == nil {
        lua.pushnil(L)
        lua.pushstring(L, "audio.play_at: sound has been freed")
        return 2
    }

    bus_idx := lua.L_checkinteger(L, 2)

    if bus_idx < 0 || bus_idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.play_at: invalid bus index %d", bus_idx)
        return 0
    }

    x := f32(lua.L_checknumber(L, 3))
    y := f32(lua.L_checknumber(L, 4))
    vol := f32(lua.L_optnumber(L, 5, 1.0))
    pitch := f32(lua.L_optnumber(L, 6, 1.0))

    // 2. Delegate Allocation & MA Graph Initialization
    voice, handle, err, ok := claim_and_init_voice(sound, int(bus_idx))
    if !ok {
        lua.pushnil(L)
        lua.pushfstring(L, "audio.play_at: %s", err)
        return 2
    }

    // 3. Mode Setup: 3D Spatial
    ma.sound_set_spatialization_enabled(&voice.node, true)
    ma.sound_set_position(&voice.node, x * AUDIO_SCALE, y * AUDIO_SCALE, 0)

    // Apply engine defaults automatically
    ma.sound_set_min_distance(&voice.node, audio_ctx.default_min_dist)
    ma.sound_set_max_distance(&voice.node, audio_ctx.default_max_dist)
    ma.sound_set_attenuation_model(&voice.node, audio_ctx.default_attenuation_model)

    // 4. Shared Setup & Playback
    ma.sound_set_volume(&voice.node, vol)
    ma.sound_set_pitch(&voice.node, pitch)
    ma.sound_start(&voice.node)

    lua.pushinteger(L, lua.Integer(handle))
    return 1
}

//VOICE

// lua_audio_set_voice_volume: audio.set_voice_volume(handle: int, volume: number)
lua_audio_set_voice_volume :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_voice_volume")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice == nil do return 0

    vol := f32(lua.L_checknumber(L, 2))
    ma.sound_set_volume(&voice.node, vol)

    return 0
}

// lua_audio_set_voice_pitch: audio.set_voice_pitch(handle: int, pitch: number)
lua_audio_set_voice_pitch :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_voice_pitch")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice == nil do return 0

    ma.sound_set_pitch(&voice.node, f32(lua.L_checknumber(L, 2)))
    return 0
}

// lua_audio_set_voice_pan: audio.set_voice_pan(handle: int, pan: number)
lua_audio_set_voice_pan :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_voice_pan")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice == nil do return 0

    pan := f32(lua.L_checknumber(L, 2))
    // Drop back to 2D mode to honor the manual pan
    ma.sound_set_spatialization_enabled(&voice.node, false)
    ma.sound_set_pan(&voice.node, pan)
    return 0
}

// lua_audio_seek_voice: audio.seek_voice(handle: int, offset: number, unit?: string)
// Valid units: "seconds" (default) or "samples".
lua_audio_seek_voice :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.seek_voice")

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
        target_frame = u64(offset)
    } else if unit == "seconds" {
        format: ma.format
        channels: u32
        sample_rate: u32

        ma.sound_get_data_format(&voice.node, &format, &channels, &sample_rate, nil, 0)
        target_frame = u64(offset * f64(sample_rate))
    } else {
        lua.L_error(L, "audio.seek_voice: expected unit 'seconds' or 'samples'")
        return 0
    }

    ma.sound_seek_to_pcm_frame(&voice.node, target_frame)
    return 0
}

// lua_audio_set_voice_position: audio.set_voice_position(handle: int, x: number, y: number)
lua_audio_set_voice_position :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_voice_position")

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
    check_audio_safety(L, "audio.set_voice_looping")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice == nil do return 0

    ma.sound_set_looping(&voice.node, b32(lua.toboolean(L, 2)))
    return 0
}

// lua_audio_fade_voice: audio.fade_voice(handle: int, target: number, duration: number)
lua_audio_fade_voice :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.fade_voice")

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
lua_audio_pause_voice :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.pause_voice")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice != nil do ma.sound_stop(&voice.node)
    return 0
}

// lua_audio_resume_voice: audio.resume_voice(handle: int)
lua_audio_resume_voice :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.resume_voice")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice != nil do ma.sound_start(&voice.node)
    return 0
}

// lua_audio_stop_voice: audio.stop_voice(handle: int)
lua_audio_stop_voice :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.stop_voice")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))

    if voice != nil {
        ma.sound_stop(&voice.node) // 1. Thread-safe halt
        ma.sound_uninit(&voice.node) // 2. Safe memory destruction
        voice.active = false // 3. Reclaim pool slot
        voice.source_sound = nil // 4. Clear the dangling pointer
    }

    return 0
}

//Voice Distance & Physics

// lua_audio_set_default_falloff: audio.set_default_falloff(min_px: number, max_px?: number)
// Sets the global default radius for all FUTURE play_at calls.
lua_audio_set_default_falloff :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_default_falloff")

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
    check_audio_safety(L, "audio.set_voice_falloff")

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
    check_audio_safety(L, "audio.set_default_falloff_mode")

    mode_str := string(lua.L_checkstring(L, 1))

    switch mode_str {
    case "none":
        audio_ctx.default_attenuation_model = .none
    case "inverse":
        audio_ctx.default_attenuation_model = .inverse
    case "linear":
        audio_ctx.default_attenuation_model = .linear
    case "exponential":
        audio_ctx.default_attenuation_model = .exponential
    case:
        lua.L_error(L, "audio.set_default_falloff_mode: expected 'none', 'inverse', 'linear', or 'exponential'")
        return 0
    }
    return 0
}

// lua_audio_set_voice_falloff_mode: audio.set_voice_falloff_mode(handle: int, mode: string)
// Modes: "none", "inverse" (Default), "linear", "exponential"
lua_audio_set_voice_falloff_mode :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_voice_falloff_mode")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice == nil do return 0

    mode_str := string(lua.L_checkstring(L, 2))
    model := ma.attenuation_model.none

    switch mode_str {
    case "none":
        model = .none
    case "inverse":
        model = .inverse
    case "linear":
        model = .linear
    case "exponential":
        model = .exponential
    case:
        lua.L_error(L, "audio.set_voice_falloff_mode: expected 'none', 'inverse', 'linear', or 'exponential'")
        return 0
    }

    ma.sound_set_attenuation_model(&voice.node, model)
    return 0
}

// lua_audio_set_voice_rolloff: audio.set_voice_rolloff(handle: int, factor: number)
lua_audio_set_voice_rolloff :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_voice_rolloff")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice == nil do return 0

    factor := f32(lua.L_checknumber(L, 2))
    ma.sound_set_rolloff(&voice.node, factor)
    return 0
}

// lua_audio_set_voice_velocity: audio.set_voice_velocity(handle: int, vx: number, vy: number)
lua_audio_set_voice_velocity :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_voice_velocity")

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
    check_audio_safety(L, "audio.set_voice_pan_mode")

    voice := get_voice(u32(lua.L_checkinteger(L, 1)))
    if voice == nil do return 0

    mode_str := string(lua.L_checkstring(L, 2))
    mode := ma.pan_mode.balance

    switch mode_str {
    case "balance":
        mode = .balance
    case "pan":
        mode = .pan
    case:
        lua.L_error(L, "audio.set_voice_pan_mode: expected 'balance' or 'pan'")
        return 0
    }

    ma.sound_set_pan_mode(&voice.node, mode)
    return 0
}

//bus/mixer

// lua_audio_set_bus_volume: audio.set_bus_volume(bus: int, volume: number)
lua_audio_set_bus_volume :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_bus_volume")

    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.set_bus_volume: invalid bus index %d", idx)
        return 0
    }

    vol := f32(lua.L_checknumber(L, 2))
    ma.sound_group_set_volume(&audio_ctx.mixer[idx].group, vol)

    return 0
}

// lua_audio_fade_bus: audio.fade_bus(bus: int, target: number, duration: number)
lua_audio_fade_bus :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.fade_bus")

    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.fade_bus: invalid bus index %d", idx)
        return 0
    }

    target := f32(lua.L_checknumber(L, 2))
    duration_seconds := f32(lua.L_checknumber(L, 3))
    duration_ms := u64(duration_seconds * 1000.0)

    current_vol := ma.sound_group_get_current_fade_volume(&audio_ctx.mixer[idx].group)
    ma.sound_group_set_fade_in_milliseconds(&audio_ctx.mixer[idx].group, current_vol, target, duration_ms)
    return 0
}

// lua_audio_set_bus_pitch: audio.set_bus_pitch(bus: int, pitch: number)
lua_audio_set_bus_pitch :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_bus_pitch")

    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.set_bus_pitch: invalid bus index %d", idx)
        return 0
    }

    ma.sound_group_set_pitch(&audio_ctx.mixer[idx].group, f32(lua.L_checknumber(L, 2)))
    return 0
}

// lua_audio_set_bus_pan: audio.set_bus_pan(bus: int, pan: number)
lua_audio_set_bus_pan :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_bus_pan")

    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.set_bus_pan: invalid bus index %d", idx)
        return 0
    }

    ma.sound_group_set_pan(&audio_ctx.mixer[idx].group, f32(lua.L_checknumber(L, 2)))
    return 0
}

// lua_audio_set_bus_lpf: audio.set_bus_lpf(bus: int, hz: number)
lua_audio_set_bus_lpf :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_bus_lpf")

    idx := lua.L_checkinteger(L, 1)
    if idx <= 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.set_bus_lpf: bus index must be between 1 and %d", MAX_AUDIO_BUSES - 1)
        return 0
    }

    hz := f64(lua.L_checknumber(L, 2))

    // DSP SAFETY CLAMPS
    if hz < 10.0 do hz = 10.0
    if hz > 22000.0 do hz = 22000.0

    channels := ma.engine_get_channels(&audio_ctx.engine)
    sample_rate := ma.engine_get_sample_rate(&audio_ctx.engine)

    format := ma.format.f32
    if audio_ctx.engine.pDevice != nil {
        format = audio_ctx.engine.pDevice.playback.playback_format
    }

    cfg := ma.lpf_config_init(format, channels, sample_rate, hz, 2)
    ma.lpf_node_reinit(&cfg, &audio_ctx.mixer[idx].lpf)
    return 0
}

// lua_audio_set_bus_hpf: audio.set_bus_hpf(bus: int, hz: number)
lua_audio_set_bus_hpf :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_bus_hpf")

    idx := lua.L_checkinteger(L, 1)
    if idx <= 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.set_bus_hpf: bus index must be between 1 and %d", MAX_AUDIO_BUSES - 1)
        return 0
    }

    hz := f64(lua.L_checknumber(L, 2))

    // DSP SAFETY CLAMPS: A 0Hz HPF creates a NaN singularity.
    if hz < 10.0 do hz = 10.0
    if hz > 22000.0 do hz = 22000.0

    channels := ma.engine_get_channels(&audio_ctx.engine)
    sample_rate := ma.engine_get_sample_rate(&audio_ctx.engine)

    format := ma.format.f32
    if audio_ctx.engine.pDevice != nil {
        format = audio_ctx.engine.pDevice.playback.playback_format
    }

    cfg := ma.hpf_config_init(format, channels, sample_rate, hz, 2)
    ma.hpf_node_reinit(&cfg, &audio_ctx.mixer[idx].hpf)
    return 0
}

// lua_audio_set_bus_delay_feedback: audio.set_bus_delay_feedback(bus: int, amount: number)
// amount is the decay feedback (0.0 to 1.0). 0.0 is off, 0.5 is a medium echo tail.
lua_audio_set_bus_delay_feedback :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_bus_delay_feedback")

    idx := lua.L_checkinteger(L, 1)
    if idx <= 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.set_bus_delay_feedback: bus index must be between 1 and %d", MAX_AUDIO_BUSES - 1)
        return 0
    }

    amount := f32(lua.L_checknumber(L, 2))

    if amount < 0.0 do amount = 0.0
    if amount > 1.0 do amount = 1.0

    ma.delay_node_set_decay(&audio_ctx.mixer[idx].delay, amount)
    return 0
}

// lua_audio_set_bus_delay_mix: audio.set_bus_delay_mix(bus: int, wet: number, dry?: number)
lua_audio_set_bus_delay_mix :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.set_bus_delay_mix")

    // 1. Fetch and validate bus index
    idx := lua.L_checkinteger(L, 1)
    if idx <= 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.set_bus_delay_mix: bus index must be between 1 and %d", MAX_AUDIO_BUSES - 1)
        return 0
    }

    // 2. Fetch wet mix (required) and dry mix (optional, defaults to 1.0)
    wet := f32(lua.L_checknumber(L, 2))
    dry := f32(lua.L_optnumber(L, 3, 1.0))
    //clamp wet/dry
    if wet < 0.0 do wet = 0.0
    if wet > 1.0 do wet = 1.0
    if dry < 0.0 do dry = 0.0
    if dry > 1.0 do dry = 1.0

    // 3. Mutate the active miniaudio node
    ma.delay_node_set_wet(&audio_ctx.mixer[idx].delay, wet)
    ma.delay_node_set_dry(&audio_ctx.mixer[idx].delay, dry)

    return 0
}

// lua_audio_config_bus_delay_times: audio.config_bus_delay_times({ [1] = 0.5, [4] = 2.0 })
lua_audio_config_bus_delay_times :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    if audio_ctx.initialized {
        lua.L_error(L, "audio.config_bus_delay_times: must be called before engine initialization")
        return 0
    }

    // 1. Validate the input is a table
    lua.L_checktype(L, 1, lua.TTABLE)

    // 2. Iterate only over valid sub-buses (Master bus 0 has no delay node)
    for i in 1 ..< MAX_AUDIO_BUSES {
        // Push the integer key we want to look up (e.g., 1, then 2, etc.)
        lua.pushinteger(L, lua.Integer(i))

        // gettable pops the key we just pushed, and pushes the value at table[key]
        // The table is at absolute index 1 on the Lua stack
        lua.gettable(L, 1)

        // 3. Check if the value exists and is a number
        // -1 is the top of the stack (the value we just fetched)
        t := lua.type(L, -1)
        if t == lua.TNUMBER {
            audio_ctx.bus_delay_times[i] = f32(lua.tonumber(L, -1))
        } else if t != lua.TNIL {
            lua.L_error(L, "audio.config_bus_delay_times: expected number or nil for bus %d", i)
            return 0
        }

        // 4. Clean up the stack
        // Pop the value so the stack is perfectly clean for the next loop iteration
        lua.pop(L, 1)
    }
    return 0
}

// lua_audio_pause_bus: audio.pause_bus(bus_idx: int)
lua_audio_pause_bus :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.pause_bus")
    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.pause_bus: invalid bus index %d", idx)
        return 0
    }

    ma.sound_group_stop(&audio_ctx.mixer[idx].group)
    return 0
}

// lua_audio_resume_bus: audio.resume_bus(bus_idx: int)
lua_audio_resume_bus :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.resume_bus")
    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.resume_bus: invalid bus index %d", idx)
        return 0
    }
    ma.sound_group_start(&audio_ctx.mixer[idx].group)
    return 0
}

// lua_audio_stop_bus: audio.stop_bus(bus_idx: int)
lua_audio_stop_bus :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.stop_bus")
    idx := lua.L_checkinteger(L, 1)
    if idx < 0 || idx >= MAX_AUDIO_BUSES {
        lua.L_error(L, "audio.stop_bus: invalid bus index %d", idx)
        return 0
    }

    // 1. Pause the bus DSP immediately to stop audio output
    ma.sound_group_stop(&audio_ctx.mixer[idx].group)

    // 2. Destroy all active voices assigned to this bus to reclaim their pool slots
    for i in 0 ..< MAX_VOICES {
        voice := &audio_ctx.voices[i]
        if voice.active && voice.bus_idx == int(idx) {
            ma.sound_stop(&voice.node)
            ma.sound_uninit(&voice.node)
            voice.active = false
            voice.source_sound = nil // <--- Clear the dangling pointer
        }
    }

    return 0
}

/////////////////

// lua_audio_get_voice_info: audio.get_voice_info(handle) -> time, duration
// Returns nil, nil for a dead or stale voice handle.
lua_audio_get_voice_info :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.get_voice_info")
    handle := u32(lua.L_checkinteger(L, 1))

    voice := get_voice(handle)
    if voice == nil {
        lua.pushnil(L)
        lua.pushnil(L)
        return 2
    }

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
    check_audio_safety(L, "audio.is_voice_playing")
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
    check_audio_safety(L, "audio.stop_all_voices")

    for i in 0 ..< MAX_VOICES {
        voice := &audio_ctx.voices[i]
        if voice.active {
            ma.sound_stop(&voice.node)
            ma.sound_uninit(&voice.node)
            voice.active = false
            voice.source_sound = nil
        }
    }

    return 0
}

// lua_audio_get_sound_info: audio.get_sound_info(sound) -> (path, duration, is_stream)
// Returns nil, nil, nil if the sound has been freed.
lua_audio_get_sound_info :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_audio_safety(L, "audio.get_sound_info")
    sound := cast(^Sound)lua.L_checkudata(L, 1, "Sound")
    if sound == nil || sound.filepath == nil {
        lua.pushnil(L)
        lua.pushnil(L)
        lua.pushnil(L)
        return 3
    }

    duration: f32 = 0.0
    if !sound.is_stream {
        ma.sound_get_length_in_seconds(&sound.cache_ref, &duration)
    }

    lua.pushstring(L, sound.filepath)
    lua.pushnumber(L, lua.Number(duration)) // <--- Fixed Cast
    lua.pushboolean(L, b32(sound.is_stream))

    return 3
}

// =============================================================================
// Memory Management & Metatables
// =============================================================================

// lua_sound_gc is triggered by Lua's GC or manual release().
lua_sound_gc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    sound := cast(^Sound)lua.L_checkudata(L, 1, "Sound")

    if sound != nil && sound.filepath != nil {

        // 1. THE SWEEP: Detach any active voices using this sound's memory
        for i in 0 ..< MAX_VOICES {
            voice := &audio_ctx.voices[i]
            if voice.active && voice.source_sound == sound {
                ma.sound_stop(&voice.node)
                ma.sound_uninit(&voice.node)
                voice.active = false
                voice.source_sound = nil
            }
        }

        // 2. Unpin RAM cache if static
        if !sound.is_stream {
            ma.sound_uninit(&sound.cache_ref)
        }

        // 3. Free the heap-allocated cstring
        delete(sound.filepath)
        sound.filepath = nil
    }

    return 0
}

// setup_audio_metatables initializes the hidden registry tables for audio userdata.
setup_audio_metatables :: proc(L: ^lua.State) {
    lua.L_newmetatable(L, "Sound")
    lua.pushcfunction(L, lua_sound_gc)
    lua.setfield(L, -2, "__gc")
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
    lua.pushcfunction(L, lua_audio_config_bus_delay_times)
    lua.setfield(L, -2, "config_bus_delay_times")

    // --- Global Listener & Defaults ---
    lua.pushcfunction(L, lua_audio_set_listener_position)
    lua.setfield(L, -2, "set_listener_position")
    lua.pushcfunction(L, lua_audio_set_listener_rotation)
    lua.setfield(L, -2, "set_listener_rotation")
    lua.pushcfunction(L, lua_audio_set_listener_velocity)
    lua.setfield(L, -2, "set_listener_velocity")
    lua.pushcfunction(L, lua_audio_set_default_falloff)
    lua.setfield(L, -2, "set_default_falloff")
    lua.pushcfunction(L, lua_audio_set_default_falloff_mode)
    lua.setfield(L, -2, "set_default_falloff_mode")

    // --- Asset Management ---
    lua.pushcfunction(L, lua_audio_load_sound)
    lua.setfield(L, -2, "load_sound")
    lua.pushcfunction(L, lua_audio_get_sound_info)
    lua.setfield(L, -2, "get_sound_info")

    // --- Playback Entry Points ---
    lua.pushcfunction(L, lua_audio_play)
    lua.setfield(L, -2, "play")
    lua.pushcfunction(L, lua_audio_play_at)
    lua.setfield(L, -2, "play_at")

    // --- Instance Control (Common) ---
    lua.pushcfunction(L, lua_audio_set_voice_volume)
    lua.setfield(L, -2, "set_voice_volume")
    lua.pushcfunction(L, lua_audio_set_voice_pitch)
    lua.setfield(L, -2, "set_voice_pitch")
    lua.pushcfunction(L, lua_audio_set_voice_pan)
    lua.setfield(L, -2, "set_voice_pan")
    lua.pushcfunction(L, lua_audio_set_voice_looping)
    lua.setfield(L, -2, "set_voice_looping")
    lua.pushcfunction(L, lua_audio_seek_voice)
    lua.setfield(L, -2, "seek_voice")
    lua.pushcfunction(L, lua_audio_fade_voice)
    lua.setfield(L, -2, "fade_voice")
    lua.pushcfunction(L, lua_audio_get_voice_info)
    lua.setfield(L, -2, "get_voice_info")
    lua.pushcfunction(L, lua_audio_is_voice_playing)
    lua.setfield(L, -2, "is_voice_playing")

    // --- Instance Control (Spatial) ---
    lua.pushcfunction(L, lua_audio_set_voice_position)
    lua.setfield(L, -2, "set_voice_position")
    lua.pushcfunction(L, lua_audio_set_voice_velocity)
    lua.setfield(L, -2, "set_voice_velocity")
    lua.pushcfunction(L, lua_audio_set_voice_falloff)
    lua.setfield(L, -2, "set_voice_falloff")
    lua.pushcfunction(L, lua_audio_set_voice_rolloff)
    lua.setfield(L, -2, "set_voice_rolloff")
    lua.pushcfunction(L, lua_audio_set_voice_falloff_mode)
    lua.setfield(L, -2, "set_voice_falloff_mode")
    lua.pushcfunction(L, lua_audio_set_voice_pan_mode)
    lua.setfield(L, -2, "set_voice_pan_mode")

    // --- Instance Lifecycle ---
    lua.pushcfunction(L, lua_audio_pause_voice)
    lua.setfield(L, -2, "pause_voice")
    lua.pushcfunction(L, lua_audio_resume_voice)
    lua.setfield(L, -2, "resume_voice")
    lua.pushcfunction(L, lua_audio_stop_voice)
    lua.setfield(L, -2, "stop_voice")

    // --- Bus Mixing & DSP ---
    lua.pushcfunction(L, lua_audio_set_bus_volume)
    lua.setfield(L, -2, "set_bus_volume")
    lua.pushcfunction(L, lua_audio_set_bus_pitch)
    lua.setfield(L, -2, "set_bus_pitch")
    lua.pushcfunction(L, lua_audio_set_bus_pan)
    lua.setfield(L, -2, "set_bus_pan")
    lua.pushcfunction(L, lua_audio_fade_bus)
    lua.setfield(L, -2, "fade_bus")
    lua.pushcfunction(L, lua_audio_set_bus_lpf)
    lua.setfield(L, -2, "set_bus_lpf")
    lua.pushcfunction(L, lua_audio_set_bus_hpf)
    lua.setfield(L, -2, "set_bus_hpf")
    lua.pushcfunction(L, lua_audio_set_bus_delay_mix)
    lua.setfield(L, -2, "set_bus_delay_mix")
    lua.pushcfunction(L, lua_audio_set_bus_delay_feedback)
    lua.setfield(L, -2, "set_bus_delay_feedback")
    lua.pushcfunction(L, lua_audio_pause_bus)
    lua.setfield(L, -2, "pause_bus")
    lua.pushcfunction(L, lua_audio_resume_bus)
    lua.setfield(L, -2, "resume_bus")
    lua.pushcfunction(L, lua_audio_stop_bus)
    lua.setfield(L, -2, "stop_bus")

    lua.pushcfunction(L, lua_audio_stop_all_voices)
    lua.setfield(L, -2, "stop_all_voices")

    lua.setglobal(L, "audio")
}
