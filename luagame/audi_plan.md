Here is a phased implementation plan for `api_audio.odin`, designed so you can verify the systems logic at every step before moving to the next layer of complexity.

### Phase 1: Engine Initialization
**Goal:** Spin up the `miniaudio` backend and bridge it to your main game loop.
* **Tasks:**
    * Import `vendor:miniaudio`.
    * Define global state variables for the audio system (e.g., `g_audio_engine: miniaudio.engine`).
    * Write `audio_init()` and `audio_quit()` procedures.
    * Hook them into your engine's main boot and shutdown sequences.
* **Definition of Done:** The engine compiles, launches, and closes without any segmentation faults or miniaudio initialization errors in the console.

### Phase 2: Asset Loading (Static)
**Goal:** Read an audio file from the disk into a miniaudio memory buffer via Lua.
* **Tasks:**
    * Define the `Audio_Source` userdata struct (containing the `ma_sound`).
    * Write the `lua_audio_load` binding. For now, hardcode it to only support `MA_SOUND_FLAG_DECODE` (static loading).
    * Write the `__gc` metamethod to call `ma_sound_uninit` when Lua drops the handle.
    * Register the `audio` table in your Lua state setup.
* **Definition of Done:** In `main.lua`, calling `local sfx = audio.load("test.ogg", "static")` successfully executes, and exiting the game triggers the `__gc` cleanup without crashing.

### Phase 3: The Voice Pool & Fire-and-Forget Playback
**Goal:** Prove the hardware output and polyphony work.
* **Tasks:**
    * Define a fixed-size array of `ma_sound` nodes in Odin (e.g., 32 voices). 
    * Initialize these voices against `g_audio_engine` during `audio_init()`.
    * Write `lua_audio_play`. It should search the array for a voice that is not currently playing (`ma_sound_is_playing`), point it at the `Audio_Source` data, and call `ma_sound_start`.
    * Ignore Track routing for now; just attach them all directly to the engine master.
* **Definition of Done:** Calling `audio.play(sfx)` in Lua makes noise out of the speakers. Calling it in a `for` loop 10 times plays 10 overlapping sounds perfectly.

### Phase 4: Track Routing & State
**Goal:** Implement the mixing buses.
* **Tasks:**
    * Define a fixed-size array of `ma_sound_group` nodes in Odin (e.g., 8 tracks).
    * Initialize them in `audio_init()`. Track 0 parented to the engine, Tracks 1-7 parented to Track 0.
    * Modify `lua_audio_play` to read the `track_id` argument and call `ma_sound_set_spatialization_enabled(false)` and `ma_sound_set_pinned_listener_index(...)` or the equivalent routing function to connect the Voice to the `ma_sound_group`.
    * Implement `lua_audio_set_track_volume`.
* **Definition of Done:** You can play a sound on Track 1, call `audio.set_track_volume(1, 0.0)`, and the sound instantly mutes, but a sound playing on Track 2 remains audible.

### Phase 5: Streaming & Transient Overrides
**Goal:** Finalize the MVP API surface.
* **Tasks:**
    * Update `lua_audio_load` to branch on the `"stream"` string and pass `MA_SOUND_FLAG_STREAM`.
    * Update `lua_audio_play` to parse the optional volume and pitch multipliers and apply them to the selected Voice before starting it.
    * Implement `stop/pause/resume_track` bindings.
    * (Optional) Implement the fading logic in your main `update()` loop.
* **Definition of Done:** You can load a 3-minute BGM as a stream, play it with a pitch modifier of 0.8, and pause the entire track on command.

The MVP API you designed is exceptionally clean. It maps directly 1:1 with Miniaudio’s internal architecture. 

To clarify your question about `cache_ref` and `audio_init`: 
Your `audio_init` procedure is actually **perfect exactly as it is**. It sets up the global hardware, the mixing graph (Tracks), and the empty Voice pool. It should *never* know about `cache_ref`. 

The `cache_ref` initialization happens entirely inside your `audio.load` function. When a user calls `load("laser.wav", "static")`, your Odin backend initializes that specific `Sound.cache_ref` node with the `{.DECODE}` flag using the filepath. Miniaudio's background resource manager sees that flag, hits the disk, and dumps the uncompressed audio into RAM. 

Here is the evaluation of your API and the high-level roadmap to build it.

---

### 1. Asset Management (`audio.load`)
**Viability: 100%**
* **Odin Side:** You will create a `lua_audio_load` binding. It will use `lua.newuserdata` to allocate the `Sound` struct, clone the `path` string, and initialize the `cache_ref` if the mode is "static". 
* **GC:** You will need a `__gc` metamethod (just like your `Image_Meta`) that calls `ma.sound_uninit(&sound.cache_ref)` and `delete(sound.filepath)`. Miniaudio handles dumping the RAM.

### 2. Emitter Management (`audio.play` & `audio.stop_voice`)
**Viability: 100%**
* **The Pool Search:** When `audio.play` is called, loop `audio_ctx.voices` to find an index where `active == false`. 
* **The Init:** You initialize that Voice's `ma.sound` node using the `Sound`'s filepath string, but you pass the requested Track's `ma.sound_group` pointer as the parent node. 
* **The ID:** You return the integer index (e.g., `5`) of that voice to Lua as the `voice_id`.
* **The Stop:** `audio.stop_voice(5)` simply calls `ma.sound_stop()` and `ma.sound_uninit()` on `audio_ctx.voices[5]`, then sets `active = false`. 
* *Edge Case to handle:* What happens if all 32 voices are active? (Usually, you either ignore the play call or forcibly stop the oldest voice).

### 3. Mixing Graph (`audio.set_track_volume`, etc.)
**Viability: 100% natively supported.**
* Miniaudio's `ma.sound_group` handles routing automatically. If you call `ma.sound_group_stop(&audio_ctx.tracks[id].group)`, it instantly halts every Voice routed through it. Same for pause and resume. 
* **Fading:** Miniaudio has native fading, but since you have `current_volume`, `target_volume`, and `fade_speed` in your `Track` struct, you can just update those values from Lua, and calculate the lerp in your engine's main loop, applying it via `ma.sound_group_set_volume`.

### High-Level Implementation Steps:
1.  **The Loader:** Write the `audio.load` Lua binding and the `Sound_Meta` garbage collector to get memory pinning working.
2.  **The Player:** Write `audio.play`. This involves scanning the 32-slot array, initializing the node, and attaching it to `tracks[track_id]`.
3.  **The Tick:** Add a small `audio_update(dt: f32)` procedure to be called in your main loop. This will scan the 32 voices: if a voice has naturally finished playing (`ma.sound_at_end`), it needs to be uninitialized and marked `active = false` so the slot opens up again.
4.  **The Track API:** Expose the track controls to Lua.

Where do you want to start writing the Odin logic? The loader, or the playback/pool-scanning logic?

1. What Miniaudio Supports Natively (High-Level)

Since you are using ma.engine and ma.sound_group (Tracks), you get the following with almost zero architectural overhead:

    Spatialization: Full 2D and 3D positioning. You set a listener position, give a Voice an X/Y coordinate, and Miniaudio handles the panning and distance attenuation automatically.

    Pitch Shifting: You can alter the pitch/speed of a Voice or an entire Track on the fly.

    Basic Filtering: Low-pass (LPF) and high-pass (HPF) filters are natively supported on both individual sounds and groups.
