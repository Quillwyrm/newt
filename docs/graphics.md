# graphics

[cite_start]The Luagame graphics API manages both hardware-accelerated rendering (VRAM) and low-level CPU pixel manipulation (RAM)[cite: 1, 6]. 

### Related Core API
These functions reside in the global `core` module but are frequently used with graphics.

* [cite_start][`free(userdata)`](core.md#free) - Manually destroys `Atlas`, `Image`, or `Pixelmap` userdata to reclaim memory[cite: 118, 120, 122].
* [`rgba(r, g, b, a)`](core.md#rgba) - Constructs packed color integers for drawing operations.

---

## Functions

### Hardware Rendering (VRAM)
[cite_start]Operations performed directly on the GPU using hardware-accelerated textures[cite: 6, 7].

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
Software-based rasterization for raw memory manipulation. [cite_start]All `blit_` functions respect a unified blend mode: `"replace"`, `"blend"`, `"add"`, `"multiply"`, `"erase"`, or `"mask"`[cite: 28, 60].

**IO & Lifecycle**
* [`new_pixelmap`](#graphicsnew_pixelmap)
* [`load_pixelmap`](#graphicsload_pixelmap)
* [`save_pixelmap`](#graphicssave_pixelmap)
* [`pixelmap_clone`](#graphicspixelmap_clone)

**Queries & Atomic Ops**
* [`get_pixelmap_size`](#graphicsget_pixelmap_size)
* [`pixelmap_get_pixel`](#graphicspixelmap_get_pixel)
* [`pixelmap_set_pixel`](#graphicspixelmap_set_pixel)
* [`pixelmap_flood_fill`](#graphicspixelmap_flood_fill)
* [`pixelmap_raycast`](#graphicspixelmap_raycast)
* [`get_pixelmap_cptr`](#graphicsget_pixelmap_cptr)

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

---

## Hardware Rendering

### graphics.clear
[cite_start]Clears the entire render target[cite: 16].

#### Usage
```lua
graphics.clear(color?)
```

#### Arguments
* `number: color` (Optional) - The color to clear with. [cite_start]Defaults to black (`0x000000FF`)[cite: 16].

---

### graphics.draw_debug_text
[cite_start]Draws simple 8x8 bitmap text to the screen for debugging[cite: 17].

#### Usage
```lua
graphics.draw_debug_text(x, y, text, color?)
```

#### Arguments
* [cite_start]`number: x`, `number: y` - Screen coordinates[cite: 17].
* [cite_start]`string: text` - The string to render[cite: 17].
* `number: color` (Optional) - Packed color integer. [cite_start]Defaults to white (`0xFFFFFFFF`)[cite: 17].

---

### graphics.load_image
[cite_start]Loads an image file (e.g., PNG) from disk into GPU VRAM[cite: 8, 18].

#### Usage
```lua
img, err = graphics.load_image(path)
```

#### Returns
* [cite_start]`userdata: img` - An Image object, or `nil` on failure[cite: 19, 20].
* [cite_start]`string: err` - Error message if loading failed[cite: 19].

---

### graphics.load_atlas
[cite_start]Loads an image and partitions it into a grid for sprite drawing[cite: 22].

#### Usage
```lua
atlas, err = graphics.load_atlas(path, cell_w, cell_h)
```

#### Returns
* [cite_start]`userdata: atlas` - An Atlas object, or `nil` on failure[cite: 23, 24].
* [cite_start]`string: err` - Error message if loading failed[cite: 23].

---

### graphics.set_default_filter
[cite_start]Sets the scaling filter used for hardware textures loaded after this call[cite: 25].

#### Usage
```lua
graphics.set_default_filter(mode)
```

#### Arguments
* [cite_start]`string: mode` - Either `"nearest"` or `"linear"`[cite: 25].

---

### graphics.get_image_size
[cite_start]Returns the pixel dimensions of an Image or Atlas[cite: 27].

#### Usage
```lua
w, h = graphics.get_image_size(object)
```

#### Returns
* [cite_start]`number: w` - Width in pixels[cite: 27].
* [cite_start]`number: h` - Height in pixels[cite: 27].

---

## Pixelmap

### graphics.new_pixelmap
[cite_start]Allocates a new CPU-side buffer for software rasterization, initialized to transparent black[cite: 33, 34].

#### Usage
```lua
pm = graphics.new_pixelmap(w, h)
```

---

### graphics.load_pixelmap
Loads an image from disk directly into a CPU Pixelmap[cite: 36].

#### Usage
```lua
pm, w, h = graphics.load_pixelmap(path)
```

#### Returns
* [cite_start]`userdata: pm` - The loaded Pixelmap[cite: 36, 38].
* [cite_start]`number: w`, `number: h` - Original image dimensions[cite: 36].

---

### graphics.save_pixelmap
[cite_start]Saves the contents of a Pixelmap to a PNG file on disk[cite: 40].

#### Usage
```lua
ok, err = graphics.save_pixelmap(pm, path)
```

---

### graphics.pixelmap_clone
Creates a deep copy of a Pixelmap into a new buffer[cite: 117].

#### Usage
```lua
new_pm = graphics.pixelmap_clone(pm)
```

---

### graphics.get_pixelmap_size
Returns the pixel dimensions of a Pixelmap[cite: 39].

#### Usage
```lua
w, h = graphics.get_pixelmap_size(pm)
```

---

### graphics.pixelmap_get_pixel
Returns the raw color value of a specific pixel[cite: 45, 46].

#### Usage
```lua
color = graphics.pixelmap_get_pixel(pm, x, y)
```

---

### graphics.pixelmap_set_pixel
Sets a single pixel value in memory. This is a raw write and does not perform alpha blending[cite: 42, 43, 44].

#### Usage
```lua
graphics.pixelmap_set_pixel(pm, x, y, color)
```

---

### graphics.pixelmap_flood_fill
Performs a high-performance scanline flood fill from a starting point[cite: 46, 49].

#### Usage
```lua
graphics.pixelmap_flood_fill(pm, x, y, color)
```

---

### graphics.pixelmap_raycast
Traces a line and returns the first non-transparent pixel encountered[cite: 54, 57].

#### Usage
```lua
hit, x, y, color = graphics.pixelmap_raycast(pm, x1, y1, x2, y2)
```

#### Returns
* [cite_start]`boolean: hit` - `true` if an opaque pixel was struck[cite: 57].
* [cite_start]`number: x`, `number: y` - Hit coordinates[cite: 57].
* [cite_start]`number: color` - The color of the hit pixel[cite: 58].

---

### graphics.get_pixelmap_cptr
[cite_start]Returns a raw C pointer to the pixel data as `lightuserdata` for use with FFI[cite: 116].

#### Usage
```lua
ptr = graphics.get_pixelmap_cptr(pm)
```

---

### graphics.blit_line
[cite_start]Draws a 1px thick line between two points using the Bresenham algorithm[cite: 79, 80].

#### Usage
```lua
graphics.blit_line(pm, x1, y1, x2, y2, color?, mode?)
```

---

### graphics.blit_rect
Draws a solid filled rectangle[cite: 68, 71].

#### Usage
```lua
graphics.blit_rect(pm, x, y, w, h, color?, mode?)
```

---

### graphics.blit_triangle
[cite_start]Draws a solid filled triangle using edge-equation rasterization[cite: 72, 75].

#### Usage
```lua
graphics.blit_triangle(pm, x1, y1, x2, y2, x3, y3, color?, mode?)
```

---

### graphics.blit_circle
Draws a solid filled circle[cite: 84, 86].

#### Usage
```lua
graphics.blit_circle(pm, cx, cy, radius, color?, mode?)
```

---

### graphics.blit_circle_outline
[cite_start]Draws a circle outline with variable thickness[cite: 86, 88].

#### Usage
```lua
graphics.blit_circle_outline(pm, cx, cy, radius, thickness, color?, mode?)
```

---

### graphics.blit_circle_pixel_outline
[cite_start]Draws a 1px thick circle outline using the Bresenham circle algorithm[cite: 90].

#### Usage
```lua
graphics.blit_circle_pixel_outline(pm, cx, cy, radius, color?, mode?)
```

---

### graphics.blit_capsule
[cite_start]Draws a thick rounded line (capsule)[cite: 92, 94].

#### Usage
```lua
graphics.blit_capsule(pm, x1, y1, x2, y2, radius, color?, mode?)
```

---

### graphics.blit
[cite_start]Copies the entire contents of one Pixelmap onto another[cite: 95, 96, 97].

#### Usage
```lua
graphics.blit(dst, src, dx, dy, mode?)
```

---

### graphics.blit_region
[cite_start]Copies a sub-region of one Pixelmap onto another[cite: 98, 100].

#### Usage
```lua
graphics.blit_region(dst, src, sx, sy, w, h, dx, dy, mode?)
```

---

### graphics.new_image_from_pixelmap
Creates a hardware-accelerated `Image` (VRAM) from a CPU `Pixelmap`[cite: 106, 107].

#### Usage
```lua
img = graphics.new_image_from_pixelmap(pm)
```

---

### graphics.update_image_from_pixelmap
[cite_start]Syncs an entire Pixelmap to an existing GPU Image[cite: 108].

#### Usage
```lua
graphics.update_image_from_pixelmap(img, pm, dx?, dy?)
```

---

### graphics.update_image_region_from_pixelmap
Pushes a sub-region of a Pixelmap to a location on a GPU Image[cite: 110, 114, 115].

#### Usage
```lua
graphics.update_image_region_from_pixelmap(img, pm, sx, sy, w, h, dx, dy)
```