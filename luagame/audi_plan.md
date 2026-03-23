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


