# Luagame API Reference

Luagame is a scriptable 2d game engine. It provides a performant host environment (Odin) that handles the windowing, rendering, audio, and input polling, while deferring all application logic to Lua scripts.

The engine exposes core modules to the global environment.

* [runtime](runtime.md) - Lifecycle hooks (`init`, `update`, `draw`).
* [window](window.md) - Window creation, sizing, clipboard, and OS interaction.
* [graphics](graphics.md) - ...
* [audio](audio.md) - ...
* [input](input.md) - Keyboard and mouse input state.

## Project Structure
The engine expects a specific file layout relative to the executable:

```sh
/luagame_project
  ├── luagame.exe
  ├── SDL3.dll
  ├── SDL3_ttf.dll
  ├── lua/
  │    └── main.lua
  └── fonts/
       ├── regular.ttf
       ├── bold.ttf
       ├── italic.ttf
       └── bolditalic.ttf
```