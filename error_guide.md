# Luagame Error Handling Policy

## Core Rule

If Lua called it, Lua should receive the failure.

Use Odin-side stderr / host-only errors only when no Lua call boundary exists:
- before Lua is initialized
- during fatal host boot/teardown

---

## Failure Classes

### 1. Contract Errors
The caller used the API incorrectly.

Examples:
- wrong argument count
- wrong argument type
- wrong userdata type
- unknown enum/token
- structurally invalid operation

Response:
- raise `lua.L_error(...)`

---

### 2. System State Errors
The subsystem is not usable at all.

Examples:
- graphics used before `window.init()`
- window getters before window creation
- audio API used before audio init

Response:
- raise `lua.L_error(...)`

---

### 3. Runtime / Backend Failures
The request was valid, but the OS, filesystem, decoder, driver, or backend failed.

Examples:
- failed file decode
- failed texture/canvas allocation
- failed file write
- failed audio voice/source init

Response:
- return `nil, err` or `false, err`

Rules:
- lead with the Luagame API name
- backend detail is supporting context, not the headline

Preferred style:
- `graphics.load_image: failed to decode image: ...`
- `audio.play: failed to initialize streaming voice from 'bgm.ogg': ...`
- `window.init: failed to create renderer: ...`

required asset loads may still be treated as fatal by the Lua app layer via `if not x then error(err) end`.

---

### 4. Dead Resources / Dead Handles
The value is the right kind, but the underlying resource is gone.

Examples:
- freed image
- freed pixelmap
- freed sound
- stale voice handle

Response depends on operation kind:

#### Draw / Mutate / Update
- silent no-op

#### Query
- return falsey (`nil`, `nil, nil`, or `false`) consistently

#### Source-Dependent Construction
- return `nil, err`

Examples:
- `graphics.new_image_from_pixelmap(dead_pmap)` -> `nil, err`
- `graphics.pixelmap_clone(dead_pmap)` -> `nil, err`

---

### 5. Normal Misses
Nothing failed. The operation simply had no meaningful result.

Examples:
- out-of-bounds write
- fully clipped region
- raycast miss
- no clip rect active

Response:
- no-op or falsey result, depending on the API

These are not errors.

---

## Special Rules

### Bad tokens are always loud
Unknown mode/filter/blend/unit strings must raise `lua.L_error(...)`.

Do not silently fall back on typos.

### Dead graphics resources are soft
Freed image/pixelmap usage should not usually explode.

- draw/update/mutate -> no-op
- query -> falsey
- source-dependent creation -> `nil, err`

### Audio playback is structured
`play` / `play_at` are runtime request APIs.

- success -> handle
- failure -> `nil, err`

### No stderr from Lua-facing API code
Do not print from Lua API functions.
Surface failure through Lua.

---

## Message Style

Prefer:
- `module.function: explanation`
- `module.function: explanation: backend detail`

Avoid:
- raw backend function names as the headline
- vague messages without Luagame context
- implementation-detail wording like `Renderer is nil`

Good:
- `graphics.set_canvas: image is not a render target`
- `audio.play: expected Sound, got nil (did audio.load_sound fail?)`
- `window.get_position: failed to query window position: ...`

Bad:
- `SDL_SetRenderTarget failed`
- `Renderer is nil`

---

## Design Principle

Different kinds of failure should feel different.

- misuse is loud
- backend/runtime failure is structured
- dead resources are soft where appropriate
- normal misses are not errors