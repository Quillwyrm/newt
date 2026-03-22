![monotome](logo.png)

**Monotome** is a **Lua-scriptable textmode rendering engine** written in *Odin*.

**Write Lua, draw glyphs, ship little tools.**

It’s aimed at **terminal-style apps**, **experiments**, **toys**, and **small games** that want a textmode look, expressive scripting, and fast iteration.

![demo](demo.gif)

## What you get

A small set of primitives exposed to Lua via the global `monotome` table:

* `runtime` — lifecycle hooks (`init`, `update`, `draw`)
* `window` — window creation, metrics, and OS window state (fullscreen, borderless)
* `draw` — cell-space primitives (clear, text, rect)
* `input` — keyboard/mouse polling and event tracking
* `font` — managed TTF rendering with strict 4-face styling (Regular, Bold, Italic, BI)

## Documentation
Full API documentation is [available in the docs/](docs/api_monotome.md) folder.


## Notes

* Text rendering is **SDL_ttf based** (not a bitmap font sheet).
* Rendering is **cell-space / textmode**: you work in `(col, row)` coordinates.
* Monotome is **not a terminal emulator**; it does not emulate VT100 or ANSI codes.
* Built with **Odin**, **SDL3**, **SDL_ttf**, and **LuaJIT**.

## Status

**Active Development.** The backend recently migrated from Raylib to SDL3. The core API is stable but subject to change.

## Running Monotome

On Windows, run the monotome.exe:

- `monotome/monotome.exe`

To start building, edit main.lua at:

- `monotome/lua/main.lua`

## Build (Windows)

From inside the `monotome/` folder:

```sh
odin build src -out:monotome.exe -resource:src/monotome.rc
```
