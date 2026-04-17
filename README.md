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
local x, y = 400, 300
local speed = 420

runtime.init = function()
    window.set_title("Welcome to Newt!")
end

runtime.update = function(dt)
    if input.down("a") or input.down("left")  then x = x - speed * dt end
    if input.down("d") or input.down("right") then x = x + speed * dt end
    if input.down("w") or input.down("up")    then y = y - speed * dt end
    if input.down("s") or input.down("down")  then y = y + speed * dt end
end

runtime.draw = function()
    graphics.clear(rgba(20, 30, 20))
    graphics.draw_text("WASD or arrow keys to move", 16, 16, rgba("#00FF00"))
    graphics.draw_rect(x, y, 32, 32, rgba("#00FF00"))
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
