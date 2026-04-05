# graphics

The Luagame graphics API manages both hardware-accelerated rendering (VRAM) and low-level CPU pixel manipulation (RAM). 

### Related Core API
These functions reside in the global `core` module but are frequently used with graphics.

* [`free(userdata)`](core.md#free) - Manually destroys `Image` or `Pixelmap` userdata to reclaim memory.
* [`rgba(r, g, b, a)`](core.md#rgba) - Constructs packed color integers for drawing operations.

---

## Functions

**Hardware Rendering (VRAM)**
* [`draw_image`](#draw_image)
* [`draw_image_region`](#draw_image_region)
* [`draw_rect`](#draw_rect)
* [`load_image`](#load_image)
* [`get_image_size`](#get_image_size)
* [`set_default_filter`](#set_default_filter)
* [`new_canvas`](#new_canvas)
* [`set_canvas`](#set_canvas)

**Frame & Pipeline State**
* [`clear`](#clear)
* [`set_blend_mode`](#set_blend_mode)
* [`set_clip_rect`](#set_clip_rect)
* [`get_clip_rect`](#get_clip_rect)

**Transformations & Coordinate Spaces**
* [`begin_transform`](#begin_transform)
* [`end_transform`](#end_transform)
* [`set_translation`](#set_translation)
* [`set_rotation`](#set_rotation)
* [`set_scale`](#set_scale)
* [`set_origin`](#set_origin)
* [`use_screen_space`](#use_screen_space)
* [`screen_to_local`](#screen_to_local)
* [`local_to_screen`](#local_to_screen)

**Debug Drawing**
* [`debug_text`](#debug_text)
* [`debug_line`](#debug_line)
* [`debug_rect`](#debug_rect)

**Pixelmap: Lifecycle & I/O**
* [`new_pixelmap`](#new_pixelmap)
* [`load_pixelmap`](#load_pixelmap)
* [`save_pixelmap`](#save_pixelmap)
* [`get_pixelmap_size`](#get_pixelmap_size)

**Pixelmap: Software Rasterization**
* [`blit`](#blit)
* [`blit_region`](#blit_region)
* [`blit_rect`](#blit_rect)
* [`blit_line`](#blit_line)
* [`blit_triangle`](#blit_triangle)
* [`blit_circle`](#blit_circle)
* [`blit_circle_outline`](#blit_circle_outline)
* [`blit_circle_pixel_outline`](#blit_circle_pixel_outline)
* [`blit_capsule`](#blit_capsule)

**Pixelmap: Atomic Ops & Analysis**
* [`pixelmap_set_pixel`](#pixelmap_set_pixel)
* [`pixelmap_get_pixel`](#pixelmap_get_pixel)
* [`pixelmap_flood_fill`](#pixelmap_flood_fill)
* [`pixelmap_raycast`](#pixelmap_raycast)

**Pixelmap: VRAM Sync**
* [`new_image_from_pixelmap`](#new_image_from_pixelmap)
* [`update_image_from_pixelmap`](#update_image_from_pixelmap)
* [`update_image_region_from_pixelmap`](#update_image_region_from_pixelmap)

**Pixelmap: Memory & FFI**
* [`pixelmap_clone`](#pixelmap_clone)
* [`pixelmap_get_cptr`](#pixelmap_get_cptr)


---

## Hardware Rendering (VRAM)
Operations performed directly on the GPU using hardware textures. These are highly efficient, respect the active transform stack, and support global blend modes.
---

### draw_image
Draws a full image to the screen.

#### Usage
```lua
graphics.draw_image(img, x, y, color?)
```

#### Arguments
* `userdata: img` - The Image object to draw.
* `number: x`, `number: y` - Local space coordinates.
* `number: color` (Optional) - A tint color. Defaults to white (`0xFFFFFFFF`).

---

### draw_image_region
Draws a rectangular sub-region (snip) of an image. Useful for sprite sheets.

#### Usage
```lua
graphics.draw_image_region(img, sx, sy, sw, sh, dx, dy, color?)
```

#### Arguments
* `userdata: img` - The Image object.
* `number: sx`, `number: sy` - Source X and Y (top-left of the snip).
* `number: sw`, `number: sh` - Source width and height.
* `number: dx`, `number: dy` - Destination X and Y (where to draw it).
* `number: color` (Optional) - A tint color. Defaults to white.

---

### draw_rect
Draws a solid filled rectangle that respects the active transform stack.

#### Usage
```lua
graphics.draw_rect(x, y, w, h, color?)
```

#### Arguments
* `number: x`, `number: y` - Top-left coordinates.
* `number: w`, `number: h` - Width and height.
* `number: color` (Optional) - Packed color integer. Defaults to white.

---

### load_image
Loads an image file (e.g., PNG) from disk directly into GPU VRAM.

#### Usage
```lua
img, err = graphics.load_image(path)
```

#### Returns
* `userdata: img` - An Image object, or `nil` on failure.
* `string: err` - Error message if loading failed.

---

### get_image_size
Returns the pixel dimensions of an Image.

#### Usage
```lua
w, h = graphics.get_image_size(img)
```

#### Returns
* `number: w` - Width in pixels.
* `number: h` - Height in pixels.

---

### set_default_filter
Sets the scaling filter used for hardware textures loaded or created *after* this call.

#### Usage
```lua
graphics.set_default_filter(mode)
```

#### Arguments
* `string: mode` - Either `"nearest"` (pixel art) or `"linear"` (smooth).

---

### new_canvas
Creates a blank, hardware-accelerated Image that can be used as a render target.

#### Usage
```lua
canvas = graphics.new_canvas(w, h)
```

#### Arguments
* `number: w`, `number: h` - Dimensions of the canvas in pixels.

#### Returns
* `userdata: canvas` - An Image object configured as a render target.

---

### set_canvas
Redirects all subsequent hardware drawing operations to a specific canvas (Image) instead of the screen.

#### Usage
```lua
graphics.set_canvas(canvas?)
```

#### Arguments
* `userdata: canvas` (Optional) - The canvas to draw into. If omitted or `nil`, drawing resets to the main screen.

---

## Frame & Pipeline State

### clear
Clears the active render target (the screen or the current canvas).

#### Usage
```lua
graphics.clear(color?)
```

#### Arguments
* `number: color` (Optional) - The background color. Defaults to black (`0x000000FF`).

---

### set_blend_mode
Sets the global hardware blending mode for all subsequent GPU draw calls.

#### Usage
```lua
graphics.set_blend_mode(mode?)
```

#### Arguments
* `string: mode` (Optional) - The blend operation. Valid options: `"blend"` (default), `"replace"`, `"add"`, `"multiply"`, `"modulate"`, `"premultiplied"`.

---

### set_clip_rect
Sets a hardware clipping rectangle (scissor box) in absolute window coordinates. Drawing outside this box is discarded.

#### Usage
```lua
graphics.set_clip_rect(x?, y?, w?, h?)
```

#### Arguments
* `number: x`, `number: y` (Optional) - Top-left coordinates.
* `number: w`, `number: h` (Optional) - Width and height.
* *Note: Calling with no arguments disables clipping entirely.*

---

### get_clip_rect
Returns the current hardware clip rectangle, if one is active.

#### Usage
```lua
x, y, w, h = graphics.get_clip_rect()
```

#### Returns
* `number: x`, `number: y`, `number: w`, `number: h` - The rectangle bounds. Returns nothing if clipping is disabled.

---

## Draw Transforms

Transform blocks let you temporarily change how things are drawn. You can move, rotate, or scale every `draw_` call inside a block.

You must call `begin_transform()` before using any transform functions.
All `set_` functions only work inside an active transform block.

Transforms are applied in the order you call them, and affect everything drawn until the block ends.

---

### begin_transform

Starts a new transform block. All transforms applied after this affect everything you draw until `end_transform()` is called. Must be called before using any transform functions.

#### Usage

```lua
graphics.begin_transform()
```

---

### end_transform

Ends the current transform block. Drawing returns to normal, and transform functions have no effect until a new block is started.

#### Usage

```lua
graphics.end_transform()
```

---

### set_translation

Moves everything you draw inside the current transform block. Must be called inside a transform block.

#### Usage

```lua
graphics.set_translation(x, y)
```

#### Arguments

* `number: x`, `number: y` — Offset amounts.

---

### set_rotation

Rotates everything you draw inside the current transform block, around the current origin (see `set_origin`). Must be called inside a transform block.

#### Usage

```lua
graphics.set_rotation(radians)
```

#### Arguments

* `number: radians` — Angle of rotation.

---

### set_scale

Scales everything you draw inside the current transform block, relative to the current origin (see `set_origin`). Must be called inside a transform block.

#### Usage

```lua
graphics.set_scale(sx, sy?)
```

#### Arguments

* `number: sx` — Horizontal scale.
* `number: sy` (optional) — Vertical scale. Defaults to `sx`.

---

### set_origin

Sets the pivot point used for rotation and scaling. By default this is the top-left corner; changing it lets you rotate or scale around another point (for example, the center). Must be called inside a transform block.

#### Usage

```lua
graphics.set_origin(ox, oy)
```

#### Arguments

* `number: ox`, `number: oy` — Pivot position.

---

### use_screen_space

Ignores all transforms in the current block, so drawing uses screen coordinates (top-left = 0,0). Still ends when `end_transform()` is called. Must be called inside a transform block.

#### Usage

```lua
graphics.use_screen_space()
```

---

### screen_to_local

Converts a screen position into the current transform. Useful for matching input (like the mouse) to transformed drawing.

#### Usage

```lua
lx, ly = graphics.screen_to_local(sx, sy)
```

#### Arguments

* `number: sx`, `number: sy` — Screen coordinates.

#### Returns

* `number: lx`, `number: ly` — Position inside the current transform.

---

### local_to_screen

Converts a position inside the current transform into screen coordinates.

#### Usage

```lua
sx, sy = graphics.local_to_screen(lx, ly)
```

#### Arguments

* `number: lx`, `number: ly` — Position inside the current transform.

#### Returns

* `number: sx`, `number: sy` — Screen coordinates.

---

## Important Notes

* Transform functions (`set_translation`, `set_rotation`, etc.) only work inside a `begin_transform()` / `end_transform()` block.

* Transforms are applied **in the order you call them**.

  A common pattern is:

  * Translate → Rotate → Scale (TRS)

  Changing the order changes the result:

  * Move, then rotate → rotates around the moved position
  * Rotate, then move → moves in a rotated direction
  * Scaling before vs after rotation also produces different results

* Transforms affect **all draw calls inside the block**.

* They do **not** affect values you pass directly into draw functions.

  If you pass `x, y` into a draw call,
  `screen_to_local()` and `local_to_screen()` may not match what you see.

  If you need correct coordinate conversion, apply movement using `set_translation()` instead of draw arguments.

---

## Debug Drawing
These functions draw primitive shapes directly to the screen via SDL. They operate in absolute screen-space and **ignore** the transform stack. Useful for hitboxes, raycasts, and development data.

### debug_text
Draws simple 8x8 bitmap text to the screen.

#### Usage
```lua
graphics.debug_text(x, y, text, color?)
```

#### Arguments
* `number: x`, `number: y` - Screen coordinates.
* `string: text` - The string to render.
* `number: color` (Optional) - Packed color integer. Defaults to white.

---

### debug_line
Draws a 1px thick line between two absolute screen points.

#### Usage
```lua
graphics.debug_line(x1, y1, x2, y2, color?)
```

#### Arguments
* `number: x1`, `number: y1`, `number: x2`, `number: y2` - Start and end coordinates.
* `number: color` (Optional) - Packed color integer. Defaults to white.

---

### debug_rect
Draws a 1px hollow rectangle.

#### Usage
```lua
graphics.debug_rect(x, y, w, h, color?)
```

#### Arguments
* `number: x`, `number: y` - Top-left coordinates.
* `number: w`, `number: h` - Width and height.
* `number: color` (Optional) - Packed color integer. Defaults to white.

---

## Pixelmap (CPU Rasterizer)
Pixelmaps are CPU-resident buffers of raw pixel data. Unlike Images (VRAM), Pixelmaps live in system RAM to allow for software rasterization, procedural generation, and per-pixel read/write access. 

*Note: Software rendering blend modes differ slightly from the GPU. Valid `blit_` modes are: `"blend"` (default), `"replace"`, `"add"`, `"multiply"`, `"erase"`, and `"mask"`.*

### new_pixelmap
Allocates a new CPU-side buffer, initialized to transparent black.

#### Usage
```lua
pm = graphics.new_pixelmap(w, h)
```

---

### load_pixelmap
Loads an image from disk directly into a CPU Pixelmap.

#### Usage
```lua
pm, w, h = graphics.load_pixelmap(path)
```

#### Returns
* `userdata: pm` - The loaded Pixelmap.
* `number: w`, `number: h` - Original image dimensions.

---

### save_pixelmap
Saves the contents of a Pixelmap to a PNG file on disk.

#### Usage
```lua
ok, err = graphics.save_pixelmap(pm, path)
```

---

### get_pixelmap_size
Returns the pixel dimensions of a Pixelmap.

#### Usage
```lua
w, h = graphics.get_pixelmap_size(pm)
```

---

### blit
Copies the entire contents of one Pixelmap onto another.

#### Usage
```lua
graphics.blit(dst, src, dx, dy, mode?)
```

#### Arguments
* `userdata: dst` - The destination Pixelmap.
* `userdata: src` - The source Pixelmap.
* `number: dx`, `number: dy` - Destination coordinates.
* `string: mode` (Optional) - CPU Blend mode. Defaults to `"blend"`.

---

### blit_region
Copies a sub-region of one Pixelmap onto another.

#### Usage
```lua
graphics.blit_region(dst, src, sx, sy, w, h, dx, dy, mode?)
```

---

### blit_rect
Draws a solid filled rectangle on a Pixelmap.

#### Usage
```lua
graphics.blit_rect(pm, x, y, w, h, color?, mode?)
```

---

### blit_line
Draws a 1px thick line between two points using the Bresenham algorithm.

#### Usage
```lua
graphics.blit_line(pm, x1, y1, x2, y2, color?, mode?)
```

---

### blit_triangle
Draws a solid filled triangle using edge-equation rasterization.

#### Usage
```lua
graphics.blit_triangle(pm, x1, y1, x2, y2, x3, y3, color?, mode?)
```

---

### blit_circle
Draws a solid filled float-precision circle.

#### Usage
```lua
graphics.blit_circle(pm, cx, cy, radius, color?, mode?)
```

---

### blit_circle_outline
Draws a circle outline with variable thickness.

#### Usage
```lua
graphics.blit_circle_outline(pm, cx, cy, radius, thickness, color?, mode?)
```

---

### blit_circle_pixel_outline
Draws a 1px thick circle outline using the Bresenham integer algorithm.

#### Usage
```lua
graphics.blit_circle_pixel_outline(pm, cx, cy, radius, color?, mode?)
```

---

### blit_capsule
Draws a thick rounded line (capsule).

#### Usage
```lua
graphics.blit_capsule(pm, x1, y1, x2, y2, radius, color?, mode?)
```

---

### pixelmap_set_pixel
Sets a single pixel value in memory. This is a raw memory write and does *not* perform alpha blending.

#### Usage
```lua
graphics.pixelmap_set_pixel(pm, x, y, color)
```

---

### pixelmap_get_pixel
Returns the raw color value of a specific pixel.

#### Usage
```lua
color = graphics.pixelmap_get_pixel(pm, x, y)
```

---

### pixelmap_flood_fill
Performs a high-performance scanline flood fill from a starting point.

#### Usage
```lua
graphics.pixelmap_flood_fill(pm, x, y, color)
```

---

### pixelmap_raycast
Traces a line and returns the first non-transparent pixel encountered.

#### Usage
```lua
hit, x, y, color = graphics.pixelmap_raycast(pm, x1, y1, x2, y2)
```

#### Returns
* `boolean: hit` - `true` if an opaque pixel was struck.
* `number: x`, `number: y` - Hit coordinates.
* `number: color` - The color of the hit pixel.

---

### new_image_from_pixelmap
Creates a hardware-accelerated `Image` (VRAM) from a CPU `Pixelmap`.

#### Usage
```lua
img = graphics.new_image_from_pixelmap(pm)
```

---

### update_image_from_pixelmap
Syncs an entire Pixelmap to an existing GPU Image. Extremely fast way to push software-rendered frames to the screen.

#### Usage
```lua
graphics.update_image_from_pixelmap(img, pm, dx?, dy?)
```

#### Arguments
* `userdata: img` - Destination GPU Image.
* `userdata: pm` - Source CPU Pixelmap.
* `number: dx`, `number: dy` (Optional) - Destination offset coordinates. Defaults to `0, 0`.

---

### update_image_region_from_pixelmap
Pushes a specific sub-region (snip) of a CPU Pixelmap across the PCI-e bus to a location on a GPU Image. Crucial for updating small dirty rects (like a destructible terrain crater) without uploading the entire texture.

#### Usage
```lua
graphics.update_image_region_from_pixelmap(img, pm, sx, sy, w, h, dx, dy)
```

---

### pixelmap_clone
Creates a deep copy of a Pixelmap into a new buffer.

#### Usage
```lua
new_pm = graphics.pixelmap_clone(pm)
```

---

### pixelmap_get_cptr
Returns a raw C pointer to the pixel data as `lightuserdata` for use with LuaJIT FFI.

#### Usage
```lua
ptr = graphics.pixelmap_get_cptr(pm)
```
