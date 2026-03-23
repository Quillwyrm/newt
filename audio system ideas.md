Here is the architectural summary for the Luagame audio system.

### The Core Architecture

**1. Memory Paradigms (Static vs. Stream)**
The API abstracts file extensions (WAV, MP3, OGG, FLAC) away from the user. Instead, the user explicitly dictates the memory footprint at load time:
* **Static:** Decodes the entire compressed file into a raw PCM buffer in RAM. Costs high RAM, but zero CPU to play. Allows massive polyphony (50 overlapping explosions).
* **Stream:** Decodes tiny 4KB chunks from the disk on the fly. Costs negligible RAM, but requires continuous CPU. Used for BGM and long ambience loops where only one instance plays at a time.

**2. Generic Channels**
The engine provides generic integer `channel_id` slots instead of hardcoded string buses (like `"sfx"` or `"music"`). The Odin backend maintains an array of `Channel` structs that act as mixer nodes. Lua userland defines the semantic meaning of these channels, giving the developer complete flexibility over their audio routing.

### The Miniaudio Advantage

`vendor:miniaudio` makes this architecture extremely lightweight on the C-boundary:
* **Unified Poly-Struct:** The `ma_sound` struct is fixed-size. Miniaudio dynamically allocates either a massive PCM buffer (Static) or a tiny ring buffer (Stream) on the heap behind the scenes. Your Odin `Audio_Source` struct remains a few bytes.
* **Zero-Branch Playback:** You pass `MA_SOUND_FLAG_DECODE` or `MA_SOUND_FLAG_STREAM` during initialization. During `play()`, you just call `ma_sound_start()`. Miniaudio handles the routing natively; your playback functions require zero `if/else` checks for the memory type.
* **Built-in Decoders:** It handles WAV, MP3, OGG, and FLAC natively without requiring external C libraries.

### The MVP Lua API

```lua
-- mode must be "static" (RAM) or "stream" (Disk)
audio.load(path: string, mode: string) -> Sound 
```

**2. Playback & Instances (The Voice)**
Transient events that pull from the Odin Voice Pool.

```lua
-- volume and pitch are optional multipliers, defaulting to 1.0. Returns a Voice ID.
audio.play(sound: Sound, track_id: int, volume?: number, pitch?: number) -> int

-- Halts a specific playback instance without affecting the rest of the track
audio.stop_voice(voice_id: int) 
```

**3. Routing & State (The Track)**
Mixing buses that affect all active Voices routed through them. `track_id 0` is hardcoded as the Master track.

```lua
audio.set_track_volume(track_id: int, volume: number)
audio.fade_track(track_id: int, target_volume: number, duration_in_seconds: number)

audio.stop_track(track_id: int)   -- Halts and rewinds all Voices on track
audio.pause_track(track_id: int)  -- Freezes all Voices on track
audio.resume_track(track_id: int) -- Unfreezes all Voices on track
```

Ready when you are.
### Odin Backend Snapshot

To support the fading math and mixing, the internal Odin state looks roughly like this:

```odin
// The userdata handle returned to Lua
Audio_Source :: struct {
    sound: miniaudio.sound,
}

// The internal mixer nodes
Channel :: struct {
    group:          miniaudio.sound_group, 
    current_volume: f32,
    target_volume:  f32,
    fade_speed:     f32, // Calculated from duration when fade_channel is called
}
```
In your `update()` loop, you step the `current_volume` toward the `target_volume` based on delta time and push it to the `ma_sound_group`.

