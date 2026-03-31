# graphics

The Luagame graphics API manages both hardware-accelerated rendering (VRAM) and low-level CPU pixel manipulation (RAM). 

### Related Core API
These functions reside in the global `core` module but are frequently used with graphics.

* [`free(userdata)`](core.md#free) - Manually destroys `Atlas`, `Image`, or `Pixelmap` userdata to reclaim memory.
* [`rgba(r, g, b, a)`](core.md#rgba) - Constructs packed color integers for drawing operations.

---

## Functions

### Hardware Rendering (VRAM)
Operations performed directly on the GPU using hardware-accelerated textures. These are highly efficient for final display and complex transformations but do not allow for direct, per-pixel modification by the CPU.

**Rendering Verbs**
* [`clear`](#graphicsclear)
* [`draw_debug_text`](#graphicsdraw_debug_text)

**Resource Loaders**
* [`load_image`](#graphicsload_image)
* [`load_atlas`](#graphicsload_atlas)
* [`set_default_filter`](#graphicsset_default_filter)

**Getters**
* [`get_image_size`](#graphicsget_image_size)

### Pixelmap (CPU Rasterizer)
Pixelmaps are CPU-resident buffers of raw pixel data (backed by SDL Surfaces). Unlike Images, which live in VRAM, Pixelmaps reside in system RAM to allow for low-level software rasterization, procedural generation, and direct per-pixel read/write access. 

Once modified, a Pixelmap can be "synced" or uploaded to an Image to be drawn by the hardware-accelerated pipeline. All `blit_` functions respect a unified blend mode system: `"replace"`, `"blend"`, `"add"`, `"multiply"`, `"erase"`, or `"mask"`.

**IO & Lifecycle**
* [`new_pixelmap`](#graphicsnew_pixelmap)
* [`load_pixelmap`](#graphicsload_pixelmap)
* [`save_pixelmap`](#graphicssave_pixelmap)

**Queries & Atomic Ops**
* [`get_pixelmap_size`](#graphicsget_pixelmap_size)
* [`pixelmap_get_pixel`](#graphicspixelmap_get_pixel)
* [`pixelmap_set_pixel`](#graphicspixelmap_set_pixel)
* [`pixelmap_flood_fill`](#graphicspixelmap_flood_fill)
* [`pixelmap_raycast`](#graphicspixelmap_raycast)


**Geometry (Blits)**
* [`blit_line`](#graphicsblit_line)
* [`blit_rect`](#graphicsblit_rect)
* [`blit_triangle`](#graphicsblit_triangle)
* [`blit_circle`](#graphicsblit_circle)
* [`blit_circle_outline`](#graphicsblit_circle_outline)
* [`blit_circle_pixel_outline`](#graphicsblit_circle_pixel_outline)
* [`blit_capsule`](#graphicsblit_capsule)

**Composition**
* [`blit`](#graphicsblit)
* [`blit_region`](#graphicsblit_region)

**VRAM Sync**
* [`new_image_from_pixelmap`](#graphicsnew_image_from_pixelmap)
* [`update_image_from_pixelmap`](#graphicsupdate_image_from_pixelmap)
* [`update_image_region_from_pixelmap`](#graphicsupdate_image_region_from_pixelmap)

**FFI utilities**
* [`get_pixelmap_cptr`](#graphicsget_pixelmap_cptr)
* [`pixelmap_clone`](#graphicspixelmap_clone)

---

## Hardware Rendering

### graphics.clear
Clears the entire render target.

#### Usage
```lua
graphics.clear(color?)
```

#### Arguments
* `number: color` (Optional) - The color to clear with. Defaults to black (`0x000000FF`).

---

### graphics.draw_debug_text
Draws simple 8x8 bitmap text to the screen for debugging.

#### Usage
```lua
graphics.draw_debug_text(x, y, text, color?)
```

#### Arguments
* `number: x`, `number: y` - Screen coordinates.
* `string: text` - The string to render.
* `number: color` (Optional) - Packed color integer. Defaults to white (`0xFFFFFFFF`).

---

### graphics.load_image
Loads an image file (e.g., PNG) from disk into GPU VRAM.

#### Usage
```lua
img, err = graphics.load_image(path)
```

#### Returns
* `userdata: img` - An Image object, or `nil` on failure.
* `string: err` - Error message if loading failed.

---

### graphics.load_atlas
Loads an image and partitions it into a grid for sprite drawing.

#### Usage
```lua
atlas, err = graphics.load_atlas(path, cell_w, cell_h)
```

#### Returns
* `userdata: atlas` - An Atlas object, or `nil` on failure.
* `string: err` - Error message if loading failed.

---

### graphics.set_default_filter
Sets the scaling filter used for hardware textures loaded after this call.

#### Usage
```lua
graphics.set_default_filter(mode)
```

#### Arguments
* `string: mode` - Either `"nearest"` or `"linear"`.

---

### graphics.get_image_size
Returns the pixel dimensions of an Image or Atlas.

#### Usage
```lua
w, h = graphics.get_image_size(object)
```

#### Returns
* `number: w` - Width in pixels.
* `number: h` - Height in pixels.

---

## Pixelmap (CPU Rasterizer)

### graphics.new_pixelmap
Allocates a new CPU-side buffer for software rasterization, initialized to transparent black.

#### Usage
```lua
pm = graphics.new_pixelmap(w, h)
```

---

### graphics.load_pixelmap
Loads an image from disk directly into a CPU Pixelmap.

#### Usage
```lua
pm, w, h = graphics.load_pixelmap(path)
```

#### Returns
* `userdata: pm` - The loaded Pixelmap.
* `number: w`, `number: h` - Original image dimensions.

---

### graphics.save_pixelmap
Saves the contents of a Pixelmap to a PNG file on disk.

#### Usage
```lua
ok, err = graphics.save_pixelmap(pm, path)
```

---

### graphics.pixelmap_clone
Creates a deep copy of a Pixelmap into a new buffer.

#### Usage
```lua
new_pm = graphics.pixelmap_clone(pm)
```

---

### graphics.get_pixelmap_size
Returns the pixel dimensions of a Pixelmap.

#### Usage
```lua
w, h = graphics.get_pixelmap_size(pm)
```

---

### graphics.pixelmap_get_pixel
Returns the raw color value of a specific pixel.

#### Usage
```lua
color = graphics.pixelmap_get_pixel(pm, x, y)
```

---

### graphics.pixelmap_set_pixel
Sets a single pixel value in memory. This is a raw write and does not perform alpha blending.

#### Usage
```lua
graphics.pixelmap_set_pixel(pm, x, y, color)
```

---

### graphics.pixelmap_flood_fill
Performs a high-performance scanline flood fill from a starting point.

#### Usage
```lua
graphics.pixelmap_flood_fill(pm, x, y, color)
```

---

### graphics.pixelmap_raycast
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

### graphics.get_pixelmap_cptr
Returns a raw C pointer to the pixel data as `lightuserdata` for use with FFI.

#### Usage
```lua
ptr = graphics.get_pixelmap_cptr(pm)
```

---

### graphics.blit_line
Draws a 1px thick line between two points using the Bresenham algorithm.

#### Usage
```lua
graphics.blit_line(pm, x1, y1, x2, y2, color?, mode?)
```

---

### graphics.blit_rect
Draws a solid filled rectangle.

#### Usage
```lua
graphics.blit_rect(pm, x, y, w, h, color?, mode?)
```

---

### graphics.blit_triangle
Draws a solid filled triangle using edge-equation rasterization.

#### Usage
```lua
graphics.blit_triangle(pm, x1, y1, x2, y2, x3, y3, color?, mode?)
```

---

### graphics.blit_circle
Draws a solid filled circle.

#### Usage
```lua
graphics.blit_circle(pm, cx, cy, radius, color?, mode?)
```

---

### graphics.blit_circle_outline
Draws a circle outline with variable thickness.

#### Usage
```lua
graphics.blit_circle_outline(pm, cx, cy, radius, thickness, color?, mode?)
```

---

### graphics.blit_circle_pixel_outline
Draws a 1px thick circle outline using the Bresenham circle algorithm.

#### Usage
```lua
graphics.blit_circle_pixel_outline(pm, cx, cy, radius, color?, mode?)
```

---

### graphics.blit_capsule
Draws a thick rounded line (capsule).

#### Usage
```lua
graphics.blit_capsule(pm, x1, y1, x2, y2, radius, color?, mode?)
```

---

### graphics.blit
Copies the entire contents of one Pixelmap onto another.

#### Usage
```lua
graphics.blit(dst, src, dx, dy, mode?)
```

---

### graphics.blit_region
Copies a sub-region of one Pixelmap onto another.

#### Usage
```lua
graphics.blit_region(dst, src, sx, sy, w, h, dx, dy, mode?)
```

---

### graphics.new_image_from_pixelmap
Creates a hardware-accelerated `Image` (VRAM) from a CPU `Pixelmap`.

#### Usage
```lua
img = graphics.new_image_from_pixelmap(pm)
```

---

### graphics.update_image_from_pixelmap
Syncs an entire Pixelmap to an existing GPU Image.

#### Usage
```lua
graphics.update_image_from_pixelmap(img, pm, dx?, dy?)
```

---

### graphics.update_image_region_from_pixelmap
Pushes a sub-region of a Pixelmap to a location on a GPU Image.

#### Usage
```lua
graphics.update_image_region_from_pixelmap(img, pm, sx, sy, w, h, dx, dy)
```