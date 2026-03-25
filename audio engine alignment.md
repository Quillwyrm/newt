This summary serves as the "Source of Truth" for our audio system architecture. Use it to snap my context back into alignment if I ever drift into "new architecture" hallucinations.

---

## 1. The Component Triad
The system is built on a strict data-oriented separation of concerns:

* **`Sound` (The Asset):** A heavy, Lua-owned **Userdata** object. It represents the raw audio data (PCM) residing in RAM or being streamed from disk.
* **`Track` (The Bus):** A mixing group (`ma.sound_group`). Track 0 is the **Master**. Tracks 1–7 are sub-buses parented to the Master.
* **`Voice` (The Instance):** An ephemeral playback slot in a fixed-size pool (`[32]Voice`). This is where the actual `ma.sound` node lives and breathes.

---

## 2. The "Pinned Cache" Strategy
To ensure "static" sounds stay in RAM without manual buffer management, we use the **Cache-Ref Pattern**:

* **Loading:** When `audio.load_sound(path, "static")` is called, we initialize a "dummy" `ma.sound` inside the `Sound` struct (`cache_ref`) using the `MA_SOUND_FLAG_DECODE` flag.
* **Persistence:** This dummy node is never played; its sole purpose is to tell Miniaudio's Resource Manager: *"Keep this file decoded in RAM as long as this node exists."*
* **Playback:** When a voice is spawned, Miniaudio sees the file is already in the decoded cache (pinned by the `cache_ref`) and points the new voice to that existing memory instantly.

---

## 3. The Voice Pool & Slot Reclamation
To keep the engine minimalist and allocation-free during gameplay:

* **Fixed Size:** We use a global `audio_ctx.voices` array of 32 slots.
* **Voice IDs:** Every `play` call returns a unique integer ID to Lua. This is a "receipt" for future mutation, not a reference to memory.
* **Reclamation (EOL):** In the main engine update, we poll `ma.sound_at_end()`. If true, we set `active = false`, making the slot available for the next sound.

---

## 4. API & Intent-Based Design
The API distinguishes between **Spawning** (Frame 0) and **Updating** (Frame 1+):

* **Spawners:** `play` and `play_at` include trailing optional arguments (volume, pitch, pan, pos). This ensures the sound starts with the correct state on its very first audio buffer (preventing "Frame 0 pops").
* **Setters:** Standard functions like `set_voice_pitch` or `set_voice_position` are for transient changes over time.
* **Implicit Spatialization:** * Calling `set_voice_position` automatically enables spatial mode.
    * Calling `set_voice_pan` automatically disables spatial mode (returning to 2D stereo).
    * An explicit `set_voice_mode(id, "spatial"|"global")` exists as an escape hatch.

---

## 5. Memory Management
We use a unified cleanup paradigm consistent with the rest of the engine:

* **Userland:** Users can call `release(sound)` to free RAM immediately.
* **Automatic:** If the user forgets, Lua's `__gc` metamethod triggers the same cleanup.
* **Implementation:** The `lua_sound_gc` procedure calls `ma.sound_uninit(&sound.cache_ref)`. This releases the "pin" on the decoded RAM, allowing Miniaudio to evict the data.
* **Safety:** We check `if sound.cache_ref != nil` to prevent double-frees between manual `release` and automatic `__gc`.

---

**Next Step:** With the high-level summary locked in, would you like to implement the `load_sound` logic in `api_audio.odin` to handle that `cache_ref` setup?
