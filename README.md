![newt](res/newtbanner.png)

Newt, a nimble 2D game framework for Lua!  

Newt is a native script-driven runtime built in Odin. It exposes a clear, composable API to LuaJIT for building 2D games, tools, and interactive apps without drowning in giant engine workflows.

## What You Get

- **2D Rendering** - images, shapes, text, fonts, render targets, transforms, clipping, blend modes, and debug drawing
- **Audio** - static sounds, streamed audio, playback, voice control, 2D spatial audio, panning, mixing, filters, and delay
- **Input** - keyboard, mouse, text input, gamepads, sticks, triggers, rumble, and button-edge queries
- **Windowing** - window sizing, positioning, flags, cursor control, clipboard access, and close handling
- **Filesystem Access** - resource paths, working paths, file I/O, directory queries, and basic path operations
- **Raster Tools** - CPU image data, raster drawing, pixel read/write and query operations, Pixelmap I/O, and GPU upload
- **Grid Tools** - datagrids, pathfinding, distance fields, field of view, line of sight, region queries, and 2D array logic
- **RNG Tools** - seeded generators, scalar random values, list randomization, and noise fields

## First Script

Newt looks for `lua/main.lua` in the project `Resource Directory`.

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

## Examples

![Platformer example](examples/platformer.gif)

A tiny platformer with movement, gravity, jumping, an ASCII tile map, and collision. ([see example code](examples/platformer.main.lua))

![Roguelike visibility example](examples/roguelike_vis.gif)

Expressive tools for roguelikes and grid games: noise caves, regions, FOV, and explored memory. ([see example code](examples/roguelike_vis.main.lua))


## Getting Started

See [Getting Started](docs/getting_started.md) for project layout and path semantics.

- [GitHub Releases](../../releases)
- [API Reference](docs/api_ref.md)
- [Examples](examples/)

## Platforms

- Windows (x64)
- macOS (arm64)
- Linux (not tested yet)

## Status

Newt is usable, stable, and actively developed. APIs may evolve as the project grows.

## License

See [LICENSE](LICENSE).
