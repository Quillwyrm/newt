package main

import "core:fmt"
import ma "vendor:miniaudio"

// =============================================================================
// Audio Data Structures
// =============================================================================

// Sound represents a loadable audio asset.
Sound :: struct {
  filepath:  string,
  is_stream: bool,
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
  tracks: [8]Track,
  voices: [32]Voice,
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
  for i in 0..<32 {
    audio_ctx.voices[i].active = false
  }

  return true
}

// audio_shutdown uninitializes all active voices, tracks, and the miniaudio engine.
// Must be called on application shutdown.
audio_shutdown :: proc() {
  // Clean up any voices that are currently playing
  for i in 0..<32 {
    if audio_ctx.voices[i].active {
      ma.sound_uninit(&audio_ctx.voices[i].node)
    }
  }

  // Uninitialize tracks in reverse order of creation (children before master)
  for i := 7; i >= 0; i -= 1 {
    ma.sound_group_uninit(&audio_ctx.tracks[i].group)
  }

  // Kill the engine
  ma.engine_uninit(&audio_ctx.engine)
}
