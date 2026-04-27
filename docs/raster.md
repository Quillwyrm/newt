# raster

The `raster` module provides CPU-side Pixelmaps, raster drawing, per-pixel access, and Pixelmap memory utilities.

Use `raster` for image data you want to edit or inspect directly: procedural images, masks, brushes, collision maps, terrain maps, and level-authoring tools.

Unless noted otherwise, functions in this module throw on wrong arity, wrong argument types, and invalid string options. Query functions on freed Pixelmaps return nil-shaped results where documented. Drawing and mutation functions on freed Pixelmaps no-op.

## Drawing Pixelmaps

Pixelmaps live in CPU memory. They are data you can edit, scan, load, save, and draw into.

To show a Pixelmap on screen, create a GPU `Image` from it with the related functions in [`graphics`](graphics.md). If the Pixelmap changes later, update the existing `Image` instead of creating a new one every frame.

| Function | Purpose |
|---|---|
| [`new_image_from_pixelmap`](graphics.md#new_image_from_pixelmap) | Creates a GPU `Image` from a Pixelmap. |
| [`update_image_from_pixelmap`](graphics.md#update_image_from_pixelmap) | Copies a full Pixelmap into an existing `Image`. |
| [`update_image_region_from_pixelmap`](graphics.md#update_image_region_from_pixelmap) | Copies part of a Pixelmap into an existing `Image`. |

## Functions

**Pixelmaps**
* [`new_pixelmap`](#new_pixelmap)
* [`load_pixelmap`](#load_pixelmap)
* [`save_pixelmap`](#save_pixelmap)
* [`get_pixelmap_size`](#get_pixelmap_size)
* [`new_pixelmap_from_datagrid`](#new_pixelmap_from_datagrid)

**Raster Drawing**
* [`blit`](#blit)
* [`blit_region`](#blit_region)
* [`blit_rect`](#blit_rect)
* [`blit_line`](#blit_line)
* [`blit_triangle`](#blit_triangle)
* [`blit_circle`](#blit_circle)
* [`blit_ring`](#blit_ring)
* [`blit_circle_pixel_outline`](#blit_circle_pixel_outline)
* [`blit_capsule`](#blit_capsule)

**Pixel Access & Analysis**
* [`set_pixel`](#set_pixel)
* [`get_pixel`](#get_pixel)
* [`flood_fill`](#flood_fill)
* [`raycast`](#raycast)

**Memory**
* [`clone_pixelmap`](#clone_pixelmap)
* [`get_pixelmap_cptr`](#get_pixelmap_cptr)

## Pixelmaps

Pixelmaps are CPU-side pixel buffers for software drawing and per-pixel access.

### new_pixelmap

Creates a blank Pixelmap initialized to transparent black.

```lua
raster.new_pixelmap(width, height) -> pixelmap
```

#### Error Cases

- `width` and `height` must be positive.

---

### load_pixelmap

Loads an image file into a Pixelmap.

```lua
raster.load_pixelmap(path) -> pixelmap, width, height | nil, err
```

#### Returns

`pixelmap, width, height` on success.  
`nil, err` if the image could not be loaded or decoded.

---

### save_pixelmap

Saves a Pixelmap to a PNG file.

```lua
raster.save_pixelmap(pixelmap, path) -> true | false, err
```

#### Returns

`true` on success.  
`false, err` if the PNG could not be written.

#### Error Cases

- Throws if `pixelmap` has been freed.

---

### get_pixelmap_size

Returns the pixel dimensions of a Pixelmap.

```lua
raster.get_pixelmap_size(pixelmap) -> width, height | nil, nil
```

#### Returns

`width, height` for a live Pixelmap.  
`nil, nil` if `pixelmap` has been freed.

---

### new_pixelmap_from_datagrid

Creates a new Pixelmap from a [`Datagrid`](grid.md) by mapping integer cell values to exact pixel colors.

This is useful for debug views, minimaps, masks, terrain previews, and turning grid data into editable image data. The returned pixelmap has the same dimensions as the datagrid, and grid coordinates map directly to pixel coordinates.

`color_map` is a table where keys are integer cell values and values are packed `0xRRGGBBAA` colors.

If `default_color` is provided, cell values not found in `color_map` are written as `default_color`. If `default_color` is omitted, unknown cell values error.

```lua
raster.new_pixelmap_from_datagrid(datagrid, color_map, default_color?) -> pixelmap

--example usage
pmap = raster.new_pixelmap_from_datagrid(terrain, {
    [0] = rgba("#000000"),
    [1] = rgba("#FFFFFF"),
    [2] = rgba("#3366FF"),
}, rgba("#FF00FF"))
```

#### Returns

`pixelmap` with the same width and height as `datagrid`.

#### Error Cases

- Datagrid has been freed.
- `color_map` keys must be integers.
- `color_map` values must be color integers.
- `default_color` must be a color integer.
- A cell value is not present in `color_map` and `default_color` is omitted.

## Raster Drawing

Raster drawing writes shapes and pixels into Pixelmaps in CPU memory. Freed Pixelmaps and fully clipped shapes are ignored.

`color` arguments default to `0xFFFFFFFF`. `mode` arguments default to `"blend"`.

Blend modes affect Pixelmap memory only. They are separate from the GPU blend mode set by `graphics.set_blend_mode`.

| Mode | Meaning | Common use |
|---|---|---|
| `"blend"` | Alpha-blends the source color over the destination pixel. | Normal translucent drawing. |
| `"replace"` | Writes the source color directly, including alpha. | Stamps, clearing regions, exact pixel writes. |
| `"add"` | Adds source RGB into destination RGB using source alpha. Adds source alpha into destination alpha. | Glow, light, heat, additive effects. |
| `"multiply"` | Multiplies destination RGB by source RGB. Keeps destination alpha. | Darkening, tint masks, shadow-like effects. |
| `"erase"` | Reduces destination alpha using source alpha. Keeps destination RGB. | Cutting holes, soft erasing, masks. |
| `"mask"` | Multiplies destination alpha by source alpha. Keeps destination RGB. | Applying an alpha mask. |

### blit

Copies one Pixelmap into another.

```lua
raster.blit(dst, src, dx, dy, mode?)
```

---

### blit_region

Copies a rectangular region from one Pixelmap into another.

```lua
raster.blit_region(dst, src, sx, sy, w, h, dx, dy, mode?)
```

---

### blit_rect

Draws a filled rectangle into a Pixelmap.

```lua
raster.blit_rect(pixelmap, x, y, w, h, color?, mode?)
```

---

### blit_line

Draws a 1-pixel line into a Pixelmap.

```lua
raster.blit_line(pixelmap, x1, y1, x2, y2, color?, mode?)
```

---

### blit_triangle

Draws a filled triangle into a Pixelmap.

```lua
raster.blit_triangle(pixelmap, x1, y1, x2, y2, x3, y3, color?, mode?)
```

---

### blit_circle

Draws a filled circle into a Pixelmap.

```lua
raster.blit_circle(pixelmap, cx, cy, radius, color?, mode?)
```

---

### blit_ring

Draws a thick circular ring into a Pixelmap.

```lua
raster.blit_ring(pixelmap, cx, cy, radius, thickness, color?, mode?)
```

---

### blit_circle_pixel_outline

Draws a 1-pixel circle outline into a Pixelmap using integer circle rasterization.

```lua
raster.blit_circle_pixel_outline(pixelmap, cx, cy, radius, color?, mode?)
```

---

### blit_capsule

Draws a thick rounded line into a Pixelmap.

```lua
raster.blit_capsule(pixelmap, x1, y1, x2, y2, radius, color?, mode?)
```

## Pixel Access & Analysis

### set_pixel

Writes a pixel directly without blending. Out-of-bounds writes are ignored.

```lua
raster.set_pixel(pixelmap, x, y, color)
```

---

### get_pixel

Returns the raw pixel color at an in-bounds position.

```lua
raster.get_pixel(pixelmap, x, y) -> color | nil
```

#### Returns

`color` for an in-bounds read from a live Pixelmap.  
`nil` for an out-of-bounds read, or if `pixelmap` has been freed.

---

### flood_fill

Flood-fills from a starting point using the target color under that point. Out-of-bounds starts are ignored.

```lua
raster.flood_fill(pixelmap, x, y, color)
```

---

### raycast

Traces a line and returns the first non-transparent pixel it hits.

```lua
raster.raycast(pixelmap, x1, y1, x2, y2) -> true, x, y, color | false
```

#### Returns

`true, x, y, color` on hit.  
`false` on miss, or if `pixelmap` has been freed.

## Memory

### clone_pixelmap

Creates a deep copy of a Pixelmap.

```lua
raster.clone_pixelmap(pixelmap) -> pixelmap
```

#### Error Cases

- `pixelmap` must be live.

---

### get_pixelmap_cptr

Returns a raw C pointer to the Pixelmap's pixel memory for LuaJIT FFI.

```lua
raster.get_pixelmap_cptr(pixelmap) -> ptr | nil
```

#### Returns

A `lightuserdata` pointer for a live Pixelmap.  
`nil` if `pixelmap` has been freed.

The returned pointer is valid only while the Pixelmap is live.