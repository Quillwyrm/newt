# graphics

The `graphics` module provides GPU drawing, images, canvases, render state, transforms, text rendering, and debug drawing.

For CPU-side Pixelmaps, software raster operations, and per-pixel access, see [`raster`](raster.md).

Unless noted otherwise, functions in this module throw on wrong arity or wrong argument types. Query functions on freed resources return nil-shaped results where documented.

## Functions

**Drawing**
* [`draw_image`](#draw_image)
* [`draw_image_region`](#draw_image_region)
* [`draw_rect`](#draw_rect)
* [`clear`](#clear)

**Images & Canvases**
* [`load_image`](#load_image)
* [`get_image_size`](#get_image_size)
* [`set_default_filter`](#set_default_filter)
* [`new_canvas`](#new_canvas)
* [`set_canvas`](#set_canvas)

**Render State**
* [`set_blend_mode`](#set_blend_mode)
* [`set_clip_rect`](#set_clip_rect)
* [`get_clip_rect`](#get_clip_rect)

**Transforms**
* [`begin_transform`](#begin_transform)
* [`end_transform`](#end_transform)
* [`set_translation`](#set_translation)
* [`set_rotation`](#set_rotation)
* [`set_scale`](#set_scale)
* [`set_origin`](#set_origin)
* [`use_screen_space`](#use_screen_space)
* [`screen_to_local`](#screen_to_local)
* [`local_to_screen`](#local_to_screen)

**Text & Fonts**
* [`load_font`](#load_font)
* [`set_font`](#set_font)
* [`draw_text`](#draw_text)
* [`draw_text_wrap`](#draw_text_wrap)
* [`set_text_alignment`](#set_text_alignment)

**Font Queries**
* [`get_font_height`](#get_font_height)
* [`get_font_ascent`](#get_font_ascent)
* [`get_font_descent`](#get_font_descent)
* [`get_font_line_skip`](#get_font_line_skip)
* [`measure_text`](#measure_text)
* [`measure_text_wrap`](#measure_text_wrap)
* [`measure_text_fit`](#measure_text_fit)
* [`font_has_glyph`](#font_has_glyph)
* [`get_glyph_metrics`](#get_glyph_metrics)

**Debug Drawing**
* [`debug_text`](#debug_text)
* [`debug_line`](#debug_line)
* [`debug_rect`](#debug_rect)

**Images From Pixelmaps**
* [`new_image_from_pixelmap`](#new_image_from_pixelmap)
* [`update_image_from_pixelmap`](#update_image_from_pixelmap)
* [`update_image_region_from_pixelmap`](#update_image_region_from_pixelmap)

## Drawing

### draw_image

Draws a full image at the given position. A freed image is ignored.

```lua
graphics.draw_image(image, x, y, color?)
```

---

### draw_image_region

Draws a rectangular region of an image. Source coordinates and size are in pixels. A freed image is ignored.

```lua
graphics.draw_image_region(image, sx, sy, sw, sh, dx, dy, color?)
```

---

### draw_rect

Draws a solid rectangle that uses the current transform and render state.

```lua
graphics.draw_rect(x, y, w, h, color?)
```

---

### clear

Clears the active render target. This clears the screen, or the current canvas if one is set.

```lua
graphics.clear(color?)
```

## Images & Canvases  
Images are GPU resources used for drawing. A canvas is an `Image` created with `graphics.new_canvas()` that can also be used as a render target.

### load_image

Loads an image into GPU memory. Newly loaded images use the current default filter.

```lua
graphics.load_image(path) -> image | nil, err
```

---

### get_image_size

Returns the pixel dimensions of an image.

```lua
graphics.get_image_size(image) -> width, height | nil, nil
```

#### Returns

`width` and `height` for a live image.  
`nil, nil` if `image` has been freed.

---

### set_default_filter

Sets the default scale filter used for images created after this call.

```lua
graphics.set_default_filter(mode)
```

#### Error Cases

- `mode` must be `"nearest"` or `"linear"`.

---

### new_canvas

Creates an `Image` resource that can be used as a render target. Canvases use the current default filter.

Canvases keep their contents until they are cleared or drawn over. Call [`graphics.clear`](#clear) after setting a canvas when you want to redraw it from scratch.

```lua
graphics.new_canvas(width, height) -> canvas
```

#### Returns

`Image` resource created for use as a render target.

#### Error Cases

- `width` and `height` must be positive.

---

### set_canvas

Sets the active render target. Pass `nil` to return drawing to the screen.

```lua
graphics.set_canvas(canvas)
graphics.set_canvas(nil)
```

#### Error Cases

- `canvas` must be an `Image` resource created with `graphics.new_canvas()`.

---

## Render State

### set_blend_mode

Sets the hardware blend mode used by subsequent draw calls. With no argument or `nil`, the mode resets to `"blend"`.

```lua
graphics.set_blend_mode(mode?)
```

#### Error Cases

- `mode` must be `"blend"`, `"replace"`, `"add"`, `"multiply"`, `"modulate"`, or `"premultiplied"`.

---

### set_clip_rect

Sets a hardware clip rectangle in absolute screen coordinates. With no arguments, clipping is disabled.

```lua
graphics.set_clip_rect()
graphics.set_clip_rect(x, y, w, h)
```

---

### get_clip_rect

Returns the current clip rectangle in absolute screen coordinates. When clipping is disabled, this returns `nil, nil, nil, nil`.

```lua
graphics.get_clip_rect() -> x, y, w, h | nil, nil, nil, nil
```

---

## Transforms

### begin_transform

Pushes the current transform onto the stack. Use this to scope later transform changes.

```lua
graphics.begin_transform()
```

#### Error Cases

- The transform stack cannot exceed 32 levels.

---

### end_transform

Pops the current transform from the stack.

```lua
graphics.end_transform()
```

#### Error Cases

- There must be an active transform level to end.

---

### set_translation

Applies a translation to the current transform.

```lua
graphics.set_translation(x, y)
```

---

### set_rotation

Applies a rotation, in radians, to the current transform.

```lua
graphics.set_rotation(radians)
```

---

### set_scale

Applies scaling to the current transform. When `sy` is omitted, it defaults to `sx`.

```lua
graphics.set_scale(sx, sy?)
```

---

### set_origin

Sets the origin used by subsequent scaling and rotation in the current transform.

```lua
graphics.set_origin(ox, oy)
```

---

### use_screen_space

Resets the current transform to screen space at the current stack level.

```lua
graphics.use_screen_space()
```

---

### screen_to_local

Converts a screen-space position into the current local transform space.

```lua
graphics.screen_to_local(sx, sy) -> lx, ly
```

---

### local_to_screen

Converts a local-space position through the current transform into screen coordinates.

```lua
graphics.local_to_screen(lx, ly) -> sx, sy
```

## Text & Fonts

A built-in default font is available from startup. `graphics.set_font()` and `graphics.set_font(nil)` reset to it.

### load_font

Loads a font at a fixed pixel size.

```lua
graphics.load_font(path, size) -> font | nil, err
```

#### Returns

A `Font` resource.

---

### set_font

Sets the active font used by text drawing. With no argument or `nil`, this resets to the built-in default font. Passing a freed font also resets to the built-in default font.

```lua
graphics.set_font()
graphics.set_font(nil)
graphics.set_font(font)
```

---

### draw_text

Draws text using the active font. This is newline-aware and does not perform width wrapping.

```lua
graphics.draw_text(text, x, y, color?)
```

---

### draw_text_wrap

Draws wrapped text using the active font and active text alignment.

```lua
graphics.draw_text_wrap(text, x, y, width, color?)
```

#### Error Cases

- `width` must be positive.

---

### set_text_alignment

Sets the active alignment used by wrapped text drawing.

```lua
graphics.set_text_alignment(mode)
```

#### Error Cases

- `mode` must be `"left"`, `"center"`, or `"right"`.

---

## Font Queries

Unless noted otherwise, these functions use the built-in default font when `font` is omitted or `nil`. Passing a freed explicit `Font` returns nil-shaped results where documented.

### get_font_height

Returns the font height.

```lua
graphics.get_font_height() -> height
graphics.get_font_height(font) -> height | nil
```

#### Returns

`height` for the default font, or for a live explicit `font`.  
`nil` if an explicit `font` has been freed.

---

### get_font_ascent

Returns the font ascent.

```lua
graphics.get_font_ascent() -> ascent
graphics.get_font_ascent(font) -> ascent | nil
```

#### Returns

`ascent` for the default font, or for a live explicit `font`.  
`nil` if an explicit `font` has been freed.

---

### get_font_descent

Returns the font descent.

```lua
graphics.get_font_descent() -> descent
graphics.get_font_descent(font) -> descent | nil
```

#### Returns

`descent` for the default font, or for a live explicit `font`.  
`nil` if an explicit `font` has been freed.

---

### get_font_line_skip

Returns the line spacing for the font.

```lua
graphics.get_font_line_skip() -> line_skip
graphics.get_font_line_skip(font) -> line_skip | nil
```

#### Returns

`line_skip` for the default font, or for a live explicit `font`.  
`nil` if an explicit `font` has been freed.

---

### measure_text

Measures text using the active font, or a specific font override.

```lua
graphics.measure_text(text, font?) -> width, height | nil, nil
```

#### Returns

`nil, nil` is returned only when `font` is passed and has been freed.

---

### measure_text_wrap

Measures wrapped text using the active font, or a specific `font` when passed.

```lua
graphics.measure_text_wrap(text, width, font?) -> width, height | nil, nil
```

#### Returns

`nil, nil` is returned only when `font` is passed and has been freed.

---

### measure_text_fit

Measures how much text fits within `width` using the active font, or a specific `font` when passed.

```lua
graphics.measure_text_fit(text, width, font?) -> fit_width, fit_length | nil, nil
```

#### Returns

`nil, nil` is returned only when `font` is passed and has been freed.

---

### font_has_glyph

Reports whether a glyph exists in the active font, or a specific `font` when passed.

```lua
graphics.font_has_glyph(codepoint, font?) -> bool | nil
```

#### Returns

`nil` is returned only when `font` is passed and has been freed.

---

### get_glyph_metrics

Returns glyph metrics from the active font, or a specific `font` when passed.

```lua
graphics.get_glyph_metrics(codepoint, font?) -> minx, maxx, miny, maxy, advance | nil, nil, nil, nil, nil
```

#### Returns

`nil, nil, nil, nil, nil` is returned only when `font` is passed and has been freed.

---

## Debug Drawing

These functions draw in absolute active-render-target coordinates and ignore the current transform.

### debug_text

Draws simple debug text.

```lua
graphics.debug_text(x, y, text, color?)
```

---

### debug_line

Draws a 1-pixel line.

```lua
graphics.debug_line(x1, y1, x2, y2, color?)
```

---

### debug_rect

Draws a 1-pixel hollow rectangle.

```lua
graphics.debug_rect(x, y, w, h, color?)
```

## Images From Pixelmaps

Pixelmaps are editable CPU-side image data from [`raster`](raster.md). These functions create or update GPU `Image` resources from Pixelmap data so they can be drawn with `graphics`.

### new_image_from_pixelmap

Creates an `Image` from a Pixelmap. The new image uses the current default filter.

```lua
graphics.new_image_from_pixelmap(pixelmap) -> image
```

#### Error Cases

- Throws if `pixelmap` has been freed.

---

### update_image_from_pixelmap

Copies an entire Pixelmap into an existing image at an optional destination offset. Freed resources are ignored.

```lua
graphics.update_image_from_pixelmap(image, pixelmap, dx?, dy?)
```
##### Error Cases
- If the destination region is out of bounds.
- If the GPU texture upload fails.

---

### update_image_region_from_pixelmap

Copies a region of a Pixelmap into an existing image. Invalid regions and freed resources are ignored.

```lua
graphics.update_image_region_from_pixelmap(image, pixelmap, sx, sy, w, h, dx, dy)
```

#### Error Cases
- if w or h is not positive.
- if the source region is out of bounds.
- if the destination region is out of bounds.
- if the GPU texture upload fails.
