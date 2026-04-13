# API Reference

This reference documents the available global functions and modules.

## Modules

* [runtime](runtime.md) - Application lifecycle callbacks.
* [window](window.md) - Window state, sizing, cursor control, and clipboard access.
* [graphics](graphics.md) - Drawing, images, text, transforms, canvases, and pixelmaps.
* [audio](audio.md) - Sound loading, playback, spatialization, buses, and effects.
* [input](input.md) - Keyboard and mouse state, mouse position and wheel, and text input.
* [filesystem](filesystem.md) - Resource and working directory access, file operations, and directory queries.

## Global Functions

* [Global Functions](global.md) - Global helpers such as `free()` and `rgba()`.

## Getting Started

Projects are loaded relative to the `Resource Directory`, which is the directory containing the executable. The executable can be renamed, and additional files or folders can be placed anywhere under the `Resource Directory`.

The host expects a `lua/main.lua` file inside the `Resource Directory`. This file is the application entry point, and is where runtime callbacks such as `runtime.init`, `runtime.update`, and `runtime.draw` are typically defined.

A minimal project might look like this:

```text
your_project/
├── your_game.exe
├── SDL3.dll
├── SDL3_ttf.dll
└── lua/
    └── main.lua
```

A minimal `main.lua` could look like this:

```lua
local px, py = 16, 16 -- Position
local pw, ph          -- Scale

runtime.init = function()
    window.set_title("Hello World!")
    pw, ph = graphics.measure_text("@")
end

runtime.update = function(dt)
    if input.pressed("left")  then px = px - pw end
    if input.pressed("right") then px = px + pw end
    if input.pressed("up")    then py = py - ph end
    if input.pressed("down")  then py = py + ph end
end

runtime.draw = function()
    graphics.clear(rgba(20, 20, 24))
    graphics.draw_text("@", px, py)
end
```