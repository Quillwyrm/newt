
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

# SHADER SYSTEM PIPELINE

### 1. Offline Compilation (The Tooling)
SDL3's 2D renderer needs specific bytecode for the host GPU (SPIR-V for Vulkan, DXIL for D3D12, MSL for Metal). You do not compile text shaders at runtime.
* Write your fragment shader in standard GLSL or HLSL.
* Run it through the **`SDL_shadercross`** CLI tool during your build step.
* Output: Pre-compiled `.bin` files that you ship with your engine assets.

### 2. The Lua API Surface
```lua
-- Load the pre-compiled bytecode
shader = graphics.load_shader("path/to/shader.bin")

-- Draw a sprite using the shader
-- uniforms: Flat array of numbers (e.g. {time, intensity})
-- samplers: Flat array of image objects
graphics.set_draw_shader(shader, uniforms, samplers)
graphics.draw_sprite(...)

-- Apply fullscreen post-processing
graphics.set_screen_shader(shader, uniforms, samplers)
```

### 3. Odin Backend & SDL3 Mechanism
The system relies on hijacking the standard `SDL_Renderer` pipeline right before a draw call.

**A. Initialization (`load_shader`)**
* **Call:** `sdl.CreateGPURenderState(renderer, &info)`
* **System:** You construct an `sdl.GPURenderStateCreateInfo` struct, point it to the loaded bytecode `.bin` in memory, and get an opaque state handle back. This handle is wrapped in Lua userdata.

**B. Uniforms & Samplers (Data Binding)**
* **Uniforms Call:** `sdl.SetGPURenderStateFragmentUniforms(renderer, state, raw_data, size)`
    * **System:** Odin takes the Lua `{1.0, 0.5}` array, copies it into a flat temporary `[]f32` buffer, and hands the raw pointer to SDL. This maps directly to the byte-alignment expected by the GPU uniform block.
* **Samplers Call:** `sdl.SetGPURenderStateFragmentSamplers(renderer, state, texture_array, count)`
    * **System:** Odin extracts the `^sdl.Texture` pointers from your Lua Image userdata and passes them as an array. Index 0 is reserved for the primary sprite being drawn; your custom samplers bind to 1, 2, etc.

**C. Execution Pipeline (`set_draw_shader`)**
When the user calls `draw_sprite` while a shader is active, the engine executes this exact stack:
1. `sdl.SetGPURenderState(renderer, state)`: Intercepts the default pipeline.
2. `sdl.SetGPURenderStateFragmentUniforms(...)`: Pushes the float data.
3. `sdl.SetGPURenderStateFragmentSamplers(...)`: Pushes the extra textures.
4. `sdl.RenderGeometry(...)`: Submits the vertices. The custom fragment shader executes.
5. `sdl.SetGPURenderState(renderer, nil)`: Resets the pipeline so the next draw call is normal.

**D. Post-Processing (`set_screen_shader`)**
* **System:** Identical to the draw execution stack, but instead of wrapping a `RenderGeometry` call, you wrap the final `sdl.RenderTexture()` call that blits your low-res virtual canvas to the physical window at the end of the frame.

//---------------------------------------------
// GRAPHICS TODO
//---------------------------------------------

// -- Shaders (Fragment Intercepts)
// .set_draw_shader(shader, [uniforms])
// .set_screen_shader(shader, [uniforms])

// -- Text & Fonts [cite: 4]
// .load_font(path, size) -> font
// .draw_text(font, text, x, y, [color])



