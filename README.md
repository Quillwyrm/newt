# Newt 🦎

Newt is a nimble framework for making 2D games with Lua.

## What you get

- 2D graphics with images, text, fonts, render targets, transforms, and CPU pixel read/write, drawing, and utilities
- Audio playback with mixing, 2D spatialization, and effects
- Keyboard, mouse, text input, clipboard, cursor, and window control
- Filesystem access, working directory control, and file operations
- Grid utilities for pathfinding, distance maps, reachability, visibility, and more

## Example

```lua
runtime.init = function()
    window.set_title("Hello Newt")
    window.set_size(800, 600)
end

runtime.update = function(dt)
    if input.pressed("escape") then
        window.close()
    end
end

runtime.draw = function()
    graphics.clear(rgba(20, 20, 24))
    graphics.draw_text("hello from newt", 16, 16)
end
```

## Getting Started

Newt looks for `lua/main.lua` in the project resource directory. That file is your application entry point.

- [Getting Started](docs/getting_started.md)
- [GitHub Releases](../../releases)

## Documentation

- [API Reference](docs/api_ref.md)

## Platforms

- Windows
- macOS (Apple Silicon)

## Status

Newt is in active development.
