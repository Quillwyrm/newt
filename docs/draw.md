# monotome.draw
The rendering API for drawing text and rects to the cell grid.

### Functions
* [`clear`](#monotomedrawclear)
* [`text`](#monotomedrawtext)
* [`rect`](#monotomedrawrect)

### Faces
The `face` argument determines the font style used for rendering text. It maps directly to the four font paths loaded via `monotome.font`.
- `1` - Regular (Default)
- `2` - Bold
- `3` - Italic
- `4` - Bold Italic

---

## monotome.draw.clear
Clears the entire window with a color and resets the cell grid clipping region to avoid spill.

### Usage
```lua
monotome.draw.clear(color)
```

### Arguments
- `table: color` - A list of RGBA values `{r, g, b, a}` (0-255).

### Returns
None.

---

## monotome.draw.text
Draws a string starting at specific grid coordinates, rendering one character per cell.

### Usage
```lua
monotome.draw.text(x, y, text, color, face?)
```

### Arguments
- `number: x` - The starting column index.
- `number: y` - The starting row index.
- `string: text` - The string to render.
- `table: color` - A list of RGBA values `{r, g, b, a}`.
- `number: face` - Optional font face index (1-4). Defaults to 1.

### Returns
None.

---

## monotome.draw.rect
Draws a solid filled rectangle in grid coordinates.

### Usage
```lua
monotome.draw.rect(x, y, w, h, color)
```

### Arguments
- `number: x` - The top-left column index.
- `number: y` - The top-left row index.
- `number: w` - Width in cells.
- `number: h` - Height in cells.
- `table: color` - A list of RGBA values `{r, g, b, a}`.

### Returns
None.
