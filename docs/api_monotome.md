# Monotome API Reference

Monotome is a scriptable text-mode rendering engine. It provides a performant host environment (Odin) that handles the windowing, inputs, and rendering loop, while deferring all application logic to Lua scripts.

The engine exposes 5 core modules to the global `monotome` namespace.

* [monotome.runtime](runtime.md) - Lifecycle hooks (`init`, `update`, `draw`).
* [monotome.window](window.md) - Window creation, sizing, clipboard, and OS interaction.
* [monotome.draw](draw.md) - Cell-based rendering primitives.
* [monotome.input](input.md) - Keyboard and mouse input state.
* [monotome.font](font.md) - Typeface loading and sizing.

## Project Structure
The engine expects a specific file layout relative to the executable:

```
/my_app
  ├── monotome.exe
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

## Example: Interactive `main.lua`
This example demonstrates the standard lifecycle:
1.  **Setup:** Localize API tables for performance and clarity.
2.  **State:** Define local variables for application state (position, color).
3.  **Init:** Initialize the window and load fonts.
4.  **Update:** Modify state based on `dt` and `input`.
5.  **Draw:** Render the state to the grid.

```lua
-- Localize API
local runtime = monotome.runtime
local window  = monotome.window
local draw    = monotome.draw
local input   = monotome.input
local font    = monotome.font

-- Declare State
local x, y = 5, 5
local color = {255, 255, 255, 255}

--------------------------------------------------------------
-- INIT
--------------------------------------------------------------
runtime.init = function()
  window.init(800, 600, "Monotome Example", {"resizable"})
  
  -- Load fonts from the /fonts/ directory
  font.init(24, {
    "fonts/Mononoki-Regular.ttf",
    "fonts/Mononoki-Bold.ttf",
    "fonts/Mononoki-Italic.ttf",
    "fonts/Mononoki-BoldItalic.ttf"
  })
end

--------------------------------------------------------------
-- UPDATE (Logic Loop)
--------------------------------------------------------------
runtime.update = function(dt)
  -- Exit on Escape
  if input.pressed("escape") then
    window.close()
  end

  -- Move with Arrow Keys
  if input.pressed("up")    then y = y - 1 end
  if input.pressed("down")  then y = y + 1 end
  if input.pressed("left")  then x = x - 1 end
  if input.pressed("right") then x = x + 1 end

  -- Change color on Mouse Click
  if input.down("mouse1") then
    color = {255, 100, 100, 255} -- Red
  else
    color = {255, 255, 255, 255} -- White
  end
end

--------------------------------------------------------------
-- DRAW (Render Loop)
--------------------------------------------------------------
runtime.draw = function()
  draw.clear({10, 10, 15, 255}) -- Clear background
  
  -- Draw instructions
  draw.text(1, 1, "Use Arrows to move. Click to change color.", {100, 100, 100, 255})
  
  -- Draw player character
  draw.text(x, y, "@", color, 2) -- Face 2 = Bold
end
```
