# Luagame

Luagame is a lightweight, scriptable 2D game engine. It uses a high-performance host environment (written in Odin) to handle windowing, rendering, audio, and input, while deferring all application logic and state to Lua scripts. 

The goal is a fast, "no bullshit" development experience: drop in your assets, write some Lua, and run.

### Features
* **Script-Driven:** Complete control over the application lifecycle via Lua callbacks.
* **Graphics:** Hardware-accelerated 2D rendering with sprite batching and CPU pixelmap rasterization.
* **Audio:** Real-time 8-bus mixing engine with 3D spatialization and DSP effects.
* **Input:** Clean state polling and edge detection for keyboard and mouse.
* **Filesystem:** Sandboxed directory management and file I/O.

---

## Quick Start

The engine expects a specific file layout relative to the executable. Your entire game lives inside the `lua/` directory, starting with `main.lua`.

```sh
/luagame_project
  ├── luagame.exe
  ├── SDL3.dll
  ├── SDL3_ttf.dll
  └── lua/
       └── main.lua
```

### Minimal Example (`main.lua`)

```lua
-- Initialize the window
function runtime.init()
    window.init(800, 600, "Hello Luagame")
end

-- Handle logic
function runtime.update(dt)
    if input.pressed("escape") then 
        window.close() 
    end
end

-- Render the frame
function runtime.draw()
    graphics.clear(rgba("#1E1E2E"))
    graphics.draw_debug_text(10, 10, "Luagame is running.", rgba(255, 255, 255))
end
```

---

## Documentation

The complete API documentation, including detailed overviews of all core modules, is available in the [Luagame API Reference](api_ref.md).

* `runtime` - Core lifecycle hooks.
* `window` - Context and OS interaction.
* `graphics` - 2D rendering and textures.
* `audio` - Sound playback and mixing.
* `input` - Keyboard and mouse state.
* `filesystem` - I/O operations.
* `core` - Global primitives and memory management.

---

## Status

**Active Development.** The core API is stabilizing but is still subject to change.