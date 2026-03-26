
# IMAGE API
```lua
-- graphics.function()

-- IO & Allocation

img   = load_image("file.png")                     --load image from disk with path.

atlas = load_atlas("file.png", 16, 16)             --load `Atlas` from image with path and cell dimentions


-- Drawing (Implicit Verbs)

image(x, y, img, color?)                           --draw an entire image

image_region(x, y, img, rx, ry, rw, rh, color?)    --draw a specified region of an image by passing the source rect. 

sprite(x, y, atlas, idx, color?)                   --draw a sprite from an atlas with an index


-- Transform Pipeline - Volatile State (Applies to next draw only)

set_draw_rotation(r)                               --set rotation of the next compatible draw call

set_draw_scale(sx, sy)                             --set scale of the next compatible draw call

set_draw_origin(ox, oy)                            --set offset from top-left origin of the next compatible draw calls

-- blending modes

set_draw_blendmode(mode)
```
---
# IMAGE READ/WRITE (pixelmap)

```lua
pixelmap = load_pixelmap(image_path)

--read/write
get_pixel(pixelmap,clr,x,y)
set_pixel(pixelmap,x,y) -> clr
set_pixelmap(srcmap, dstmap)

  --bad names 
  --but the idea of circ/rect writers
write_circ
write_rect


-- conversion
new_image_from_pixelmap(pixelmap)
update_image_from_pixelmap(image, pixelmap)

--saving
save_pixelmap(pixelmap, output_name)
```

*example*:
```lua
-- 1. Load the PNG into system RAM (CPU)
local col_map = graphics.load_pixelmap("collision.png")

-- 2. Read pixels instantly for game logic (Zero GPU stall)
local r, g, b, a = graphics.get_pixel(col_map, 10, 5)
if r == 255 then
    print("Hit a wall!")
end

-- 3. Modify pixels if you want (e.g., dynamic destruction)
graphics.set_pixel(col_map, 10, 5, 0, 0, 0, 255)

-- 4. When ready, upload it to the GPU to be drawn
local col_image = graphics.new_image_from_pixelmap(col_map)

-- 5. Draw it using the fast Renderer path
graphics.image(col_image, 0, 0)
```

---

# SHADER API 
```lua

shader = load_shader(bin_path)

set_draw_shader(shader, uniforms, samplers)

set_screen_shader(shader, uniforms, samplers)
```

The SDL3 function that makes it possible is `SDL_SetGPURenderState`.

To be precise on the Odin backend, you will use two main calls:
* `SDL_CreateGPURenderState`: Used during initialization to create the state object containing the shader handle.
* `SDL_SetGPURenderState(renderer, state)`: Used during the draw loop to intercept the standard renderer pipeline.

How your Lua API maps to it:
* `set_draw_shader`: Binds the state, pushes your float array via `SDL_SetGPURenderStateFragmentUniforms`, draws the specific sprite, then calls `SDL_SetGPURenderState(renderer, nil)` to reset.
* `set_screen_shader`: Binds the state right before you draw your main virtual canvas texture to the window at the end of the frame.


