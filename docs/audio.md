# audio

The Luagame audio API is a real-time mixing engine built on an 8-bus architecture. It supports 3D spatialization, audio streaming for long-form assets, and per-bus DSP effects.

## System Overview
- **Mixing Buses**: The engine provides 8 buses (0-7). Bus 0 is the **Master Bus** and outputs directly to the hardware. Buses 1-7 are sub-buses that route into Bus 0 and feature a persistent signal chain: Group -> Delay -> HPF -> LPF.
- **Handle Safety**: Playback functions return an integer handle. These handles are unique identifiers; if a sound finishes or its slot is reclaimed by the engine, the handle becomes invalid, ensuring that commands sent to "dead" voices fail safely without affecting new sounds.

## Functions

**Engine Configuration**
* [`config_bus_delay_times`](#config_bus_delay_times)

**Listener & Defaults**
* [`set_listener_position`](#set_listener_position)
* [`set_listener_rotation`](#set_listener_rotation)
* [`set_listener_velocity`](#set_listener_velocity)
* [`set_default_falloff`](#set_default_falloff)
* [`set_default_falloff_mode`](#set_default_falloff_mode)

**Asset Management**
* [`load_sound`](#load_sound)
* [`get_sound_info`](#get_sound_info)

**Playback**
* [`play`](#play)
* [`play_at`](#play_at)

**Voice Control**
* [`set_voice_volume`](#set_voice_volume)
* [`set_voice_pitch`](#set_voice_pitch)
* [`set_voice_pan`](#set_voice_pan)
* [`set_voice_looping`](#set_voice_looping)
* [`seek_voice`](#seek_voice)
* [`fade_voice`](#fade_voice)
* [`get_voice_info`](#get_voice_info)
* [`is_voice_playing`](#is_voice_playing)
* [`set_voice_position`](#set_voice_position)
* [`set_voice_velocity`](#set_voice_velocity)
* [`set_voice_falloff`](#set_voice_falloff)
* [`set_voice_rolloff`](#set_voice_rolloff)
* [`set_voice_falloff_mode`](#set_voice_falloff_mode)
* [`set_voice_pan_mode`](#set_voice_pan_mode)

**Voice Lifecycle**
* [`pause_voice`](#pause_voice)
* [`resume_voice`](#resume_voice)
* [`stop_voice`](#stop_voice)
* [`stop_all_voices`](#stop_all_voices)

**Bus Mixing**
* [`set_bus_volume`](#set_bus_volume)
* [`set_bus_pitch`](#set_bus_pitch)
* [`set_bus_pan`](#set_bus_pan)
* [`fade_bus`](#fade_bus)
* [`set_bus_lpf`](#set_bus_lpf)
* [`set_bus_hpf`](#set_bus_hpf)
* [`set_bus_delay_mix`](#set_bus_delay_mix)
* [`set_bus_delay_feedback`](#set_bus_delay_feedback)
* [`pause_bus`](#pause_bus)
* [`resume_bus`](#resume_bus)
* [`stop_bus`](#stop_bus)

## Engine Configuration

### config_bus_delay_times

Configures the buffer length (echo time) for sub-bus delay nodes. This must be called **before** the engine initializes.

#### Usage

```lua
audio.config_bus_delay_times(config)
```

#### Arguments

* `table: config` - A table mapping bus indices (1-7) to delay times in seconds (e.g., `{ [1] = 0.5, [4] = 2.0 }`).

---

## Listener & Defaults

### set_listener_position

Sets the world-space position of the virtual listener.

#### Usage

```lua
audio.set_listener_position(x, y)
```

#### Arguments

* `number: x` - X coordinate.
* `number: y` - Y coordinate.

---

### set_listener_rotation

Sets the orientation of the listener in degrees.

#### Usage

```lua
audio.set_listener_rotation(degrees)
```

#### Arguments

* `number: degrees` - Rotation angle.

---

### set_listener_velocity

Sets the velocity of the listener for Doppler effect calculations.

#### Usage

```lua
audio.set_listener_velocity(vx, vy)
```

#### Arguments

* `number: vx` - Velocity on the X axis.
* `number: vy` - Velocity on the Y axis.

---

### set_default_falloff

Sets the global default inner and outer radii for all future 3D playback calls.

#### Usage

```lua
audio.set_default_falloff(min_px, max_px?)
```

#### Arguments

* `number: min_px` - The distance at which volume begins to attenuate.
* `number: max_px` (Optional) - The distance at which the sound becomes silent.

---

### set_default_falloff_mode

Sets the default attenuation curve for future 3D playback calls.

#### Usage

```lua
audio.set_default_falloff_mode(mode)
```

#### Arguments

* `string: mode` - The curve type: `"none"`, `"inverse"`, `"linear"`, or `"exponential"`.

---

## Asset Management

### load_sound

Loads an audio file into memory as a reusable asset.

#### Usage

```lua
sound = audio.load_sound(filepath, mode?)
```

#### Arguments

* `string: filepath` - Path to the audio file.
* `string: mode` (Optional) - `"static"` (fully decoded into RAM, default) or `"stream"` (decoded on the fly).

#### Returns

* `userdata: sound` - A handle to the sound asset.

---

### get_sound_info

Returns metadata for a loaded sound asset.

#### Usage

```lua
path, duration, is_stream = audio.get_sound_info(sound)
```

#### Arguments

* `userdata: sound` - The sound asset to inspect.

#### Returns

* `string: path` - The source file path.
* `number: duration` - Length in seconds (0.0 for streams).
* `boolean: is_stream` - `true` if the asset is streaming.

---

## Playback

### play

Starts 2D (non-spatialized) playback of a sound.

#### Usage

```lua
handle = audio.play(sound, bus, vol?, pitch?, pan?)
```

#### Arguments

* `userdata: sound` - The sound asset to play.
* `number: bus` - The target bus index (0-7).
* `number: vol` (Optional) - Initial volume (default 1.0).
* `number: pitch` (Optional) - Initial pitch (default 1.0).
* `number: pan` (Optional) - Initial stereo pan (default 0.0).

#### Returns

* `number: handle` - A unique identifier for the playing voice.

---

### play_at

Starts 3D (spatialized) playback of a sound at a world position.

#### Usage

```lua
handle = audio.play_at(sound, bus, x, y, vol?, pitch?)
```

#### Arguments

* `userdata: sound` - The sound asset to play.
* `number: bus` - The target bus index (0-7).
* `number: x`, `number: y` - World coordinates.
* `number: vol` (Optional) - Initial volume.
* `number: pitch` (Optional) - Initial pitch.

#### Returns

* `number: handle` - A unique identifier for the playing voice.

---

## Voice Control

### set_voice_volume

Sets the volume of an active voice.

#### Usage

```lua
audio.set_voice_volume(handle, volume)
```

#### Arguments

* `number: handle` - The voice identifier.
* `number: volume` - New volume level.

---

### set_voice_pitch

Sets the playback speed of an active voice.

#### Usage

```lua
audio.set_voice_pitch(handle, pitch)
```

#### Arguments

* `number: handle` - The voice identifier.
* `number: pitch` - New pitch multiplier.

---

### set_voice_pan

Sets the stereo panning for an active voice. Calling this disables spatialization for the voice.

#### Usage

```lua
audio.set_voice_pan(handle, pan)
```

#### Arguments

* `number: handle` - The voice identifier.
* `number: pan` - Panning value (-1.0 to 1.0).

---

### set_voice_looping

Enables or disables looping for an active voice.

#### Usage

```lua
audio.set_voice_looping(handle, is_looping)
```

#### Arguments

* `number: handle` - The voice identifier.
* `boolean: is_looping` - `true` to loop.

---

### seek_voice

Seeks to a specific position within a voice's audio data.

#### Usage

```lua
audio.seek_voice(handle, offset, unit?)
```

#### Arguments

* `number: handle` - The voice identifier.
* `number: offset` - The target position.
* `string: unit` (Optional) - `"seconds"` (default) or `"samples"`.

---

### fade_voice

Smoothly transitions a voice's volume over a duration.

#### Usage

```lua
audio.fade_voice(handle, target_volume, duration)
```

#### Arguments

* `number: handle` - The voice identifier.
* `number: target_volume` - Destination volume level.
* `number: duration` - Time in seconds.

---

### get_voice_info

Returns the current playback state of a voice.

#### Usage

```lua
time, duration = audio.get_voice_info(handle)
```

#### Arguments

* `number: handle` - The voice identifier.

#### Returns

* `number: time` - Current playback position in seconds.
* `number: duration` - Total length of the sound in seconds.
* On failure (dead voice): `nil, nil`

---

### is_voice_playing

Checks if a voice is currently active and not paused.

#### Usage

```lua
playing = audio.is_voice_playing(handle)
```

#### Arguments

* `number: handle` - The voice identifier.

#### Returns

* `boolean: playing` - `true` if active.

---

### set_voice_position

Sets the world-space position of an active voice and enables spatialization.

#### Usage

```lua
audio.set_voice_position(handle, x, y)
```

#### Arguments

* `number: handle` - The voice identifier.
* `number: x`, `number: y` - World coordinates.

---

### set_voice_velocity

Sets the velocity of a voice for Doppler effect calculations.

#### Usage

```lua
audio.set_voice_velocity(handle, vx, vy)
```

#### Arguments

* `number: handle` - The voice identifier.
* `number: vx`, `number: vy` - Velocity components.

---

### set_voice_falloff

Sets the attenuation radii for a specific voice.

#### Usage

```lua
audio.set_voice_falloff(handle, min_px, max_px?)
```

#### Arguments

* `number: handle` - The voice identifier.
* `number: min_px` - Inner radius.
* `number: max_px` (Optional) - Outer radius.

---

### set_voice_rolloff

Sets the rolloff factor (intensity of the falloff) for a specific voice.

#### Usage

```lua
audio.set_voice_rolloff(handle, factor)
```

#### Arguments

* `number: handle` - The voice identifier.
* `number: factor` - Rolloff multiplier.

---

### set_voice_falloff_mode

Sets the attenuation curve for a specific voice.

#### Usage

```lua
audio.set_voice_falloff_mode(handle, mode)
```

#### Arguments

* `number: handle` - The voice identifier.
* `string: mode` - `"none"`, `"inverse"`, `"linear"`, or `"exponential"`.

---

### set_voice_pan_mode

Sets the panning calculation mode for a voice.

#### Usage

```lua
audio.set_voice_pan_mode(handle, mode)
```

#### Arguments

* `number: handle` - The voice identifier.
* `string: mode` - `"balance"` (default) or `"pan"`.

---

## Voice Lifecycle

### pause_voice

Pauses playback of a voice.

#### Usage

```lua
audio.pause_voice(handle)
```

#### Arguments

* `number: handle` - The voice identifier.

---

### resume_voice

Resumes playback of a paused voice.

#### Usage

```lua
audio.resume_voice(handle)
```

#### Arguments

* `number: handle` - The voice identifier.

---

### stop_voice

Immediately halts a voice and reclaims its slot.

#### Usage

```lua
audio.stop_voice(handle)
```

#### Arguments

* `number: handle` - The voice identifier.

---

### stop_all_voices

Immediately halts and destroys all active voices across the entire engine.

#### Usage

```lua
audio.stop_all_voices()
```

---

## Bus Mixing

### set_bus_volume

Sets the volume for an entire mixing bus.

#### Usage

```lua
audio.set_bus_volume(bus, volume)
```

#### Arguments

* `number: bus` - Bus index (0-7).
* `number: volume` - New volume level.

---

### set_bus_pitch

Sets the playback speed for an entire mixing bus.

#### Usage

```lua
audio.set_bus_pitch(bus, pitch)
```

#### Arguments

* `number: bus` - Bus index (0-7).
* `number: pitch` - New pitch multiplier.

---

### set_bus_pan

Sets the stereo panning for an entire mixing bus.

#### Usage

```lua
audio.set_bus_pan(bus, pan)
```

#### Arguments

* `number: bus` - Bus index (0-7).
* `number: pan` - Panning value (-1.0 to 1.0).

---

### fade_bus

Smoothly transitions a bus's volume over a duration.

#### Usage

```lua
audio.fade_bus(bus, target_volume, duration)
```

#### Arguments

* `number: bus` - Bus index (0-7).
* `number: target_volume` - Destination volume.
* `number: duration` - Time in seconds.

---

### set_bus_lpf

Sets the Low-Pass Filter cutoff for a sub-bus (1-7).

#### Usage

```lua
audio.set_bus_lpf(bus, hz)
```

#### Arguments

* `number: bus` - Bus index (1-7).
* `number: hz` - Frequency cutoff (Range: 10-22000).

---

### set_bus_hpf

Sets the High-Pass Filter cutoff for a sub-bus (1-7).

#### Usage

```lua
audio.set_bus_hpf(bus, hz)
```

#### Arguments

* `number: bus` - Bus index (1-7).
* `number: hz` - Frequency cutoff (Range: 10-22000).

---

### set_bus_delay_mix

Sets the wet/dry balance for the delay effect on a sub-bus (1-7).

#### Usage

```lua
audio.set_bus_delay_mix(bus, wet, dry?)
```

#### Arguments

* `number: bus` - Bus index (1-7).
* `number: wet` - Level of processed (echo) signal.
* `number: dry` (Optional) - Level of original signal (default 1.0).

---

### set_bus_delay_feedback

Sets the feedback (echo tail intensity) for the delay effect on a sub-bus (1-7).

#### Usage

```lua
audio.set_bus_delay_feedback(bus, amount)
```

#### Arguments

* `number: bus` - Bus index (1-7).
* `number: amount` - Feedback level (Range: 0.0 to 1.0).

---

### pause_bus

Pauses all audio output from a bus.

#### Usage

```lua
audio.pause_bus(bus)
```

#### Arguments

* `number: bus` - Bus index (0-7).

---

### resume_bus

Resumes audio output for a paused bus.

#### Usage

```lua
audio.resume_bus(bus)
```

#### Arguments

* `number: bus` - Bus index (0-7).

---

### stop_bus

Halts a bus and immediately destroys all voices assigned to it.

#### Usage

```lua
audio.stop_bus(bus)
```

#### Arguments

* `number: bus` - Bus index (0-7).