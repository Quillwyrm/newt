That’s great practice getting the API docs updated while the architecture is fresh in your head. I don't need the repo link right now unless you made massive structural changes outside of `api_graphics.odin` that affect our pipeline. 

You left off at **Ground Zero**: The old `FRect` rendering is completely purged. You have a clean Odin state, the new `u32rgba` type, and your shadow state syncing perfectly for `clear` and `draw_debug_text`.

Here is the exact roadmap for the rest of the graphics refactor, broken into sequential tasks:

### Phase 1: The Bare Metal Pipeline
1. **The Geometry Submitter:** Write the internal `draw_image_geometry` helper. It will take a texture and hardcoded screen coordinates, pack 4 `sdl.Vertex` structs (unpacking `u32rgba` to `sdl.FColor`), and call `sdl.RenderGeometry`. No matrices yet.
2. **The Lua Wire-up:** Rebind `graphics.draw_image` to call this new submitter. 
*Goal: Prove you can render a flat, un-transformed sprite using the new vertex pipeline.*

### Phase 2: The Linear Algebra Engine
3. **The Matrix Composer:** Write the Odin internal procedure that takes your `Pending_Transform` struct (translation, rotation, scale, origin) and uses `core:math/linalg` to build a strictly ordered local `matrix[3,3]f32`.
4. **The Vertex Transformer:** Update the Geometry Submitter to accept a 3x3 matrix. Multiply the 4 local corners of your image quad against this matrix before packing them into the `sdl.Vertex` array.
*Goal: Prove a single sprite can be moved, scaled, and rotated around its origin using matrix math.*

### Phase 3: The Hierarchical Stack
5. **The Verbs:** Implement `lua_graphics_begin_transform_group` and `lua_graphics_end_transform_group`. These will compose a matrix from the pending state, multiply it against the current top of the global `transform_stack`, and push/pop the result.
6. **The Final Link:** Update `draw_image` to multiply its local matrix against the top of the global stack before submitting vertices.
*Goal: Prove nested groups, UI coordinate spaces, and camera views work flawlessly.*

### Phase 4: Restoration
7. **The Variants:** Re-implement `draw_image_region`, `draw_sprite`, and `draw_rect` by feeding different UV coordinates and textures into your unified Geometry Submitter.

Would you like to start by mapping out the raw `sdl.Vertex` layout for Phase 1?