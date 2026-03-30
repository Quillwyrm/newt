
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

//---------------------------------------------
// GRAPHICS TODO
//---------------------------------------------

// -- GPU Primitives
// .draw_line(x1, y1, x2, y2, [color])
// .draw_rect_lines(x, y, w, h, [color])
// .draw_poly(points_table, [color])
// .draw_poly_lines(points_table, [color])
// .set_scissor(x, y, w, h) // GPU Clipping [cite: 1]

// -- Render Targets (Canvases) 
// .set_canvas(img | nil) 
// .new_canvas(w, h) -> img

// -- Shaders (Fragment Intercepts)
// .set_draw_shader(shader, [uniforms])
// .set_screen_shader(shader, [uniforms])

// -- Text & Fonts [cite: 4]
// .load_font(path, size) -> font
// .draw_text(font, text, x, y, [color])

// -- Animation System [cite: 5]
// .draw_animation(anim, x, y, [color]) // Odin-side cell math helper


