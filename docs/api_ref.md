# Newt API Reference

This is the reference for Newt's modules and built-in functions.

For setup, project layout, and your first `lua/main.lua`, see [Getting Started](getting_started.md).

### Core

- [runtime](runtime.md) - Application callbacks for startup, per-frame updates, and drawing.
- [window](window.md) - Main window control, sizing, cursor state, clipboard access, and close requests.
- [filesystem](filesystem.md) - Resource paths, working directory access, file I/O, and directory operations.

### Input

- [input](input.md) - Keyboard, mouse, mouse wheel, and text input queries.
- [gamepad](gamepad.md) - Gamepad connection queries, buttons, sticks, triggers, labels, and rumble.

### Media

- [graphics](graphics.md) - GPU drawing, images, canvases, render state, transforms, text, and debug drawing.
- [raster](raster.md) - CPU-side Pixelmaps, raster drawing, per-pixel access, and image-data tools.
- [audio](audio.md) - Sound loading, playback, voice control, spatial audio, bus mixing, and effects.

### Data & Tools

- [grid](grid.md) - Dense integer Datagrids for pathfinding, distance fields, visibility, regions, and grid math.

### Built-in Functions

- [Global Functions](global.md) - Built-in functions available everywhere, including `free()` and `rgba()`.