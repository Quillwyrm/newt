package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:math"
import "core:c"
import "core:math/linalg"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import "vendor:sdl3/ttf"
import lua "luajit"

//TODO:

// Primitives: draw_line, 1px unfilled rects, and draw_poly (plus unfilled variant). ect.

// Render Targets: Support for rendering to textures.

// Blend Modes: Global or per-draw blending control.

// Scissor/clip rect

// Text & Fonts: Integration with SDL_ttf for font loading and text rendering.

// Animation System: Logic for handling sprite/atlas frames over time.

// Shaders (see notes)

//DONE!!!  
//TRANSFORMS
//Image IO
//Image drawing prims (GPU) ****
//Atlas/Sprite idx system
//transform pipeline (scale/rot/origin) 
//Pixelmap API (CPU Read/Write)

//=========================================================================================
// GRAPHICS API: STATE, TYPES & HELPERS
//=========================================================================================

//TYPES---------

// Image represents a hardware texture allocated in GPU VRAM.
Image :: struct {
  texture: ^sdl.Texture,
  width:   f32,
  height:  f32,
}

Atlas :: struct {
	image:  Image, 
	cell_w: f32,
	cell_h: f32,
	cols:   int,
	rows:   int,
}

Pixelmap :: struct {
    surface: ^sdl.Surface,
}

u32rgba :: distinct u32

Gfx_Ctx: struct {
	current_sdl_color:  u32rgba, 
	default_scale_mode: sdl.ScaleMode,

	transform : struct {
		matrix_stack: [32]matrix[3, 3]f32,
		group_depth:  int,
	}
}




//HELPERS---------

// CPU state only. Safe to call at boot.
init_graphics_state :: proc() {
	Gfx_Ctx.current_sdl_color = u32rgba(0xFFFFFFFF)
	Gfx_Ctx.default_scale_mode = .LINEAR
	
	// '1' is the Odin literal for an Identity Matrix
	Gfx_Ctx.transform.matrix_stack[0] = 1 
	Gfx_Ctx.transform.group_depth = 0
}

// load_image_from_path handles the hardware-level pipeline: Disk -> CPU RAM -> GPU VRAM.
// Returns an Image struct and a success boolean.
load_image_from_path :: proc(path: cstring) -> (Image, bool) {
	// 1. DECODE: Load the PNG from disk into CPU RAM.
	w, h, channels: c.int
	pixels := stbi.load(path, &w, &h, &channels, 4)
	if pixels == nil do return {}, false
	defer stbi.image_free(pixels)

	// 2. ALLOCATE VRAM: Create hardware texture.
	texture := sdl.CreateTexture(Renderer, .RGBA32, .STATIC, w, h)
	if texture == nil do return {}, false

	// 3. UPLOAD: Push decoded bytes to GPU and set alpha blending.
	sdl.UpdateTexture(texture, nil, pixels, w * 4)
	sdl.SetTextureBlendMode(texture, {.BLEND})
	
	// Apply the global filter preference immediately
	sdl.SetTextureScaleMode(texture, Gfx_Ctx.default_scale_mode)

	return Image{texture, f32(w), f32(h)}, true
}

set_global_sdl_color :: proc(c: u32rgba) {
    if Gfx_Ctx.current_sdl_color != c {
        r := u8((u32(c) >> 24) & 0xFF)
        g := u8((u32(c) >> 16) & 0xFF)
        b := u8((u32(c) >> 8)  & 0xFF)
        a := u8(u32(c) & 0xFF)
        sdl.SetRenderDrawColor(Renderer, r, g, b, a)
        Gfx_Ctx.current_sdl_color = c
    }
}

unpack_fcolor :: #force_inline proc(c: u32rgba) -> sdl.FColor {
	return sdl.FColor{
		f32((u32(c) >> 24) & 0xFF) / 255.0,
		f32((u32(c) >> 16) & 0xFF) / 255.0,
		f32((u32(c) >> 8)  & 0xFF) / 255.0,
		f32(u32(c) & 0xFF)         / 255.0,
	}
}

// ---------------------------------------------------------
// RENDER GEOMETRY PIPELINE
// ---------------------------------------------------------

// draw_image_geometry submits a flat, un-transformed quad to the GPU.
draw_image_geometry :: proc(tex: ^sdl.Texture, x, y, w, h: f32, color: u32rgba, m: matrix[3, 3]f32) {
	fc := unpack_fcolor(color)

	// Apply the local X/Y offsets directly to the vertices BEFORE multiplying by the world matrix.
	tl := (m * [3]f32{x, y, 1}).xy
	tr := (m * [3]f32{x + w, y, 1}).xy
	br := (m * [3]f32{x + w, y + h, 1}).xy
	bl := (m * [3]f32{x, y + h, 1}).xy

	verts := [4]sdl.Vertex{
		{ position = cast(sdl.FPoint)tl, color = fc, tex_coord = {0.0, 0.0} },
		{ position = cast(sdl.FPoint)tr, color = fc, tex_coord = {1.0, 0.0} },
		{ position = cast(sdl.FPoint)br, color = fc, tex_coord = {1.0, 1.0} },
		{ position = cast(sdl.FPoint)bl, color = fc, tex_coord = {0.0, 1.0} },
	}

	indices := [6]c.int{0, 1, 2, 0, 2, 3}

	sdl.RenderGeometry(Renderer, tex, raw_data(verts[:]), 4, raw_data(indices[:]), 6)
}

// ---------------------------------------------------------
// PIXELMAP GEOMETRY & INTERNAL HELPERS
// ---------------------------------------------------------

// Helper to flip Lua's 0xRRGGBBAA to the physical 0xAABBGGRR memory layout.
// This compiles down to a single CPU bswap instruction.
u32_rgba_to_abgr :: #force_inline proc(c: u32) -> u32 {
	return (c >> 24) | ((c >> 8) & 0xFF00) | ((c << 8) & 0x00FF0000) | (c << 24)
}

//=========================================================================================
// GRAPHICS API: LUA BINDINGS
//=========================================================================================

// lua_graphics_draw_image implements: graphics.draw_image(img, x, y, [color])
lua_graphics_draw_image :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()

  // L_checkudata throws a Lua error if arg 1 is missing or wrong type
  img := cast(^Image)lua.L_checkudata(L, 1, cstring("Image_Meta"))
  if img == nil || img.texture == nil do return 0

  x := f32(lua.L_checknumber(L, 2))
  y := f32(lua.L_checknumber(L, 3))
  raw_color := lua.L_optinteger(L, 4, 0xFFFFFFFF)

  world_m := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]
  draw_image_geometry(img.texture, x, y, img.width, img.height, u32rgba(raw_color), world_m)

  return 0
}

// lua_graphics_clear implements: graphics.clear([color])
// Clears the entire render target. Defaults to black.
lua_graphics_clear :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()

  raw_color := lua.L_optinteger(L, 1, 0x000000FF)
  set_global_sdl_color(u32rgba(raw_color))
  sdl.RenderClear(Renderer)

  return 0
}

// lua_graphics_draw_debug_text implements: graphics.draw_debug_text(x, y, text, [color])
// Draws simple 8x8 bitmap text to the screen for debugging purposes.
lua_graphics_draw_debug_text :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()

  x := cast(f32)lua.L_checknumber(L, 1)
  y := cast(f32)lua.L_checknumber(L, 2)

  text_len: c.size_t
  text_c := lua.L_checklstring(L, 3, &text_len)

  raw_color := lua.L_optinteger(L, 4, 0xFFFFFFFF)
  set_global_sdl_color(u32rgba(raw_color))

  if !sdl.RenderDebugText(Renderer, x, y, text_c) {
    fmt.eprintln("Debug text failed:", sdl.GetError())
  }

  return 0
}

/////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////

// lua_graphics_begin_transform implements: graphics.begin_transform()
lua_graphics_begin_transform :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if Gfx_Ctx.transform.group_depth >= 31 {
		lua.L_error(L, cstring("Transform stack overflow: Max depth is 32."))
		return 0
	}

	current_m := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]
	
	Gfx_Ctx.transform.group_depth += 1
	Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth] = current_m

	return 0
}

// lua_graphics_end_transform implements: graphics.end_transform()
lua_graphics_end_transform :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if Gfx_Ctx.transform.group_depth == 0 {
		lua.L_error(L, cstring("Transform stack underflow: No group to end."))
		return 0
	}

	Gfx_Ctx.transform.group_depth -= 1
	return 0
}

// graphics.use_screen_space()
// Wipes all inherited transforms (position, rotation, scale) for the current block, 
// allowing you to draw directly to absolute screen coordinates.
// Use this for: Drawing flat UI, nameplates, or targeting brackets while inside a transformed entity.
// Note: This effect is scoped and ends as soon as graphics.end_transform() is called.
lua_graphics_use_screen_space :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	// '1' is the Odin literal for a clean slate matrix
	Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth] = 1 
	
	return 0
}

// lua_graphics_set_translation implements: graphics.set_translation(x, y)
lua_graphics_set_translation :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	tx := f32(lua.L_checknumber(L, 1))
	ty := f32(lua.L_checknumber(L, 2))

	T := matrix[3, 3]f32{
		1, 0, tx,
		0, 1, ty,
		0, 0, 1,
	}
	
	depth := Gfx_Ctx.transform.group_depth
	Gfx_Ctx.transform.matrix_stack[depth] *= T
	return 0
}

// lua_graphics_set_rotation implements: graphics.set_rotation(radians)
lua_graphics_set_rotation :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	r := f32(lua.L_checknumber(L, 1))
	c := math.cos(r)
	s := math.sin(r)

	R := matrix[3, 3]f32{
		c, -s, 0,
		s,  c, 0,
		0,  0, 1,
	}

	depth := Gfx_Ctx.transform.group_depth
	Gfx_Ctx.transform.matrix_stack[depth] *= R
	return 0
}

// lua_graphics_set_scale implements: graphics.set_scale(sx, [sy])
// sy defaults to sx if omitted for uniform scaling.
lua_graphics_set_scale :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	sx := f32(lua.L_checknumber(L, 1))
	sy := f32(lua.L_optnumber(L, 2, lua.Number(sx)))
	
	S := matrix[3, 3]f32{
		sx, 0,  0,
		0,  sy, 0,
		0,  0,  1,
	}

	depth := Gfx_Ctx.transform.group_depth
	Gfx_Ctx.transform.matrix_stack[depth] *= S
	return 0
}

// lua_graphics_set_origin implements: graphics.set_origin(ox, oy)
lua_graphics_set_origin :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	ox := f32(lua.L_checknumber(L, 1))
	oy := f32(lua.L_checknumber(L, 2))

	O := matrix[3, 3]f32{
		1, 0, -ox,
		0, 1, -oy,
		0, 0, 1,
	}

	depth := Gfx_Ctx.transform.group_depth
	Gfx_Ctx.transform.matrix_stack[depth] *= O
	return 0
}

// graphics.screen_to_local(x, y) -> lx, ly
// Reverses the active transform stack to convert a screen coordinate into the current local space.
// Use this for: Checking if the mouse is hovering over a rotated or scaled entity.
lua_graphics_screen_to_local :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()

  sx := f32(lua.L_checknumber(L, 1))
  sy := f32(lua.L_checknumber(L, 2))

  m   := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]
  inv := linalg.inverse(m)
  local_pos := (inv * [3]f32{sx, sy, 1.0}).xy

  lua.pushnumber(L, cast(lua.Number)local_pos.x)
  lua.pushnumber(L, cast(lua.Number)local_pos.y)
  return 2
}

// graphics.local_to_screen(lx, ly) -> sx, sy
// Applies the active transform stack to convert a local coordinate into an absolute screen coordinate.
// Use this for: Finding exactly where an entity is on the screen to draw a UI element over it.
lua_graphics_local_to_screen :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()

  lx := f32(lua.L_checknumber(L, 1))
  ly := f32(lua.L_checknumber(L, 2))

  m := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]
  screen_pos := (m * [3]f32{lx, ly, 1.0}).xy

  lua.pushnumber(L, cast(lua.Number)screen_pos.x)
  lua.pushnumber(L, cast(lua.Number)screen_pos.y)
  return 2
}


/////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////

// lua_graphics_load_image implements: graphics.load_image(path) -> Image | nil, err
lua_graphics_load_image :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 1 {
        lua.L_error(L, cstring("graphics.load_image expects 1 argument: path"))
        return 0
    }

    path_cstr := cast(cstring)lua.L_checklstring(L, 1, nil)

    // 1. LOAD: Dispatch to the hardware-level helper.
    img, ok := load_image_from_path(path_cstr)
    if !ok {
        lua.pushnil(L)
        lua.pushstring(L, cstring("Failed to load image texture"))
        return 2
    }

    // 2. BIND TO LUA: Allocate userdata and copy the Image POD.
    data := cast(^Image)lua.newuserdata(L, size_of(Image))
    data^ = img

    // 3. ATTACH SAFETY NET: Apply the metatable for GC.
    lua.L_getmetatable(L, cstring("Image_Meta"))
    lua.setmetatable(L, -2)

    return 1
}

// lua_graphics_load_atlas implements: graphics.load_atlas(path, cell_w, cell_h) -> Atlas | nil, err
lua_graphics_load_atlas :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) != 3 {
        lua.L_error(L, cstring("graphics.load_atlas expects 3 args: path, cell_w, cell_h"))
        return 0
    }

    path_cstr := cast(cstring)lua.L_checklstring(L, 1, nil)
    cell_w    := f32(lua.L_checknumber(L, 2))
    cell_h    := f32(lua.L_checknumber(L, 3))

    // 1. LOAD: Reuse the hardware-level helper.
    img, ok := load_image_from_path(path_cstr)
    if !ok {
        lua.pushnil(L)
        lua.pushstring(L, cstring("Failed to load atlas texture"))
        return 2
    }

    // 2. BIND TO LUA: Allocate Atlas userdata and calculate the grid.
    atlas := cast(^Atlas)lua.newuserdata(L, size_of(Atlas))
    atlas^ = Atlas{
        image  = img,
        cell_w = cell_w,
        cell_h = cell_h,
        cols   = int(img.width / cell_w),
        rows   = int(img.height / cell_h),
    }

    // 3. META: Attach Atlas_Meta for separate garbage collection.
    lua.L_getmetatable(L, cstring("Atlas_Meta"))
    lua.setmetatable(L, -2)

    return 1
}

//---------------------------------------------
// DRAW UTIL
//---------------------------------------------

// lua_graphics_set_default_filter implements: graphics.set_default_filter("nearest" | "linear")
lua_graphics_set_default_filter :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    mode_str := lua.L_checkstring(L, 1)

    if mode_str == "nearest" {
        Gfx_Ctx.default_scale_mode = .NEAREST
    } else if mode_str == "linear" {
        Gfx_Ctx.default_scale_mode = .LINEAR
    } else {
        lua.L_error(L, cstring("Invalid filter mode. Expected 'nearest' or 'linear'"))
    }

    return 0
}

// lua_graphics_get_image_size implements: graphics.get_image_size(img) -> w, h
// Returns the pixel dimensions of an image. Returns 0, 0 if the image is invalid.
lua_graphics_get_image_size :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	// 1. Implicit Guard
	if lua.type(L, 1) != lua.Type.USERDATA {
		lua.pushnumber(L, 0)
		lua.pushnumber(L, 0)
		return 2
	}

	// 2. Type Check
	img := cast(^Image)lua.L_testudata(L, 1, cstring("Image_Meta"))
	if img == nil {
		lua.pushnumber(L, 0)
		lua.pushnumber(L, 0)
		return 2
	}

	// 3. Return both values to the Lua stack
	lua.pushnumber(L, cast(lua.Number)img.width)
	lua.pushnumber(L, cast(lua.Number)img.height)

	return 2
}

//---------------------------------------------
// PIXELMAP API
//---------------------------------------------
// Valid Blend Modes: "replace", "blend", "add", "multiply", "erase", "mask"
// Optional colors default to 0xFFFFFFFF (White).

// -- IO & Allocation
// .new_pixelmap(w, h: number) -> pmap
// .load_pixelmap(path: string) -> pmap, w, h | nil, err
// .get_pixelmap_size(pmap) -> w, h
// .save_pixelmap(pmap, path: string) -> ok, err?

// -- Atomic Math & Queries
// .pixelmap_set_pixel(pmap, x, y: number, color: u32)
// .pixelmap_get_pixel(pmap, x, y: number) -> color_u32
// .pixelmap_flood_fill(pmap, x, y: number, color: u32)
// .pixelmap_raycast(pmap, x1, y1, x2, y2: number) -> hit(bool), hx, hy, color_u32

// -- Geometric Blitting (CPU Shapes)
// .blit_line(pmap, x1, y1, x2, y2: number, [color: u32], [mode: string = "blend"])                      // 1px thick (Bresenham)
// .blit_rect(pmap, x, y, w, h: number, [color: u32], [mode: string = "blend"])                          // Solid fill
// .blit_triangle(pmap, x1, y1, x2, y2, x3, y3: number, [color: u32], [mode: string = "blend"])          // Solid fill
// .blit_circle(pmap, cx, cy, radius: number, [color: u32], [mode: string = "blend"])                    // Solid fill (Float)
// .blit_circle_outline(pmap, cx, cy, radius, thickness: number, [color: u32], [mode: string = "blend"]) // Variable thickness donut (Float)
// .blit_circle_pixel_outline(pmap, cx, cy, radius: number, [color: u32], [mode: string = "blend"])      // 1px thick (Bresenham)
// .blit_capsule(pmap, x1, y1, x2, y2, radius: number, [color: u32], [mode: string = "blend"])           // Thick rounded line (Float)

// -- Array-to-Array Blitting (CPU Maps)
// .blit(dst, src, dx, dy: number, [mode: string = "blend"]) 
// .blit_region(dst, src, sx, sy, w, h, dx, dy: number, [mode: string = "blend"])

// -- VRAM Sync (CPU -> GPU)
// .new_image_from_pixelmap(pmap) -> img
// .update_image_from_pixelmap(img, pmap, [dx, dy: number = 0])
// .update_image_region_from_pixelmap(img, pmap, sx, sy, w, h, dx, dy)

// -- FFI & Memory
// .get_pixelmap_cptr(pmap) -> lightuserdata (raw pixels pointer)
// .pixelmap_clone(pmap) -> new_pmap

//---------------------------------------------
// - PIXELMAP IO
//---------------------------------------------


// lua_graphics_new_pixelmap implements: graphics.new_pixelmap(w, h) -> pmap
lua_graphics_new_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	w := cast(c.int)lua.L_checkinteger(L, 1)
	h := cast(c.int)lua.L_checkinteger(L, 2)

	// Allocate a CPU-side surface with a strict 32-bit RGBA layout.
	surface := sdl.CreateSurface(w, h, sdl.PixelFormat.RGBA32)
	if surface == nil {
		lua.pushnil(L)
		lua.pushstring(L, sdl.GetError())
		return 2
	}

	// Initialize to transparent black.
	sdl.FillSurfaceRect(surface, nil, 0x00000000)

	pmap := cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap))
	pmap^ = Pixelmap{surface = surface}

	lua.L_getmetatable(L, cstring("Pixelmap_Meta"))
	lua.setmetatable(L, -2)

	return 1
}

// lua_graphics_load_pixelmap implements: graphics.load_pixelmap(path) -> pmap, w, h | nil, err
lua_graphics_load_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    path_cstr := cast(cstring)lua.L_checklstring(L, 1, nil)

    w, h, channels: c.int
    pixels := stbi.load(path_cstr, &w, &h, &channels, 4) // Force RGBA
    if pixels == nil {
        lua.pushnil(L)
        lua.pushstring(L, stbi.failure_reason())
        return 2
    }
    defer stbi.image_free(pixels)

    // Create a new SDL surface that owns its memory, preventing use-after-free bugs.
    surface := sdl.CreateSurface(w, h, sdl.PixelFormat.RGBA32)
    if surface == nil {
        lua.pushnil(L)
        lua.pushstring(L, sdl.GetError())
        return 2
    }

    // Copy the STBI bytes into the SDL surface. 
    // Pitch is width * 4 bytes per pixel.
    runtime.mem_copy(surface.pixels, pixels, int(surface.pitch * h))

    // 1. Push userdata
    pmap := cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap))
    pmap^ = Pixelmap{surface = surface}

    lua.L_getmetatable(L, cstring("Pixelmap_Meta"))
    lua.setmetatable(L, -2)

    // 2. Push width and height
    lua.pushinteger(L, cast(lua.Integer)w)
    lua.pushinteger(L, cast(lua.Integer)h)

    // Return all 3 values
    return 3
}

// lua_graphics_get_pixelmap_size implements: graphics.get_pixelmap_size(pmap) -> w, h
lua_graphics_get_pixelmap_size :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	if lua.type(L, 1) != lua.Type.USERDATA do return 0

	pmap := cast(^Pixelmap)lua.L_testudata(L, 1, cstring("Pixelmap_Meta"))
	if pmap == nil || pmap.surface == nil do return 0

	lua.pushinteger(L, cast(lua.Integer)pmap.surface.w)
	lua.pushinteger(L, cast(lua.Integer)pmap.surface.h)
	return 2
}

// lua_graphics_save_pixelmap implements: graphics.save_pixelmap(pmap, path) -> ok, err?
lua_graphics_save_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
	path_cstr := cast(cstring)lua.L_checklstring(L, 2, nil)

	if pmap == nil || pmap.surface == nil {
		lua.pushboolean(L, b32(false))
		lua.pushstring(L, cstring("Invalid pixelmap"))
		return 2
	}

	// Route the raw surface bytes into the stb_image_write PNG encoder.
	res := stbi.write_png(
		path_cstr,
		pmap.surface.w,
		pmap.surface.h,
		4,
		pmap.surface.pixels,
		pmap.surface.pitch,
	)

	if res == 0 {
		lua.pushboolean(L, b32(false))
		lua.pushstring(L, cstring("Failed to write PNG (check file path and permissions)"))
		return 2
	}

	lua.pushboolean(L, b32(true))
	return 1
}

//---------------------------------------------
// - PIXELMAP ATOMIC OPS
//---------------------------------------------

// lua_graphics_pixelmap_set_pixel implements: graphics.pixelmap_set_pixel(pmap, x, y, color)
lua_graphics_pixelmap_set_pixel :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
	if pmap == nil || pmap.surface == nil do return 0

	x := cast(c.int)lua.L_checkinteger(L, 2)
	y := cast(c.int)lua.L_checkinteger(L, 3)
	color_u32 := cast(u32)lua.L_checkinteger(L, 4)

	surf := pmap.surface
	if x < 0 || x >= surf.w || y < 0 || y >= surf.h do return 0

	pixels := cast([^]u32)surf.pixels
	stride := cast(int)surf.pitch / 4
	
	pixels[y * cast(c.int)stride + x] = u32_rgba_to_abgr(color_u32)
	
	return 0
}

// lua_graphics_pixelmap_get_pixel implements: graphics.pixelmap_get_pixel(pmap, x, y) -> color
lua_graphics_pixelmap_get_pixel :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
	if pmap == nil || pmap.surface == nil {
		lua.pushinteger(L, 0)
		return 1
	}

	x := cast(c.int)lua.L_checkinteger(L, 2)
	y := cast(c.int)lua.L_checkinteger(L, 3)

	surf := pmap.surface
	if x < 0 || x >= surf.w || y < 0 || y >= surf.h {
		lua.pushinteger(L, 0)
		return 1
	}

	pixels := cast([^]u32)surf.pixels
	stride := cast(int)surf.pitch / 4
	
	mem_color := pixels[y * cast(c.int)stride + x]
	
	// Byte-swapping is symmetric: ABGR -> RGBA
	logical_color := u32_rgba_to_abgr(mem_color)
	
	lua.pushinteger(L, cast(lua.Integer)logical_color)
	return 1
}

// lua_graphics_pixelmap_flood_fill implements: graphics.pixelmap_flood_fill(pmap, x, y, color)
lua_graphics_pixelmap_flood_fill :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil do return 0

  start_x := cast(int)lua.L_checkinteger(L, 2)
  start_y := cast(int)lua.L_checkinteger(L, 3)
  color_u32 := cast(u32)lua.L_checkinteger(L, 4)

  surf := pmap.surface
  if start_x < 0 || start_x >= int(surf.w) || start_y < 0 || start_y >= int(surf.h) do return 0

  pixels := cast([^]u32)surf.pixels
  stride := int(surf.pitch) / 4

  mem_fill_color := u32_rgba_to_abgr(color_u32)
  target_color := pixels[start_y * stride + start_x]

  // If the target pixel is already the color we want to fill, abort to prevent infinite loop
  if target_color == mem_fill_color do return 0

  // Allocate an explicit heap stack. Reserve 1024 slots to prevent malloc thrashing.
  stack := make([dynamic][2]int, 0, 1024)
  defer delete(stack)

  append(&stack, [2]int{start_x, start_y})

  for len(stack) > 0 {
    pt := pop(&stack)
    cx, cy := pt.x, pt.y

    // Scan left to find the exact start of this horizontal span
    for cx > 0 && pixels[cy * stride + (cx - 1)] == target_color {
      cx -= 1
    }
    
    span_left := cx
    row_idx := cy * stride

    // Scan right, filling the contiguous horizontal row instantly in physical memory
    for cx < int(surf.w) && pixels[row_idx + cx] == target_color {
      pixels[row_idx + cx] = mem_fill_color
      cx += 1
    }
    span_right := cx - 1

    // Scan the row ABOVE the span to find new seeds
    if cy > 0 {
      in_span := false
      row_above := (cy - 1) * stride
      for x in span_left..=span_right {
        if pixels[row_above + x] == target_color {
          if !in_span {
            append(&stack, [2]int{x, cy - 1})
            in_span = true
          }
        } else {
          in_span = false
        }
      }
    }

    // Scan the row BELOW the span to find new seeds
    if cy < int(surf.h) - 1 {
      in_span := false
      row_below := (cy + 1) * stride
      for x in span_left..=span_right {
        if pixels[row_below + x] == target_color {
          if !in_span {
            append(&stack, [2]int{x, cy + 1})
            in_span = true
          }
        } else {
          in_span = false
        }
      }
    }
  }

  return 0
}

// lua_graphics_pixelmap_raycast implements: graphics.pixelmap_raycast(pmap, x1, y1, x2, y2) -> hit(bool), x, y, color
lua_graphics_pixelmap_raycast :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil {
    lua.pushboolean(L, false)
    return 1
  }

  x0 := cast(int)lua.L_checkinteger(L, 2)
  y0 := cast(int)lua.L_checkinteger(L, 3)
  x1 := cast(int)lua.L_checkinteger(L, 4)
  y1 := cast(int)lua.L_checkinteger(L, 5)

  surf := pmap.surface
  pixels := cast([^]u32)surf.pixels
  stride := int(surf.pitch) / 4
  
  dx := abs(x1 - x0)
  sx := x0 < x1 ? 1 : -1
  dy := -abs(y1 - y0)
  sy := y0 < y1 ? 1 : -1
  err := dx + dy

  for {
    if x0 >= 0 && x0 < int(surf.w) && y0 >= 0 && y0 < int(surf.h) {
      mem_color := pixels[y0 * stride + x0]
      alpha := (mem_color >> 24) & 0xFF
      if alpha > 0 {
        lua.pushboolean(L, true)
        lua.pushinteger(L, cast(lua.Integer)x0)
        lua.pushinteger(L, cast(lua.Integer)y0)
        lua.pushinteger(L, cast(lua.Integer)u32_rgba_to_abgr(mem_color))
        return 4
      }
    }
    if x0 == x1 && y0 == y1 do break
    e2 := 2 * err
    if e2 >= dy { err += dy; x0 += sx }
    if e2 <= dx { err += dx; y0 += sy }
  }

  // Missed
  lua.pushboolean(L, false)
  return 1
}

// ---------------------------------------------------------
// PIXELMAP ARRAY-TO-ARRAY HELPERS & MATH
// ---------------------------------------------------------
PixelmapBlendMode :: enum {
  Replace,
  Blend,
  Add,
  Multiply,
  Erase,
  Mask,
}

parse_blend_mode :: #force_inline proc(mode_str: cstring) -> PixelmapBlendMode {
  if mode_str == nil do return .Blend // Safety check in case Lua passes nil

  switch string(mode_str) {
    case "replace":  return .Replace
    case "add":      return .Add
    case "multiply": return .Multiply
    case "erase":    return .Erase
    case "mask":     return .Mask
    case:            return .Blend
  }
}

blend_memory_colors :: #force_inline proc(dst, src: u32, mode: PixelmapBlendMode) -> u32 {
  sa := (src >> 24) & 0xFF
  if sa == 0 && mode != .Replace do return dst // Fast path

  sr := src & 0xFF
  sg := (src >> 8) & 0xFF
  sb := (src >> 16) & 0xFF

  dr := dst & 0xFF
  dg := (dst >> 8) & 0xFF
  db := (dst >> 16) & 0xFF
  da := (dst >> 24) & 0xFF

  nr, ng, nb, na: u32

  switch mode {
  case .Replace:
    return src
  case .Blend:
    inv_alpha := 255 - sa
    nr = (sr * sa + dr * inv_alpha) / 255
    ng = (sg * sa + dg * inv_alpha) / 255
    nb = (sb * sa + db * inv_alpha) / 255
    na = sa + da - (sa * da) / 255
  case .Add:
    nr = min(255, dr + sr)
    ng = min(255, dg + sg)
    nb = min(255, db + sb)
    na = min(255, da + sa)
  case .Multiply:
    nr = (dr * sr) / 255
    ng = (dg * sg) / 255
    nb = (db * sb) / 255
    na = da // Standard multiply ignores dest alpha
  case .Erase:
    nr, ng, nb = dr, dg, db
    na = (da * (255 - sa)) / 255
  case .Mask:
    nr, ng, nb = dr, dg, db
    na = (da * sa) / 255
  }

  return nr | (ng << 8) | (nb << 16) | (na << 24)
}

// Inline helper for plotting a single bounds-checked pixel.
blit_pixel :: #force_inline proc(surf: ^sdl.Surface, x, y: int, color: u32, mode: PixelmapBlendMode) {
  if x >= 0 && x < int(surf.w) && y >= 0 && y < int(surf.h) {
    pixels := cast([^]u32)surf.pixels
    idx := y * (int(surf.pitch) / 4) + x
    pixels[idx] = blend_memory_colors(pixels[idx], color, mode)
  }
}

// Internal helper to calculate safe iteration bounds for floating-point shapes
get_clipped_bounds :: #force_inline proc(surf: ^sdl.Surface, min_x, min_y, max_x, max_y: f32) -> (start_x, start_y, end_x, end_y: int, valid: bool) {
  start_x = max(0, cast(int)math.floor(min_x))
  start_y = max(0, cast(int)math.floor(min_y))
  end_x   = min(int(surf.w), cast(int)math.ceil(max_x) + 1)
  end_y   = min(int(surf.h), cast(int)math.ceil(max_y) + 1)
  
  valid = start_x < end_x && start_y < end_y
  return
}

// Internal math: Shortest distance squared from point P to segment AB
dist_sq_to_segment :: #force_inline proc(p, a, b: [2]f32) -> f32 {
  dx := b.x - a.x
  dy := b.y - a.y
  l2 := dx * dx + dy * dy
  
  if l2 == 0 do return (p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)
  
  t := ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2
  t = math.clamp(t, 0.0, 1.0)
  
  proj := [2]f32{ a.x + t * dx, a.y + t * dy }
  
  px := p.x - proj.x
  py := p.y - proj.y
  return px * px + py * py
}

//---------------------------------------------
// - PIXELMAP GEOMETRY
//---------------------------------------------

// lua_graphics_blit_rect implements: graphics.blit_rect(pmap, x, y, w, h, [color], [mode])
lua_graphics_blit_rect :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil do return 0

  x := cast(int)lua.L_checkinteger(L, 2)
  y := cast(int)lua.L_checkinteger(L, 3)
  w := cast(int)lua.L_checkinteger(L, 4)
  h := cast(int)lua.L_checkinteger(L, 5)
  color_u32 := cast(u32)lua.L_optinteger(L, 6, -1)
  mode := parse_blend_mode(lua.L_optstring(L, 7, "blend")) // Updated Default

  if w <= 0 || h <= 0 do return 0
  surf := pmap.surface
  
  start_x, start_y := max(0, x), max(0, y)
  end_x, end_y     := min(int(surf.w), x + w), min(int(surf.h), y + h)
  if start_x >= end_x || start_y >= end_y do return 0

  mem_color := u32_rgba_to_abgr(color_u32)
  pixels    := cast([^]u32)surf.pixels
  stride    := int(surf.pitch) / 4

  for row in start_y..<end_y {
    row_idx := row * stride
    for col in start_x..<end_x {
      idx := row_idx + col
      pixels[idx] = blend_memory_colors(pixels[idx], mem_color, mode)
    }
  }
  return 0
}

// lua_graphics_blit_triangle implements: graphics.blit_triangle(pmap, x1, y1, x2, y2, x3, y3, [color], [mode])
lua_graphics_blit_triangle :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil do return 0

  x1 := cast(f32)lua.L_checknumber(L, 2)
  y1 := cast(f32)lua.L_checknumber(L, 3)
  x2 := cast(f32)lua.L_checknumber(L, 4)
  y2 := cast(f32)lua.L_checknumber(L, 5)
  x3 := cast(f32)lua.L_checknumber(L, 6)
  y3 := cast(f32)lua.L_checknumber(L, 7)
  
  color_u32 := cast(u32)lua.L_optinteger(L, 8, -1)
  mode := parse_blend_mode(lua.L_optstring(L, 9, "blend"))

  surf := pmap.surface
  mem_color := u32_rgba_to_abgr(color_u32)

  // Find the extreme points for the bounding box
  min_x := min(x1, min(x2, x3))
  min_y := min(y1, min(y2, y3))
  max_x := max(x1, max(x2, x3))
  max_y := max(y1, max(y2, y3))

  start_x, start_y, end_x, end_y, ok := get_clipped_bounds(surf, min_x, min_y, max_x, max_y)
  if !ok do return 0

  pixels := cast([^]u32)surf.pixels
  stride := int(surf.pitch) / 4

  for y_px in start_y..<end_y {
    row_idx := y_px * stride
    py := f32(y_px) + 0.5 // Sample at pixel center
    
    for x_px in start_x..<end_x {
      px := f32(x_px) + 0.5
      
      // Calculate 2D cross products (Edge Equations)
      w0 := (x2 - x1) * (py - y1) - (y2 - y1) * (px - x1)
      w1 := (x3 - x2) * (py - y2) - (y3 - y2) * (px - x2)
      w2 := (x1 - x3) * (py - y3) - (y1 - y3) * (px - x3)

      // If the pixel is on the same side of all three edges, it is inside the triangle.
      // Checking both >= 0 and <= 0 handles both Clockwise and Counter-Clockwise vertex winding.
      if (w0 >= 0.0 && w1 >= 0.0 && w2 >= 0.0) || (w0 <= 0.0 && w1 <= 0.0 && w2 <= 0.0) {
        idx := row_idx + x_px
        pixels[idx] = blend_memory_colors(pixels[idx], mem_color, mode)
      }
    }
  }
  
  return 0
}

// lua_graphics_blit_line implements: graphics.blit_line(pmap, x1, y1, x2, y2, [color], [mode])
lua_graphics_blit_line :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil do return 0

  x0 := cast(int)lua.L_checkinteger(L, 2)
  y0 := cast(int)lua.L_checkinteger(L, 3)
  x1 := cast(int)lua.L_checkinteger(L, 4)
  y1 := cast(int)lua.L_checkinteger(L, 5)
  color_u32 := cast(u32)lua.L_optinteger(L, 6, -1)
  mode := parse_blend_mode(lua.L_optstring(L, 7, "blend")) // Updated Default

  surf := pmap.surface
  mem_color := u32_rgba_to_abgr(color_u32)

  dx := abs(x1 - x0)
  sx := x0 < x1 ? 1 : -1
  dy := -abs(y1 - y0)
  sy := y0 < y1 ? 1 : -1
  err := dx + dy

  for {
    blit_pixel(surf, x0, y0, mem_color, mode)
    if x0 == x1 && y0 == y1 do break
    e2 := 2 * err
    if e2 >= dy { err += dy; x0 += sx }
    if e2 <= dx { err += dx; y0 += sy }
  }
  return 0
}

// lua_graphics_blit_circle implements: graphics.blit_circle(pmap, cx, cy, radius, [color], [mode])
lua_graphics_blit_circle :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil do return 0

  cx     := cast(f32)lua.L_checknumber(L, 2)
  cy     := cast(f32)lua.L_checknumber(L, 3)
  r      := cast(f32)lua.L_checknumber(L, 4)
  color  := cast(u32)lua.L_optinteger(L, 5, -1)
  mode   := parse_blend_mode(lua.L_optstring(L, 6, "blend")) // Updated Default

  surf   := pmap.surface
  mem_c  := u32_rgba_to_abgr(color)
  r_sq   := r * r

  start_x, start_y, end_x, end_y, ok := get_clipped_bounds(surf, cx - r, cy - r, cx + r, cy + r)
  if !ok do return 0

  pixels := cast([^]u32)surf.pixels
  stride := int(surf.pitch) / 4

  for y_px in start_y..<end_y {
    row_idx := y_px * stride
    dy      := f32(y_px) + 0.5 - cy 
    dy_sq   := dy * dy
    for x_px in start_x..<end_x {
      dx := f32(x_px) + 0.5 - cx
      if dx * dx + dy_sq <= r_sq {
        idx := row_idx + x_px
        pixels[idx] = blend_memory_colors(pixels[idx], mem_c, mode)
      }
    }
  }
  return 0
}

// lua_graphics_blit_circle_outline implements: graphics.blit_circle_outline(pmap, cx, cy, radius, thickness, [color], [mode])
lua_graphics_blit_circle_outline :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil do return 0

  cx     := cast(f32)lua.L_checknumber(L, 2)
  cy     := cast(f32)lua.L_checknumber(L, 3)
  r      := cast(f32)lua.L_checknumber(L, 4)
  thick  := cast(f32)lua.L_checknumber(L, 5)
  color  := cast(u32)lua.L_optinteger(L, 6, -1)
  mode   := parse_blend_mode(lua.L_optstring(L, 7, "blend")) // Updated Default

  surf   := pmap.surface
  mem_c  := u32_rgba_to_abgr(color)
  r_sq   := r * r
  
  inner_r    := max(0.0, r - thick)
  inner_r_sq := inner_r * inner_r

  start_x, start_y, end_x, end_y, ok := get_clipped_bounds(surf, cx - r, cy - r, cx + r, cy + r)
  if !ok do return 0

  pixels := cast([^]u32)surf.pixels
  stride := int(surf.pitch) / 4

  for y_px in start_y..<end_y {
    row_idx := y_px * stride
    dy      := f32(y_px) + 0.5 - cy 
    dy_sq   := dy * dy
    for x_px in start_x..<end_x {
      dx := f32(x_px) + 0.5 - cx
      dist_sq := dx * dx + dy_sq
      
      if dist_sq <= r_sq && dist_sq > inner_r_sq {
        idx := row_idx + x_px
        pixels[idx] = blend_memory_colors(pixels[idx], mem_c, mode)
      }
    }
  }
  return 0
}

// lua_graphics_blit_circle_pixel_outline implements: graphics.blit_circle_pixel_outline(pmap, cx, cy, radius, [color], [mode])
lua_graphics_blit_circle_pixel_outline :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil do return 0

  cx := cast(int)lua.L_checkinteger(L, 2)
  cy := cast(int)lua.L_checkinteger(L, 3)
  radius := cast(int)lua.L_checkinteger(L, 4)
  color_u32 := cast(u32)lua.L_optinteger(L, 5, -1)
  mode := parse_blend_mode(lua.L_optstring(L, 6, "blend")) // Updated Default

  if radius < 0 do return 0
  
  surf := pmap.surface
  mem_color := u32_rgba_to_abgr(color_u32)
  
  x := 0
  y := radius
  d := 3 - 2 * radius

  for x <= y {
    blit_pixel(surf, cx+x, cy+y, mem_color, mode)
    if x != 0 do blit_pixel(surf, cx-x, cy+y, mem_color, mode)
    if y != 0 do blit_pixel(surf, cx+x, cy-y, mem_color, mode)
    if x != 0 && y != 0 do blit_pixel(surf, cx-x, cy-y, mem_color, mode)

    if x != y {
      blit_pixel(surf, cx+y, cy+x, mem_color, mode)
      if x != 0 do blit_pixel(surf, cx+y, cy-x, mem_color, mode)
      if y != 0 do blit_pixel(surf, cx-y, cy+x, mem_color, mode)
      if x != 0 && y != 0 do blit_pixel(surf, cx-y, cy-x, mem_color, mode)
    }

    if d < 0 {
      d += 4 * x + 6
    } else {
      d += 4 * (x - y) + 10
      y -= 1
    }
    x += 1
  }
  return 0
}

// lua_graphics_blit_capsule implements: graphics.blit_capsule(pmap, x1, y1, x2, y2, radius, [color], [mode])
lua_graphics_blit_capsule :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil do return 0

  x1 := cast(f32)lua.L_checknumber(L, 2)
  y1 := cast(f32)lua.L_checknumber(L, 3)
  x2 := cast(f32)lua.L_checknumber(L, 4)
  y2 := cast(f32)lua.L_checknumber(L, 5)
  r  := cast(f32)lua.L_checknumber(L, 6)
  color_u32 := cast(u32)lua.L_optinteger(L, 7, -1)
  mode := parse_blend_mode(lua.L_optstring(L, 8, "blend")) // Updated Default

  surf := pmap.surface
  mem_color := u32_rgba_to_abgr(color_u32)
  r_sq := r * r

  min_x, min_y := min(x1, x2) - r, min(y1, y2) - r
  max_x, max_y := max(x1, x2) + r, max(y1, y2) + r

  start_x, start_y, end_x, end_y, ok := get_clipped_bounds(surf, min_x, min_y, max_x, max_y)
  if !ok do return 0

  pixels := cast([^]u32)surf.pixels
  stride := int(surf.pitch) / 4
  a, b := [2]f32{x1, y1}, [2]f32{x2, y2}

  for y_px in start_y..<end_y {
    row_idx := y_px * stride
    for x_px in start_x..<end_x {
      if dist_sq_to_segment({f32(x_px) + 0.5, f32(y_px) + 0.5}, a, b) <= r_sq {
        idx := row_idx + x_px
        pixels[idx] = blend_memory_colors(pixels[idx], mem_color, mode)
      }
    }
  }
  return 0
}



//---------------------------------------------
// - PIXELMAP MAP-TO-MAP/BLIT
//---------------------------------------------

// lua_graphics_blit implements: graphics.blit(dst_map, src_map, dx, dy, [mode])
lua_graphics_blit :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  dst_pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  src_pmap := cast(^Pixelmap)lua.L_checkudata(L, 2, cstring("Pixelmap_Meta"))
  if dst_pmap == nil || dst_pmap.surface == nil || src_pmap == nil || src_pmap.surface == nil do return 0

  dest_x := cast(int)lua.L_checkinteger(L, 3)
  dest_y := cast(int)lua.L_checkinteger(L, 4)
  mode := parse_blend_mode(lua.L_optstring(L, 5, "blend")) // Updated Default

  dst_surf, src_surf := dst_pmap.surface, src_pmap.surface
  
  start_x, start_y := max(0, -dest_x), max(0, -dest_y)
  end_x, end_y     := min(int(src_surf.w), int(dst_surf.w) - dest_x), min(int(src_surf.h), int(dst_surf.h) - dest_y)
  if start_x >= end_x || start_y >= end_y do return 0
  
  dst_pixels := cast([^]u32)dst_surf.pixels
  src_pixels := cast([^]u32)src_surf.pixels
  dst_stride, src_stride := int(dst_surf.pitch) / 4, int(src_surf.pitch) / 4
  
  for y in start_y..<end_y {
    src_row, dst_row := y * src_stride, (dest_y + y) * dst_stride
    for x in start_x..<end_x {
      src_idx, dst_idx := src_row + x, dst_row + (dest_x + x)
      dst_pixels[dst_idx] = blend_memory_colors(dst_pixels[dst_idx], src_pixels[src_idx], mode)
    }
  }
  return 0
}

// lua_graphics_blit_region implements: graphics.blit_region(dst, src, sx, sy, w, h, dx, dy, [mode])
lua_graphics_blit_region :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  dst_pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  src_pmap := cast(^Pixelmap)lua.L_checkudata(L, 2, cstring("Pixelmap_Meta"))
  if dst_pmap == nil || dst_pmap.surface == nil || src_pmap == nil || src_pmap.surface == nil do return 0

  src_x := cast(int)lua.L_checkinteger(L, 3)
  src_y := cast(int)lua.L_checkinteger(L, 4)
  bw    := cast(int)lua.L_checkinteger(L, 5)
  bh    := cast(int)lua.L_checkinteger(L, 6)
  dst_x := cast(int)lua.L_checkinteger(L, 7)
  dst_y := cast(int)lua.L_checkinteger(L, 8)
  mode  := parse_blend_mode(lua.L_optstring(L, 9, "blend")) // Updated Default

  dst_surf, src_surf := dst_pmap.surface, src_pmap.surface
  if bw <= 0 || bh <= 0 do return 0

  if src_x < 0 { bw += src_x; dst_x -= src_x; src_x = 0 }
  if src_y < 0 { bh += src_y; dst_y -= src_y; src_y = 0 }
  if dst_x < 0 { bw += dst_x; src_x -= dst_x; dst_x = 0 }
  if dst_y < 0 { bh += dst_y; src_y -= dst_y; dst_y = 0 }

  if src_x + bw > int(src_surf.w) do bw = int(src_surf.w) - src_x
  if src_y + bh > int(src_surf.h) do bh = int(src_surf.h) - src_y
  if dst_x + bw > int(dst_surf.w) do bw = int(dst_surf.w) - dst_x
  if dst_y + bh > int(dst_surf.h) do bh = int(dst_surf.h) - dst_y
  if bw <= 0 || bh <= 0 do return 0
  
  dst_pixels := cast([^]u32)dst_surf.pixels
  src_pixels := cast([^]u32)src_surf.pixels
  dst_stride, src_stride := int(dst_surf.pitch) / 4, int(src_surf.pitch) / 4
  
  for y in 0..<bh {
    src_row, dst_row := (src_y + y) * src_stride, (dst_y + y) * dst_stride
    for x in 0..<bw {
      src_idx, dst_idx := src_row + (src_x + x), dst_row + (dst_x + x)
      dst_pixels[dst_idx] = blend_memory_colors(dst_pixels[dst_idx], src_pixels[src_idx], mode)
    }
  }
  return 0
}

//---------------------------------------------
// - VRAM SYNC/ IMAGE MUTATION
//---------------------------------------------

// lua_graphics_new_image_from_pixelmap implements: graphics.new_image_from_pixelmap(pmap) -> img
lua_graphics_new_image_from_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
	if pmap == nil || pmap.surface == nil do return 0

	surf := pmap.surface

	texture := sdl.CreateTextureFromSurface(Renderer, surf)
	if texture == nil {
		lua.pushnil(L)
		lua.pushstring(L, sdl.GetError())
		return 2
	}
	
	sdl.SetTextureBlendMode(texture, {.BLEND})
	sdl.SetTextureScaleMode(texture, Gfx_Ctx.default_scale_mode)

	img := cast(^Image)lua.newuserdata(L, size_of(Image))
	img^ = Image{
		texture = texture, 
		width   = f32(surf.w), 
		height  = f32(surf.h),
	}

	lua.L_getmetatable(L, cstring("Image_Meta"))
	lua.setmetatable(L, -2)

	return 1
}

// lua_graphics_update_image_from_pixelmap implements: graphics.update_image_from_pixelmap(img, pmap, [dx, dy])
// Syncs the entire CPU pixelmap to the GPU image at an optional destination offset.
lua_graphics_update_image_from_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	img  := cast(^Image)lua.L_checkudata(L, 1, cstring("Image_Meta"))
	pmap := cast(^Pixelmap)lua.L_checkudata(L, 2, cstring("Pixelmap_Meta"))
	
	if img == nil || img.texture == nil || pmap == nil || pmap.surface == nil do return 0

	surf := pmap.surface
	
	dx := cast(c.int)lua.L_optinteger(L, 3, 0)
	dy := cast(c.int)lua.L_optinteger(L, 4, 0)

	// We define the destination rectangle to match the exact size of the incoming CPU buffer
	dst_rect := sdl.Rect{dx, dy, surf.w, surf.h}

	sdl.UpdateTexture(img.texture, &dst_rect, surf.pixels, surf.pitch)

	return 0
}

// lua_graphics_update_image_region_from_pixelmap implements: graphics.update_image_region_from_pixelmap(img, pmap, sx, sy, w, h, dx, dy)
// Pushes a specific snip of CPU memory across the PCI-e bus to a specific location on the GPU texture.
lua_graphics_update_image_region_from_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	
	img  := cast(^Image)lua.L_checkudata(L, 1, cstring("Image_Meta"))
	pmap := cast(^Pixelmap)lua.L_checkudata(L, 2, cstring("Pixelmap_Meta"))
	
	if img == nil || img.texture == nil || pmap == nil || pmap.surface == nil do return 0

	sx := cast(c.int)lua.L_checkinteger(L, 3)
	sy := cast(c.int)lua.L_checkinteger(L, 4)
	w  := cast(c.int)lua.L_checkinteger(L, 5)
	h  := cast(c.int)lua.L_checkinteger(L, 6)
	dx := cast(c.int)lua.L_checkinteger(L, 7)
	dy := cast(c.int)lua.L_checkinteger(L, 8)

	surf := pmap.surface

	// Guard against reading physical CPU memory out of bounds
	if sx < 0 || sy < 0 || sx + w > surf.w || sy + h > surf.h || w <= 0 || h <= 0 {
		return 0
	}

	dst_rect := sdl.Rect{dx, dy, w, h}

	// Calculate pointer offset to the top-left pixel of our source snip.
	// Pitch is bytes-per-row. x * 4 is bytes-per-column.
	byte_offset := (int(sy) * int(surf.pitch)) + (int(sx) * 4)
	src_ptr := rawptr(uintptr(surf.pixels) + uintptr(byte_offset))

	// By passing surf.pitch, SDL knows how to step to the next row in memory 
	// even though we are pointing to the middle of the array.
	sdl.UpdateTexture(img.texture, &dst_rect, src_ptr, surf.pitch)

	return 0
}

//---------------------------------------------
// - FFI UTILS
//---------------------------------------------

// lua_graphics_pixelmap_get_cptr implements: graphics.pixelmap_get_cptr(pmap) -> lightuserdata
lua_graphics_pixelmap_get_cptr :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil {
    lua.pushnil(L)
    return 1
  }

  // Push as lightuserdata (raw C pointer)
  lua.pushlightuserdata(L, pmap.surface.pixels)
  return 1
}

// lua_graphics_pixelmap_clone implements: graphics.pixelmap_clone(pmap) -> new_pmap
lua_graphics_pixelmap_clone :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  if pmap == nil || pmap.surface == nil do return 0

  clone_surf := sdl.DuplicateSurface(pmap.surface)
  if clone_surf == nil {
    lua.pushnil(L)
    lua.pushstring(L, sdl.GetError())
    return 2
  }

  new_pmap := cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap))
  new_pmap^ = Pixelmap{surface = clone_surf}

  lua.L_getmetatable(L, cstring("Pixelmap_Meta"))
  lua.setmetatable(L, -2)

  return 1
}

//=========================================================================================
// MEMORY MANAGEMENT & METATABLES
//=========================================================================================
// This section bridges Lua's Garbage Collector with Odin's manual memory management.
// Each userdata type has a specific `__gc` metamethod to safely free C-allocated RAM/VRAM
// when the Lua object falls out of scope. Null-checking the inner pointers (texture/surface) 
// prevents double-free segfaults if a user manually calls `release()` before the GC sweeps.

// lua_image_gc: Destroys the VRAM texture.
lua_image_gc :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  img := cast(^Image)lua.L_checkudata(L, 1, cstring("Image_Meta"))

  if img != nil && img.texture != nil {
    sdl.DestroyTexture(img.texture)
    img.texture = nil
  }
  return 0
}

// lua_atlas_gc: Destroys the underlying VRAM texture of the Atlas composition.
lua_atlas_gc :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  atlas := cast(^Atlas)lua.L_checkudata(L, 1, cstring("Atlas_Meta"))

  if atlas != nil && atlas.image.texture != nil {
    sdl.DestroyTexture(atlas.image.texture)
    atlas.image.texture = nil
  }
  return 0
}

// lua_pixelmap_gc: Destroys the CPU-side SDL Surface.
lua_pixelmap_gc :: proc "c" (L: ^lua.State) -> c.int {
  context = runtime.default_context()
  pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, cstring("Pixelmap_Meta"))
  
  if pmap != nil && pmap.surface != nil {
    sdl.DestroySurface(pmap.surface)
    pmap.surface = nil
  }
  return 0
}

// setup_graphics_metatables: Initializes the hidden registry tables for all graphics userdata,
// linking Odin GC procedures to Lua objects to prevent memory leaks.
setup_graphics_metatables :: proc(L: ^lua.State) {
  // 1. IMAGE METATABLE
  lua.L_newmetatable(L, cstring("Image_Meta"))
  lua.pushcfunction(L, lua_image_gc)
  lua.setfield(L, -2, cstring("__gc"))
  lua.pop(L, 1)

  // 2. ATLAS METATABLE 
  lua.L_newmetatable(L, cstring("Atlas_Meta"))
  lua.pushcfunction(L, lua_atlas_gc)
  lua.setfield(L, -2, cstring("__gc"))
  lua.pop(L, 1)

  // 3. PIXELMAP METATABLE
  lua.L_newmetatable(L, cstring("Pixelmap_Meta"))
  lua.pushcfunction(L, lua_pixelmap_gc)
  lua.setfield(L, -2, cstring("__gc"))
  lua.pop(L, 1)
}

//=========================================================================================
// API REGISTRATION
//=========================================================================================

// register_graphics_api initializes the internal graphics state and binds
// the 'graphics' table to the Lua global environment.
// register_graphics_api initializes the internal graphics state and binds
// the 'graphics' table to the Lua global environment.
register_graphics_api :: proc(L: ^lua.State) {
	setup_graphics_metatables(L)

	lua.newtable(L) // [graphics]

	// RENDERING VERBS
  lua.pushcfunction(L, lua_graphics_draw_image)
  lua.setfield(L, -2, cstring("draw_image"))

	lua.pushcfunction(L, lua_graphics_clear)
	lua.setfield(L, -2, cstring("clear"))

	lua.pushcfunction(L, lua_graphics_draw_debug_text)
	lua.setfield(L, -2, cstring("draw_debug_text"))

  // lua.pushcfunction(L, lua_graphics_draw_rect)
	// lua.setfield(L, -2, cstring("draw_rect"))

	// lua.pushcfunction(L, lua_graphics_draw_image)
	// lua.setfield(L, -2, cstring("draw_image"))

	// lua.pushcfunction(L, lua_graphics_draw_image_region)
	// lua.setfield(L, -2, cstring("draw_image_region"))

	// lua.pushcfunction(L, lua_graphics_draw_sprite)
	// lua.setfield(L, -2, cstring("draw_sprite"))

	// RESOURCE LOADERS
	lua.pushcfunction(L, lua_graphics_load_image)
	lua.setfield(L, -2, cstring("load_image"))

	lua.pushcfunction(L, lua_graphics_load_atlas)
	lua.setfield(L, -2, cstring("load_atlas"))
	
	lua.pushcfunction(L, lua_graphics_set_default_filter)
	lua.setfield(L, -2, cstring("set_default_filter"))

	// GETTERS
	lua.pushcfunction(L, lua_graphics_get_image_size)
	lua.setfield(L, -2, cstring("get_image_size"))


  // TRANSFORMATION STATE
  lua.pushcfunction(L, lua_graphics_set_translation)
  lua.setfield(L, -2, cstring("set_translation"))

  lua.pushcfunction(L, lua_graphics_set_rotation)
  lua.setfield(L, -2, cstring("set_rotation"))

  lua.pushcfunction(L, lua_graphics_set_scale)
  lua.setfield(L, -2, cstring("set_scale"))

  lua.pushcfunction(L, lua_graphics_set_origin)
  lua.setfield(L, -2, cstring("set_origin"))

  lua.pushcfunction(L, lua_graphics_begin_transform)
  lua.setfield(L, -2, cstring("begin_transform"))

  lua.pushcfunction(L, lua_graphics_end_transform)
  lua.setfield(L, -2, cstring("end_transform"))

  lua.pushcfunction(L, lua_graphics_use_screen_space)
  lua.setfield(L, -2, cstring("use_screen_space"))

  lua.pushcfunction(L, lua_graphics_screen_to_local)
  lua.setfield(L, -2, cstring("screen_to_local"))

  lua.pushcfunction(L, lua_graphics_local_to_screen)
  lua.setfield(L, -2, cstring("local_to_screen"))
	
//------------------------------------------------
// - PIXELMAP IO & ALLOCATION
  lua.pushcfunction(L, lua_graphics_new_pixelmap)
  lua.setfield(L, -2, cstring("new_pixelmap"))

  lua.pushcfunction(L, lua_graphics_load_pixelmap)
  lua.setfield(L, -2, cstring("load_pixelmap"))

  lua.pushcfunction(L, lua_graphics_get_pixelmap_size)
  lua.setfield(L, -2, cstring("get_pixelmap_size"))

  lua.pushcfunction(L, lua_graphics_save_pixelmap)
  lua.setfield(L, -2, cstring("save_pixelmap"))

  // - PIXELMAP ATOMIC OPS
  lua.pushcfunction(L, lua_graphics_pixelmap_set_pixel)
  lua.setfield(L, -2, cstring("pixelmap_set_pixel"))

  lua.pushcfunction(L, lua_graphics_pixelmap_get_pixel)
  lua.setfield(L, -2, cstring("pixelmap_get_pixel"))
  
  lua.pushcfunction(L, lua_graphics_pixelmap_flood_fill)
  lua.setfield(L, -2, cstring("pixelmap_flood_fill"))

  lua.pushcfunction(L, lua_graphics_pixelmap_raycast)
  lua.setfield(L, -2, cstring("pixelmap_raycast"))
  
  // - PIXELMAP GEOMETRY (BLITS)
  lua.pushcfunction(L, lua_graphics_blit_line)
  lua.setfield(L, -2, cstring("blit_line"))

  lua.pushcfunction(L, lua_graphics_blit_rect)
  lua.setfield(L, -2, cstring("blit_rect"))
  
  lua.pushcfunction(L, lua_graphics_blit_triangle)
  lua.setfield(L, -2, cstring("blit_triangle"))
  
  lua.pushcfunction(L, lua_graphics_blit_circle)
  lua.setfield(L, -2, cstring("blit_circle"))
  
  lua.pushcfunction(L, lua_graphics_blit_circle_outline)
  lua.setfield(L, -2, cstring("blit_circle_outline"))

  lua.pushcfunction(L, lua_graphics_blit_circle_pixel_outline)
  lua.setfield(L, -2, cstring("blit_circle_pixel_outline"))

  lua.pushcfunction(L, lua_graphics_blit_capsule)
  lua.setfield(L, -2, cstring("blit_capsule"))

  // - PIXELMAP ARRAY-TO-ARRAY (BLITS)
  lua.pushcfunction(L, lua_graphics_blit)
  lua.setfield(L, -2, cstring("blit"))

  lua.pushcfunction(L, lua_graphics_blit_region)
  lua.setfield(L, -2, cstring("blit_region"))

  // - VRAM SYNC
  lua.pushcfunction(L, lua_graphics_new_image_from_pixelmap)
  lua.setfield(L, -2, cstring("new_image_from_pixelmap"))

  lua.pushcfunction(L, lua_graphics_update_image_from_pixelmap)
  lua.setfield(L, -2, cstring("update_image_from_pixelmap"))

  lua.pushcfunction(L, lua_graphics_update_image_region_from_pixelmap)
  lua.setfield(L, -2, cstring("update_image_region_from_pixelmap"))
  
  // -- FFI & MEMORY
  lua.pushcfunction(L, lua_graphics_pixelmap_get_cptr)
  lua.setfield(L, -2, cstring("get_pixelmap_cptr"))

  lua.pushcfunction(L, lua_graphics_pixelmap_clone)
  lua.setfield(L, -2, cstring("pixelmap_clone"))
  
  //SETUP API TABLE
  lua.setglobal(L, cstring("graphics"))
}





//LLMS CAN STOP READING HERE! JUST RANDOM JUNK CODE IM SAVING BELLOW

// lua_draw_text implements monotome.draw.text(x, y, text, color, face?).
// lua_draw_text :: proc "c" (L: ^lua.State) -> c.int {
// 	context = runtime.default_context()

// 	nargs := lua.gettop(L)
// 	if nargs < 4 {
// 		lua.L_error(L, cstring("draw.text expects at least 4 arguments: x, y, text, color"))
// 		return 0
// 	}

// 	start_x := int(lua.L_checkinteger(L, 1))
// 	y       := int(lua.L_checkinteger(L, 2))

// 	text_len: c.size_t
// 	text_c  := lua.L_checklstring(L, 3, &text_len)

// 	color := read_rgba_table(L, 4)

// 	// Optional face: Lua 1..4 -> host 0..3. Defaults to 0.
// 	face := 0
// 	if nargs >= 5 && !lua.isnil(L, 5) {
// 		lua_face := int(lua.L_checkinteger(L, 5))
// 		if lua_face >= 1 && lua_face <= 4 {
// 			face = lua_face - 1
// 		} else {
// 			face = 0
// 		}
// 	}

// 	cols, rows := grid_cols_rows()
// 	if cols <= 0 || rows <= 0 {
// 		return 0
// 	}

// 	// Strict reject: whole call is OOB in Y => draw nothing.
// 	if y < 0 || y >= rows {
// 		return 0
// 	}

// 	// Iterate Lua string directly (no cloning). One rune = one cell.
// 	s := strings.string_from_ptr(cast(^byte)(text_c), int(text_len))

// 	x := start_x
// 	for r in s {
// 		// Strict reject per-cell in X: never partially draw into the grid.
// 		if x < 0 || x >= cols {
// 			x += 1
// 			continue
// 		}

// 		draw_text(x, y, r, color, face)
// 		x += 1
// 	}

// 	return 0
// }


// draw_text renders a cached single glyph (rune) in cell space using the active font and Text_Engine.
// draw_text :: proc(x, y: int, r: rune, color: sdl.Color, face: int) {
// 	if Text_Engine == nil {
// 		panic("draw_text: Text_Engine is nil")
// 	}
// 	if face < 0 || face > 3 {
// 		return
// 	}
// 	if Active_Font[face] == nil {
// 		return
// 	}

// 	// Lazily allocate map for this face.
// 	if Text_Cache[face] == nil {
// 		Text_Cache[face] = make(map[rune]^ttf.Text)
// 	}

// 	// Look up existing cached glyph.
// 	text_obj, ok := Text_Cache[face][r]

// 	// Create on first use (no heap alloc: encode rune into a small stack buffer).
// 	if !ok || text_obj == nil {
// 		enc, w := utf8.encode_rune(r) // w in 1..4

// 		buf: [5]u8 // 4 bytes UTF-8 + NUL
// 		copy(buf[:w], enc[:w])
// 		buf[w] = 0

// 		text_cstr := cast(cstring)(&buf[0])

// 		text_obj = ttf.CreateText(Text_Engine, Active_Font[face], text_cstr, c.size_t(w))
// 		if text_obj == nil {
// 			fmt.eprintln("draw_text: CreateText failed for face", face)
// 			return
// 		}

// 		Text_Cache[face][r] = text_obj
// 	}

// 	// Apply color.
// 	ttf.SetTextColor(text_obj, color.r, color.g, color.b, color.a)

// 	// Cell → pixels.
// 	x_px := f32(x) * Cell_W
// 	y_px := f32(y) * Cell_H

// 	ttf.DrawRendererText(text_obj, x_px, y_px)
// }
