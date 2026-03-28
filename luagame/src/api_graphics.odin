package main

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:math"
import "core:c"
import "core:unicode/utf8"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"
import "vendor:sdl3/ttf"
import lua "luajit"

//TODO:
// raster ops - Pixelmap API

// Primitives: draw_line, 1px unfilled rects, and draw_poly (plus unfilled variant).

// Pixelmaps (CPU Read/Write): load_pixelmap, get_pixel, set_pixel, new_image_from_pixelmap, and save_pixelmap.

// Render Targets: Support for rendering to textures.

// Blend Modes: Global or per-draw blending control.

// Camera: A dedicated abstraction or module for view transforms.

// Text & Fonts: Integration with SDL_ttf for font loading and text rendering.

// Animation System: Logic for handling sprite/atlas frames over time.

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

// Global singleton for the immediate-mode "Pen" state and shared resources.
gfx_ctx: struct {
  pending: struct {
		rotation: f32,
		scale:    [2]f32,
		origin:   [2]f32,
  },
  group_depth:       int,
  current_color:     sdl.Color,    // Shadow copy for RenderClear/DebugText
  rect_color:        sdl.Color,    // Shadow copy for gfx_ctx.base_rect_texture ONLY
	base_rect_texture: ^sdl.Texture,
	default_scale_mode: sdl.ScaleMode,
}= {
	//defaults
  pending = { scale = {1, 1} },
  default_scale_mode = .NEAREST,
}


//HELPERS---------

// Returns the draw state to neutral defaults.
reset_pending_transforms :: proc() {
	gfx_ctx.pending.rotation = 0
	gfx_ctx.pending.scale    = {1, 1}
	gfx_ctx.pending.origin   = {0, 0}
}

// Called after every draw call to handle the Consumer vs. Persistent logic.
check_transform_consumption :: proc() {
	if gfx_ctx.group_depth == 0 {
		reset_pending_transforms()
	}
}

init_graphics_state :: proc() {
	// 1. Lock Odin and SDL to the same baseline color state
	gfx_ctx.current_color = sdl.Color{255, 255, 255, 255}
	sdl.SetRenderDrawColor(Renderer, 255, 255, 255, 255)

	// 2. Setup the 1x1 rect texture
	if gfx_ctx.base_rect_texture != nil do return

	pixel_data: u32 = 0xFFFFFFFF
	gfx_ctx.base_rect_texture = sdl.CreateTexture(Renderer, .RGBA32, .STATIC, 1, 1)
	sdl.UpdateTexture(gfx_ctx.base_rect_texture, nil, &pixel_data, 4)
	sdl.SetTextureBlendMode(gfx_ctx.base_rect_texture, {.BLEND})
}

// set_render_color checks the requested color against our shadow state.
// If it differs, we update SDL and sync our shadow state. If it matches, we do nothing.
// This is the backbone of the stateless Lua API's performance.
set_render_color :: proc(c: sdl.Color) {
	if gfx_ctx.current_color != c {
		sdl.SetRenderDrawColor(Renderer, c.r, c.g, c.b, c.a)
		gfx_ctx.current_color = c
	}
}

// unpack_color converts a packed 32-bit integer (0xRRGGBBAA) into an sdl.Color.
unpack_color :: proc(packed: u32) -> sdl.Color {
	return sdl.Color{
		u8((packed >> 24) & 0xFF),
		u8((packed >> 16) & 0xFF),
		u8((packed >> 8)  & 0xFF),
		u8(packed & 0xFF),
	}
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
	sdl.SetTextureScaleMode(texture, gfx_ctx.default_scale_mode)

	return Image{texture, f32(w), f32(h)}, true
}


// Internal workhorse for drawing textures with transforms.
draw_image_pixels :: proc(tex: ^sdl.Texture, src_rect: ^sdl.FRect, x, y, w, h: f32, color: sdl.Color) {
  p := &gfx_ctx.pending

  pivot := p.origin * p.scale
  size  := [2]f32{w, h} * p.scale
  dst   := sdl.FRect{ x - pivot.x, y - pivot.y, size.x, size.y }

  // THE COLOR ROUTING
  if tex == gfx_ctx.base_rect_texture {
    // 1. It's a Rect: Check the cache to save GPU calls
    if color != gfx_ctx.rect_color {
      sdl.SetTextureColorMod(tex, color.r, color.g, color.b)
      sdl.SetTextureAlphaMod(tex, color.a)
      gfx_ctx.rect_color = color
    }
  } else {
    // 2. It's an Image: Always apply the tint (don't bother caching 500 textures)
    // Note: If color is white {255,255,255,255}, it just draws normally.
    sdl.SetTextureColorMod(tex, color.r, color.g, color.b)
    sdl.SetTextureAlphaMod(tex, color.a)
  }

  // Draw
  sdl.RenderTextureRotated(Renderer, tex, src_rect, &dst, f64(p.rotation), sdl.FPoint{pivot.x, pivot.y}, .NONE)

  // Consume the transform
  check_transform_consumption()
}

//---------------------------------------------
// - PIXELMAP/SDLSURFACE HELPERS
//---------------------------------------------

// internal SDLsurface (pixelmap) mutator
surface_set_pixel :: proc(surface: ^sdl.Surface, x, y: c.int, color: sdl.Color) {
    if x < 0 || x >= surface.w || y < 0 || y >= surface.h do return
    
    // 1. Calculate the exact byte offset (pitch is in bytes, RGBA is 4 bytes per pixel)
    byte_offset := (y * surface.pitch) + (x * 4)
    
    // 2. Cast the raw pointer to a byte array so we can index it safely
    pixels := cast([^]u8)surface.pixels
    
    // 3. Grab the address of the starting byte, cast it to a Color pointer, and assign the struct
    target_pixel := cast(^sdl.Color)(&pixels[byte_offset])
    target_pixel^ = color
}

//=========================================================================================
// GRAPHICS API: LUA BINDINGS
//=========================================================================================

// lua_graphics_draw_image implements: graphics.draw_image(img, x, y, [color])
// Draws an image. If 'img' is nil or has been released, this function
// returns silently to avoid forcing manual 'if img then' guards in Lua.
lua_graphics_draw_image :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	nargs := lua.gettop(L)
	if nargs < 3 {
		lua.L_error(L, cstring("graphics.draw_image expects at least: img, x, y"))
		return 0
	}

	// 1. IMPLICIT GUARD: Check if the first argument is actually userdata.
	// If the user passed 'nil' (because they released the image), we skip the draw.
	if lua.type(L, 1) != lua.Type.USERDATA {
		return 0
	}

	// 2. TYPE CHECK: Verify the userdata has the "Image_Meta" metatable.
	// L_testudata is used instead of L_checkudata to prevent a Lua-side crash.
	img := cast(^Image)lua.L_testudata(L, 1, cstring("Image_Meta"))

	// 3. VALIDITY CHECK: Exit if the image is invalid or the VRAM texture is gone.
	if img == nil || img.texture == nil {
		return 0
	}

	// 4. COORDINATES: Extract position from the stack.
	x := cast(f32)lua.L_checknumber(L, 2)
	y := cast(f32)lua.L_checknumber(L, 3)

	// 5. COLOR TINT: Pull integer, default to -1 (White), cast to u32, unpack.
	raw_color := lua.L_optinteger(L, 4, -1)
	color := unpack_color(cast(u32)raw_color)

	// 6. GEOMETRY: The destination rectangle matches the image's original dimensions.
	dst := sdl.FRect{x, y, img.width, img.height}

	// 7. RENDER: Dispatch to the hardware-level draw helper.
	draw_image_pixels(img.texture, nil, x, y, img.width, img.height, color)

	return 0
}

// lua_graphics_draw_image_region implements: graphics.draw_image_region(img, sx, sy, sw, sh, x, y, [color])
// Draws a specific rectangular sub-section of an image (a "source rect").
// This is the primary tool for spritesheets, tilemaps, and atlas rendering.
// Updated lua_graphics_image_region
lua_graphics_draw_image_region :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	nargs := lua.gettop(L)

	if nargs < 7 {
		lua.L_error(L, cstring("graphics.draw_image_region expects: img, sx, sy, sw, sh, x, y, [color]"))
		return 0
	}

	if lua.type(L, 1) != lua.Type.USERDATA do return 0

	img := cast(^Image)lua.L_testudata(L, 1, cstring("Image_Meta"))
	if img == nil || img.texture == nil do return 0

	sx := cast(f32)lua.L_checknumber(L, 2)
	sy := cast(f32)lua.L_checknumber(L, 3)
	sw := cast(f32)lua.L_checknumber(L, 4)
	sh := cast(f32)lua.L_checknumber(L, 5)
	x  := cast(f32)lua.L_checknumber(L, 6)
	y  := cast(f32)lua.L_checknumber(L, 7)

	// 5. COLOR TINT: Pull integer, default to -1 (White), cast to u32, unpack.
	raw_color := lua.L_optinteger(L, 8, -1)
	color := unpack_color(cast(u32)raw_color)

	// Create the source crop rect
	src := sdl.FRect{sx, sy, sw, sh}

	// Dispatch to hardware with the source rect and intended dimensions
	draw_image_pixels(img.texture, &src, x, y, sw, sh, color)

	return 0
}

// lua_graphics_draw_sprite implements: graphics.draw_sprite(atlas, idx, x, y, [color])
lua_graphics_draw_sprite :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	nargs := lua.gettop(L)

	// 1. SUBJECT: Extract Atlas and Index.
	atlas := cast(^Atlas)lua.L_checkudata(L, 1, cstring("Atlas_Meta"))
	idx   := int(lua.L_checknumber(L, 2))

	// 2. SPATIAL: Extract position.
	x := f32(lua.L_checknumber(L, 3))
	y := f32(lua.L_checknumber(L, 4))

	// 5. COLOR TINT: Pull integer, default to -1 (White), cast to u32, unpack.
	raw_color := lua.L_optinteger(L, 5, -1)
	color := unpack_color(cast(u32)raw_color)

	// 4. LOGIC: Guard against OOB frame indices.
	if idx < 0 || idx >= (atlas.cols * atlas.rows) {
		fmt.eprintln("WARN: draw_sprite index OOB:", idx)
		return 0
	}

	// 5. MATH: Calculate source rectangle.
	src := sdl.FRect{
		x = f32(idx % atlas.cols) * atlas.cell_w,
		y = f32(idx / atlas.cols) * atlas.cell_h,
		w = atlas.cell_w,
		h = atlas.cell_h,
	}

	// 6. RENDER: Dispatch to hardware.
	draw_image_pixels(atlas.image.texture, &src, x, y, atlas.cell_w, atlas.cell_h, color)

	return 0
}

// lua_graphics_draw_rect implements: graphics.draw_rect(x, y, w, h, [color])
// Draws a filled rectangle. Internally, this stretches the 1x1 'gfx_ctx.base_rect_texture'
// to the desired dimensions and applies a color tint.
lua_graphics_draw_rect :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	nargs := lua.gettop(L)

	x := cast(f32)lua.L_checknumber(L, 1)
	y := cast(f32)lua.L_checknumber(L, 2)
	w := cast(f32)lua.L_checknumber(L, 3)
	h := cast(f32)lua.L_checknumber(L, 4)

	// 5. COLOR TINT: Pull integer, default to -1 (White), cast to u32, unpack.
	raw_color := lua.L_optinteger(L, 5, -1)
	color := unpack_color(cast(u32)raw_color)

	// We treat the rectangle as a stretched 1x1 image.
	dst := sdl.FRect{x, y, w, h}

	// Apply color tinting to our white pixel
	sdl.SetTextureColorMod(gfx_ctx.base_rect_texture, color.r, color.g, color.b)
	sdl.SetTextureAlphaMod(gfx_ctx.base_rect_texture, color.a)

	// Draw the 1px texture stretched to the rect size
	draw_image_pixels(gfx_ctx.base_rect_texture, nil, x, y, w, h, color)

	return 0
}

// lua_graphics_clear implements: graphics.clear([color])
// Clears the entire render target. The color argument is optional and defaults to black.
lua_graphics_clear :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	nargs := lua.gettop(L)

	// 5. COLOR TINT: Pull integer, default to 255 (Black), cast to u32, unpack.
	raw_color := lua.L_optinteger(L, 1, 255)
	color := unpack_color(cast(u32)raw_color)

	// Route through the cache to prevent state desync
	set_render_color(color)
	sdl.RenderClear(Renderer)

	return 0
}

// lua_graphics_draw_debug_text implements: graphics.draw_debug_text(x, y, text, [color])
// Draws simple 8x8 bitmap text to the screen for debugging purposes.
lua_graphics_draw_debug_text :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	nargs := lua.gettop(L)
	if nargs < 3 {
		lua.L_error(L, cstring("graphics.draw_debug_text expects: x, y, text, [color]"))
		return 0
	}

	// 1. Extract coordinates and string
	x := cast(f32)lua.L_checknumber(L, 1)
	y := cast(f32)lua.L_checknumber(L, 2)

	text_len: c.size_t
	text_c := lua.L_checklstring(L, 3, &text_len)

	// 5. COLOR TINT: Pull integer, default to -1 (White), cast to u32, unpack.
	raw_color := lua.L_optinteger(L, 4, -1)
	color := unpack_color(cast(u32)raw_color)

	// 3. Apply state and draw
	set_render_color(color)

	if !sdl.RenderDebugText(Renderer, x, y, text_c) {
		fmt.eprintln("Debug text failed:", sdl.GetError())
	}

	return 0
}


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
        gfx_ctx.default_scale_mode = .NEAREST
    } else if mode_str == "linear" {
        gfx_ctx.default_scale_mode = .LINEAR
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
// DRAW TRANSFORMATION
//---------------------------------------------

// lua_graphics_set_draw_rotation: graphics.set_draw_rotation(angle: number = 0)
lua_graphics_set_draw_rotation :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	gfx_ctx.pending.rotation = cast(f32)lua.L_optnumber(L, 1, 0.0)
	return 0
}

// lua_graphics_set_draw_scale: graphics.set_draw_scale(sx: number = 1, sy: number = sx)
lua_graphics_set_draw_scale :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	sx := lua.L_optnumber(L, 1, 1.0)
	// If sy isn't provided, we default to sx to perform a uniform scale.
	sy := lua.L_optnumber(L, 2, sx) 
	
	gfx_ctx.pending.scale.x = cast(f32)sx
	gfx_ctx.pending.scale.y = cast(f32)sy
	return 0
}

// lua_graphics_set_draw_origin: graphics.set_draw_origin(ox: number = 0, oy: number = 0)
lua_graphics_set_draw_origin :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	gfx_ctx.pending.origin.x = cast(f32)lua.L_optnumber(L, 1, 0.0)
	gfx_ctx.pending.origin.y = cast(f32)lua.L_optnumber(L, 2, 0.0)
	return 0
}

// lua_graphics_begin_transform_group: graphics.begin_transform_group()
lua_graphics_begin_transform_group :: proc "c" (L: ^lua.State) -> c.int {
	gfx_ctx.group_depth += 1
	return 0
}

// lua_graphics_end_transform_group: graphics.end_transform_group()
lua_graphics_end_transform_group :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	gfx_ctx.group_depth = math.max(0, gfx_ctx.group_depth - 1)
	
	// If we've popped the last group, reset the pen to neutral defaults.
	if gfx_ctx.group_depth == 0 {
		reset_pending_transforms()
	}
	return 0
}

//---------------------------------------------
// PIXELMAP [WIP]
//---------------------------------------------

// -- IO & Allocation
// .load_pixelmap("file.png") -> pmap, w, h
// .new_pixelmap(w, h) -> pmap
// .get_pixelmap_size(pmap) - > w, h
// .save_pixelmap(pmap, "out.png")

// -- Atomic Math
// .get_pixel(pmap, x, y) -> r, g, b, a
// .set_pixel(pmap, x, y, color)

// -- Geometric drawing
// .pixelmap_fill_rect(pmap, x, y, w, h, color)
// .pixelmap_fill_circle(pmap, x, y, radius, color)

// -- Array-to-Array operations
// .pixelmap_blit(dst_map, src_map, dest_x, dest_y, blend_mode?) -- Modes: "blend", "replace", "add", "multiply"
// .pixelmap_erase(dst_map, mask_map, dest_x, dest_y)            -- Implicitly uses your custom Destructive Masking mode

// -- VRAM Sync
// .new_image_from_pixelmap(pmap) -> img
// .update_image_from_pixelmap(img, pmap, dx?, dy?, dw?, dh?)

// -- FFI
// .get_pixelmap_rawdata()
// .pixelmap_clone(pmap)


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
    lua.pushcfunction(L, lua_graphics_clear)
    lua.setfield(L, -2, cstring("clear"))

    lua.pushcfunction(L, lua_graphics_draw_rect)
    lua.setfield(L, -2, cstring("draw_rect"))

    lua.pushcfunction(L, lua_graphics_draw_debug_text)
    lua.setfield(L, -2, cstring("draw_debug_text"))

    lua.pushcfunction(L, lua_graphics_draw_image)
    lua.setfield(L, -2, cstring("draw_image"))

    lua.pushcfunction(L, lua_graphics_draw_image_region)
    lua.setfield(L, -2, cstring("draw_image_region"))

    lua.pushcfunction(L, lua_graphics_draw_sprite)
    lua.setfield(L, -2, cstring("draw_sprite"))

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
    lua.pushcfunction(L, lua_graphics_set_draw_rotation)
    lua.setfield(L, -2, cstring("set_draw_rotation"))

    lua.pushcfunction(L, lua_graphics_set_draw_scale)
    lua.setfield(L, -2, cstring("set_draw_scale"))

    lua.pushcfunction(L, lua_graphics_set_draw_origin)
    lua.setfield(L, -2, cstring("set_draw_origin"))

    lua.pushcfunction(L, lua_graphics_begin_transform_group)
    lua.setfield(L, -2, cstring("begin_transform_group"))

    lua.pushcfunction(L, lua_graphics_end_transform_group)
    lua.setfield(L, -2, cstring("end_transform_group"))

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
