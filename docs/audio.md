# audio

The `audio` module provides sound loading, playback, spatialization, and bus mixing across 8 buses.  
Bus `0` is the master bus. Playback functions return integer voice handles. Query behavior for freed sounds and dead voice handles is documented below.

## Functions

**Engine Configuration**
* [`config_bus_delay_times`](#config_bus_delay_times)

**Listener & Defaults**
* [`set_listener_position`](#set_listener_position)
* [`set_listener_rotation`](#set_listener_rotation)
* [`set_listener_velocity`](#set_listener_velocity)
* [`set_default_falloff`](#set_default_falloff)
* [`set_default_falloff_mode`](#set_default_falloff_mode)

**Sounds**
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

**Voice Spatialization**
* [`set_voice_position`](#set_voice_position)
* [`set_voice_velocity`](#set_voice_velocity)
* [`set_voice_falloff`](#set_voice_falloff)
* [`set_voice_falloff_intensity`](#set_voice_falloff_intensity)
* [`set_voice_falloff_mode`](#set_voice_falloff_mode)
* [`set_voice_pan_mode`](#set_voice_pan_mode)

**Voice Lifecycle**
* [`pause_voice`](#pause_voice)
* [`resume_voice`](#resume_voice)
* [`stop_voice`](#stop_voice)
* [`stop_all_voices`](#stop_all_voices)

**Bus Control**
* [`set_bus_volume`](#set_bus_volume)
* [`set_bus_pitch`](#set_bus_pitch)
* [`set_bus_pan`](#set_bus_pan)
* [`fade_bus`](#fade_bus)
* [`pause_bus`](#pause_bus)
* [`resume_bus`](#resume_bus)
* [`stop_bus`](#stop_bus)

**Bus Effects**
* [`set_bus_lpf`](#set_bus_lpf)
* [`set_bus_hpf`](#set_bus_hpf)
* [`set_bus_delay_mix`](#set_bus_delay_mix)
* [`set_bus_delay_feedback`](#set_bus_delay_feedback)

## Engine Configuration

### config_bus_delay_times

Configures delay buffer lengths for buses `1` through `7`. `config` is a table keyed by bus index, where each value is a delay time in seconds.  
Call this before engine initialization. Only entries for buses `1` through `7` are read. `nil` keeps the default delay time for that bus.

```lua
audio.config_bus_delay_times(config)

-- example
audio.config_bus_delay_times({
    [1] = 0.5, -- bus 1
    [4] = 2.0, -- bus 4
})
```

#### Error Cases

- Must be called before engine initialization.
- `config` must be a table.
- Values for buses `1` through `7` must be positive numbers or `nil`.

## Listener & Defaults

### set_listener_position

Sets the world-space position of the listener.

```lua
audio.set_listener_position(x, y)
```

---

### set_listener_rotation

Sets the listener rotation in degrees.

```lua
audio.set_listener_rotation(degrees)
```

---

### set_listener_velocity

Sets the listener velocity for Doppler calculations.

```lua
audio.set_listener_velocity(vx, vy)
```

---

### set_default_falloff

Sets the default falloff distances used by future `audio.play_at()` calls. Negative distances are treated as `0`. If `max_px` is provided and is less than `min_px`, it is treated as `min_px`.

```lua
audio.set_default_falloff(min_px, max_px?)
```

---

### set_default_falloff_mode

Sets the default falloff mode used by future `audio.play_at()` calls.

```lua
audio.set_default_falloff_mode(mode)
```

#### Error Cases

- `mode` must be `"none"`, `"inverse"`, `"linear"`, or `"exponential"`.

## Sounds

### load_sound

Loads a sound asset from a file. `mode` may be `"static"` or `"stream"`. Static sounds are decoded into memory. Streamed sounds are decoded on demand.

```lua
audio.load_sound(filepath, mode?) -> sound | nil, err
```

#### Returns

`sound` is `Sound` type userdata.

#### Error Cases

- `mode` must be `"static"` or `"stream"`.

---

### get_sound_info

Returns metadata for a sound asset.

```lua
audio.get_sound_info(sound) -> path, duration, is_stream | nil, nil, nil
```

#### Returns

Returns `path`, `duration`, and `is_stream` for a live sound.  
Returns `nil, nil, nil` if `sound` has been freed.

`duration` is in seconds. Streamed sounds return `0.0` for duration.

## Playback

### play

Starts non-spatialized playback of a sound on a bus. `volume`, `pitch`, and `pan` set the initial state of the new voice.  
Negative `volume` is treated as `0`. `pitch` must be greater than `0`. `pan` is clamped to `-1.0` through `1.0`.

```lua
audio.play(sound, bus, volume?, pitch?, pan?) -> handle | nil, err
```

#### Returns

Returns a voice handle on success, or `nil, err` if playback could not start.

#### Error Cases

- `bus` must be between `0` and `7`.
- `pitch` must be greater than `0`.

---

### play_at

Starts spatialized playback of a sound at a world position on a bus. `volume` and `pitch` set the initial state of the new voice. Negative `volume` is treated as `0`. `pitch` must be greater than `0`. This uses the current default falloff settings.

```lua
audio.play_at(sound, bus, x, y, volume?, pitch?) -> handle | nil, err
```

#### Returns

Returns a voice handle on success, or `nil, err` if playback could not start.

#### Error Cases

- `bus` must be between `0` and `7`.
- `pitch` must be greater than `0`.

## Voice Control

Unless noted otherwise, functions in this section ignore dead voice handles.

### set_voice_volume

Sets the volume of a voice. Negative values are treated as `0`.

```lua
audio.set_voice_volume(handle, volume)
```

---

### set_voice_pitch

Sets the pitch of a voice.

```lua
audio.set_voice_pitch(handle, pitch)
```

#### Error Cases

- `pitch` must be greater than `0`.

---

### set_voice_pan

Sets the stereo pan of a voice. This disables spatialization for that voice. `pan` is clamped to `-1.0` through `1.0`.

```lua
audio.set_voice_pan(handle, pan)
```

---

### set_voice_looping

Enables or disables looping for a voice.

```lua
audio.set_voice_looping(handle, is_looping)
```

---

### seek_voice

Seeks within a voice. Negative offsets are clamped to `0`.

```lua
audio.seek_voice(handle, offset, unit?)
```

#### Error Cases

- `unit` must be `"seconds"` or `"samples"`.

---

### fade_voice

Fades a voice to a target volume over a duration in seconds. Negative `target_volume` is treated as `0`. Negative `duration` is treated as `0`.

```lua
audio.fade_voice(handle, target_volume, duration)
```

---

### get_voice_info

Returns the current playback position and total duration of a voice.

```lua
audio.get_voice_info(handle) -> time, duration | nil, nil
```

#### Returns

Returns `time` and `duration` in seconds for a live voice.  
Returns `nil, nil` for a dead voice handle.

---

### is_voice_playing

Returns whether a voice is currently playing. Paused, finished, or dead voices return `false`.

```lua
audio.is_voice_playing(handle) -> bool
```

## Voice Spatialization

Unless noted otherwise, functions in this section ignore dead voice handles.

### set_voice_position

Sets the world-space position of a voice. This enables spatialization for that voice.

```lua
audio.set_voice_position(handle, x, y)
```

---

### set_voice_velocity

Sets the velocity of a voice for Doppler calculations.

```lua
audio.set_voice_velocity(handle, vx, vy)
```

---

### set_voice_falloff

Sets the falloff distances for a voice. Negative distances are treated as `0`. If `max_px` is provided and is less than `min_px`, it is treated as `min_px`.

```lua
audio.set_voice_falloff(handle, min_px, max_px?)
```

---

### set_voice_falloff_intensity

Sets the falloff intensity for a voice. Negative values are treated as `0`.

```lua
audio.set_voice_falloff_intensity(handle, factor)
```

---

### set_voice_falloff_mode

Sets the falloff mode for a voice.

```lua
audio.set_voice_falloff_mode(handle, mode)
```

#### Error Cases

- `mode` must be `"none"`, `"inverse"`, `"linear"`, or `"exponential"`.

---

### set_voice_pan_mode

Sets the pan mode for a voice.

```lua
audio.set_voice_pan_mode(handle, mode)
```

#### Error Cases

- `mode` must be `"balance"` or `"pan"`.

## Voice Lifecycle

These functions ignore dead voice handles.

### pause_voice

Pauses a voice.

```lua
audio.pause_voice(handle)
```

---

### resume_voice

Resumes a paused voice.

```lua
audio.resume_voice(handle)
```

---

### stop_voice

Stops a voice and releases its slot.

```lua
audio.stop_voice(handle)
```

---

### stop_all_voices

Stops all active voices and releases their slots.

```lua
audio.stop_all_voices()
```

## Bus Control

These functions apply to buses `0` through `7`. Bus `0` is the master bus.

### set_bus_volume

Sets the volume of a bus. Negative values are treated as `0`.

```lua
audio.set_bus_volume(bus, volume)
```

#### Error Cases

- `bus` must be between `0` and `7`.

---

### set_bus_pitch

Sets the pitch of a bus.

```lua
audio.set_bus_pitch(bus, pitch)
```

#### Error Cases

- `bus` must be between `0` and `7`.
- `pitch` must be greater than `0`.

---

### set_bus_pan

Sets the stereo pan of a bus. `pan` is clamped to `-1.0` through `1.0`.

```lua
audio.set_bus_pan(bus, pan)
```

#### Error Cases

- `bus` must be between `0` and `7`.

---

### fade_bus

Fades a bus to a target volume over a duration in seconds. Negative `target_volume` is treated as `0`. Negative `duration` is treated as `0`.

```lua
audio.fade_bus(bus, target_volume, duration)
```

#### Error Cases

- `bus` must be between `0` and `7`.

---

### pause_bus

Pauses a bus.

```lua
audio.pause_bus(bus)
```

#### Error Cases

- `bus` must be between `0` and `7`.

---

### resume_bus

Resumes a paused bus.

```lua
audio.resume_bus(bus)
```

#### Error Cases

- `bus` must be between `0` and `7`.

---

### stop_bus

Stops a bus and destroys all active voices assigned to it.

```lua
audio.stop_bus(bus)
```

#### Error Cases

- `bus` must be between `0` and `7`.

## Bus Effects

These functions apply only to buses `1` through `7`.

### set_bus_lpf

Sets the low-pass filter cutoff for a bus. Cutoff values are clamped to `10` through `22000`.

```lua
audio.set_bus_lpf(bus, hz)
```

#### Error Cases

- `bus` must be between `1` and `7`.

---

### set_bus_hpf

Sets the high-pass filter cutoff for a bus. Cutoff values are clamped to `10` through `22000`.

```lua
audio.set_bus_hpf(bus, hz)
```

#### Error Cases

- `bus` must be between `1` and `7`.

---

### set_bus_delay_mix

Sets the delay wet and dry mix for a bus. `wet` and `dry` are clamped to `0.0` through `1.0`.

```lua
audio.set_bus_delay_mix(bus, wet, dry?)
```

#### Error Cases

- `bus` must be between `1` and `7`.

---

### set_bus_delay_feedback

Sets the delay feedback amount for a bus. Values are clamped to `0.0` through `1.0`.

```lua
audio.set_bus_delay_feedback(bus, amount)
```

#### Error Cases

- `bus` must be between `1` and `7`.