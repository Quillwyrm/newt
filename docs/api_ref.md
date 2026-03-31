# Luagame API Reference

Luagame is a scriptable 2D game engine. It provides a performant host environment that handles windowing, rendering, audio, and input polling, while deferring all application logic to Lua scripts.

The engine exposes core systems directly to the global Lua environment.

* [runtime](runtime.md) - Core lifecycle hooks (`init`, `update`, `draw`, `shutdown`).
* [window](window.md) - Window context, sizing, cursors, and clipboard access.
* [graphics](graphics.md) - 2D rendering, texture management, and CPU pixelmap rasterization.
* [audio](audio.md) - Real-time 8-bus mixing engine, 3D spatialization, and DSP effects.
* [input](input.md) - Keyboard and mouse state polling, edge detection, and text input.
* [filesystem](filesystem.md) - Process environment, directory management, and basic file IO.

## Project Structure
The engine expects a specific file layout relative to the executable:

```sh
/luagame_project
  ├── luagame.exe
  ├── SDL3.dll
  ├── SDL3_ttf.dll
  └── lua/
       └── main.lua
```