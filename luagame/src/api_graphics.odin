package main

import "base:runtime"
import "core:c"
import "core:math"
import "core:math/linalg"
import lua "luajit"
import sdl "vendor:sdl3"
import "vendor:sdl3/ttf"
import stbi "vendor:stb/image"

//TODO:

// Text & Fonts: Integration with SDL_ttf for font loading and text rendering.
// Particle System
// Shaders (see notes)

//Lua-side modules:
//sprite/animation system

//DONE!!!
// Render Targets: Support for rendering to textures.
// Scissor/clip rect
// Blend Modes: Global or per-draw blending control.
// 1px: debug_line, outline debug_rect,
//TRANSFORM PIPELINE
//Image IO
//Image/region/rect drawing (GPU)
//Pixelmap API (CPU Read/Write)

// ============================================================================
// Graphics State And Helpers
// ============================================================================

// - Types And Global Context

// Image represents a hardware texture allocated in GPU VRAM.
Image :: struct {
    texture: ^sdl.Texture,
    width:   f32,
    height:  f32,
}

Pixelmap :: struct {
    surface: ^sdl.Surface,
}

u32rgba :: distinct u32

Gfx_Ctx: struct {
    current_sdl_color:  u32rgba,
    default_scale_mode: sdl.ScaleMode,
    current_blend_mode: sdl.BlendMode,
    transform:          struct {
        matrix_stack: [32]matrix[3, 3]f32,
        group_depth:  int,
    },
}

// - Graphics System Helpers

check_render_safety :: #force_inline proc "contextless"(L: ^lua.State, fn_name: cstring) {
    if Renderer == nil { 
        lua.L_error(L, "%s: graphics system not initialized yet", fn_name) 
    }
}

// CPU state only. Safe to call at boot.
init_graphics_state :: proc() {
    Gfx_Ctx.current_sdl_color = u32rgba(0xFFFFFFFF)
    Gfx_Ctx.default_scale_mode = .LINEAR
    Gfx_Ctx.current_blend_mode = sdl.BLENDMODE_BLEND

    // '1' is the Odin literal for an Identity Matrix
    Gfx_Ctx.transform.matrix_stack[0] = 1
    Gfx_Ctx.transform.group_depth = 0
}

// load_image_from_path handles the hardware-level pipeline: Disk -> CPU RAM -> GPU VRAM.
// Returns an Image struct, an error string, and a success boolean.
load_image_from_path :: proc(path: cstring) -> (Image, cstring, bool) {
    w, h, channels: c.int
    pixels := stbi.load(path, &w, &h, &channels, 4)
    if pixels == nil {
        reason := stbi.failure_reason()
        if reason == nil do reason = "failed to decode image"
        return {}, reason, false
    }
    defer stbi.image_free(pixels)

    texture := sdl.CreateTexture(Renderer, .RGBA32, .STATIC, w, h)
    if texture == nil {
        reason := sdl.GetError()
        if reason == nil do reason = "failed to create texture"
        return {}, reason, false
    }

    sdl.UpdateTexture(texture, nil, pixels, w * 4)
    sdl.SetTextureBlendMode(texture, {.BLEND})
    sdl.SetTextureScaleMode(texture, Gfx_Ctx.default_scale_mode)

    return Image{texture, f32(w), f32(h)}, nil, true
}

set_global_sdl_color :: proc(c: u32rgba) {
    if Gfx_Ctx.current_sdl_color != c {
        r := u8((u32(c) >> 24) & 0xFF)
        g := u8((u32(c) >> 16) & 0xFF)
        b := u8((u32(c) >> 8) & 0xFF)
        a := u8(u32(c) & 0xFF)
        sdl.SetRenderDrawColor(Renderer, r, g, b, a)
        Gfx_Ctx.current_sdl_color = c
    }
}

unpack_fcolor :: #force_inline proc(c: u32rgba) -> sdl.FColor {
    return sdl.FColor {
        f32((u32(c) >> 24) & 0xFF) / 255.0,
        f32((u32(c) >> 16) & 0xFF) / 255.0,
        f32((u32(c) >> 8) & 0xFF) / 255.0,
        f32(u32(c) & 0xFF) / 255.0,
    }
}

// - Render Geometry Helpers

// draw_geometry submits a textured quad with explicit UV coordinates.
draw_geometry :: proc(
    tex: ^sdl.Texture,
    x, y, w, h: f32,
    u0, v0, u1, v1: f32,
    color: u32rgba,
    m: matrix[3, 3]f32,
) {
    fc := unpack_fcolor(color)

    tl := (m * [3]f32{x, y, 1}).xy
    tr := (m * [3]f32{x + w, y, 1}).xy
    br := (m * [3]f32{x + w, y + h, 1}).xy
    bl := (m * [3]f32{x, y + h, 1}).xy

    verts := [4]sdl.Vertex {
        {position = cast(sdl.FPoint)tl, color = fc, tex_coord = {u0, v0}},
        {position = cast(sdl.FPoint)tr, color = fc, tex_coord = {u1, v0}},
        {position = cast(sdl.FPoint)br, color = fc, tex_coord = {u1, v1}},
        {position = cast(sdl.FPoint)bl, color = fc, tex_coord = {u0, v1}},
    }

    indices := [6]c.int{0, 1, 2, 0, 2, 3}

    if tex != nil {
        sdl.SetTextureBlendMode(tex, Gfx_Ctx.current_blend_mode)
    }

    sdl.RenderGeometry(Renderer, tex, raw_data(verts[:]), 4, raw_data(indices[:]), 6)
}

// - Pixelmap Helpers

// Helper to flip Lua's 0xRRGGBBAA to the physical 0xAABBGGRR memory layout.
// This compiles down to a single CPU bswap instruction.
u32_rgba_to_abgr :: #force_inline proc(c: u32) -> u32 {
    return (c >> 24) | ((c >> 8) & 0xFF00) | ((c << 8) & 0x00FF0000) | (c << 24)
}

PixelmapBlendMode :: enum {
    Replace,
    Blend,
    Add,
    Multiply,
    Erase,
    Mask,
}

parse_blend_mode_checked :: #force_inline proc(
    L: ^lua.State,
    mode_str: cstring,
    fn_name: cstring,
) -> PixelmapBlendMode {
    if mode_str == nil do return .Blend

    switch string(mode_str) {
    case "replace":
        return .Replace
    case "blend":
        return .Blend
    case "add":
        return .Add
    case "multiply":
        return .Multiply
    case "erase":
        return .Erase
    case "mask":
        return .Mask
    case:
        lua.L_error(L, "%s: unknown blend mode '%s'", fn_name, mode_str)
        return .Blend
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
blit_pixel :: #force_inline proc(
    surf: ^sdl.Surface,
    x, y: int,
    color: u32,
    mode: PixelmapBlendMode,
) {
    if x >= 0 && x < int(surf.w) && y >= 0 && y < int(surf.h) {
        pixels := cast([^]u32)surf.pixels
        idx := y * (int(surf.pitch) / 4) + x
        pixels[idx] = blend_memory_colors(pixels[idx], color, mode)
    }
}

// Internal helper to calculate safe iteration bounds for floating-point shapes
get_clipped_bounds :: #force_inline proc(
    surf: ^sdl.Surface,
    min_x, min_y, max_x, max_y: f32,
) -> (
    start_x, start_y, end_x, end_y: int,
    valid: bool,
) {
    start_x = max(0, cast(int)math.floor(min_x))
    start_y = max(0, cast(int)math.floor(min_y))
    end_x = min(int(surf.w), cast(int)math.ceil(max_x) + 1)
    end_y = min(int(surf.h), cast(int)math.ceil(max_y) + 1)

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

    proj := [2]f32{a.x + t * dx, a.y + t * dy}

    px := p.x - proj.x
    py := p.y - proj.y
    return px * px + py * py
}

// ============================================================================
// Lua Graphics Bindings
// ============================================================================

// - Image I/O

// lua_graphics_load_image implements: graphics.load_image(path) -> Image | nil, err
lua_graphics_load_image :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.load_image")

    if lua.gettop(L) != 1 {
        lua.L_error(L, "graphics.load_image: expected 1 argument: path")
        return 0
    }

    path_cstr := cast(cstring)lua.L_checklstring(L, 1, nil)

    img, err, ok := load_image_from_path(path_cstr)
    if !ok {
        lua.pushnil(L)
        if err != nil {
            lua.pushfstring(L, "graphics.load_image: %s", err)
        } else {
            lua.pushstring(L, "graphics.load_image: failed to load image")
        }
        return 2
    }

    data := cast(^Image)lua.newuserdata(L, size_of(Image))
    data^ = img

    lua.L_getmetatable(L, "Image")
    lua.setmetatable(L, -2)

    return 1
}

// - GPU Drawing

// lua_graphics_draw_image implements: graphics.draw_image(img, x, y, [color])
lua_graphics_draw_image :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.draw_image")

    img := cast(^Image)lua.L_testudata(L, 1, "Image")
    if img == nil {
        if lua.isnil(L, 1) {
            lua.L_error(L, "graphics.draw_image: expected Image, got nil (did graphics.load_image fail?)")
        } else {
            lua.L_error(L, "graphics.draw_image: expected Image")
        }
        return 0
    }

    if img.texture == nil do return 0

    x := f32(lua.L_checknumber(L, 2))
    y := f32(lua.L_checknumber(L, 3))
    raw_color := lua.L_optinteger(L, 4, 0xFFFFFFFF)

    world_m := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]

    // Full image UVs: 0.0 to 1.0
    draw_geometry(img.texture, x, y, img.width, img.height, 0.0, 0.0, 1.0, 1.0, u32rgba(raw_color), world_m)

    return 0
}

// lua_graphics_draw_image_region implements: graphics.draw_image_region(img, sx, sy, sw, sh, x, y, [color])
lua_graphics_draw_image_region :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.draw_image_region")

    img := cast(^Image)lua.L_testudata(L, 1, "Image")
    if img == nil {
        if lua.isnil(L, 1) {
            lua.L_error(L, "graphics.draw_image_region: expected Image, got nil (did graphics.load_image fail?)")
        } else {
            lua.L_error(L, "graphics.draw_image_region: expected Image")
        }
        return 0
    }

    if img.texture == nil do return 0

    sx := f32(lua.L_checknumber(L, 2))
    sy := f32(lua.L_checknumber(L, 3))
    sw := f32(lua.L_checknumber(L, 4))
    sh := f32(lua.L_checknumber(L, 5))

    dx := f32(lua.L_checknumber(L, 6))
    dy := f32(lua.L_checknumber(L, 7))

    raw_color := lua.L_optinteger(L, 8, 0xFFFFFFFF)

    // Normalize pixel coordinates into UV space
    u0 := sx / img.width
    v0 := sy / img.height
    u1 := (sx + sw) / img.width
    v1 := (sy + sh) / img.height

    world_m := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]

    draw_geometry(img.texture, dx, dy, sw, sh, u0, v0, u1, v1, u32rgba(raw_color), world_m)

    return 0
}

// lua_graphics_draw_rect implements: graphics.draw_rect(x, y, w, h, [color])
// Draws a filled rectangle that respects the active transform stack.
lua_graphics_draw_rect :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.draw_rect")

    x := f32(lua.L_checknumber(L, 1))
    y := f32(lua.L_checknumber(L, 2))
    w := f32(lua.L_checknumber(L, 3))
    h := f32(lua.L_checknumber(L, 4))
    raw_color := lua.L_optinteger(L, 5, 0xFFFFFFFF)

    world_m := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]

    // Pass nil for texture. UVs (0,0,0,0) are ignored by SDL when untextured.
    draw_geometry(nil, x, y, w, h, 0.0, 0.0, 0.0, 0.0, u32rgba(raw_color), world_m)

    return 0
}

// lua_graphics_clear implements: graphics.clear([color])
// Clears the entire render target. Defaults to black.
lua_graphics_clear :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.clear")

    raw_color := lua.L_optinteger(L, 1, 0x000000FF)
    set_global_sdl_color(u32rgba(raw_color))
    sdl.RenderClear(Renderer)

    return 0
}

// - Debug Draws (no transform)

// lua_graphics_debug_line implements: graphics.debug_line(x1, y1, x2, y2, [color])
// Draws a 1px thick line directly to the screen, ignoring the transform stack.
// Use this for: Raycasts, velocity vectors, and quick debug indicators.
lua_graphics_debug_line :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.debug_line")

    x1 := cast(f32)lua.L_checknumber(L, 1)
    y1 := cast(f32)lua.L_checknumber(L, 2)
    x2 := cast(f32)lua.L_checknumber(L, 3)
    y2 := cast(f32)lua.L_checknumber(L, 4)
    raw_color := lua.L_optinteger(L, 5, 0xFFFFFFFF)

    set_global_sdl_color(u32rgba(raw_color))
    sdl.RenderLine(Renderer, x1, y1, x2, y2)

    return 0
}

// lua_graphics_debug_rect implements: graphics.debug_rect(x, y, w, h, [color])
// Draws a 1px hollow rectangle directly to the screen, ignoring the transform stack.
// Use this for: Hitboxes, bounds checking, and unbatched development visuals.
lua_graphics_debug_rect :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.debug_rect")

    x := cast(f32)lua.L_checknumber(L, 1)
    y := cast(f32)lua.L_checknumber(L, 2)
    w := cast(f32)lua.L_checknumber(L, 3)
    h := cast(f32)lua.L_checknumber(L, 4)
    raw_color := lua.L_optinteger(L, 5, 0xFFFFFFFF)

    set_global_sdl_color(u32rgba(raw_color))

    rect := sdl.FRect{x, y, w, h}
    sdl.RenderRect(Renderer, &rect)

    return 0
}

// lua_graphics_debug_text implements: graphics.debug_text(x, y, text, [color])
// Draws simple 8x8 bitmap text to the screen for debugging purposes.
lua_graphics_debug_text :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.debug_text")

    x := cast(f32)lua.L_checknumber(L, 1)
    y := cast(f32)lua.L_checknumber(L, 2)

    text_len: c.size_t
    text_c := lua.L_checklstring(L, 3, &text_len)

    raw_color := lua.L_optinteger(L, 4, 0xFFFFFFFF)
    set_global_sdl_color(u32rgba(raw_color))

    if !sdl.RenderDebugText(Renderer, x, y, text_c) {
        lua.L_error(L, "graphics.debug_text: failed to draw debug text: %s", sdl.GetError())
        return 0
    }

    return 0
}

// - Transform Pipeline


// lua_graphics_begin_transform implements: graphics.begin_transform()
lua_graphics_begin_transform :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if Gfx_Ctx.transform.group_depth >= 31 {
        lua.L_error(L, "graphics.begin_transform: transform stack overflow (max depth is 32)")
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
        lua.L_error(L, "graphics.end_transform: transform stack underflow (no transform block to end)")
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
        s, c, 0,
        0, 0, 1,
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
        sx, 0, 0,
        0, sy, 0,
        0, 0, 1,
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

    m := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]
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

// - Draw Utilities

// lua_graphics_set_default_filter implements: graphics.set_default_filter("nearest" | "linear")
lua_graphics_set_default_filter :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    mode_str := lua.L_checkstring(L, 1)

    if mode_str == "nearest" {
        Gfx_Ctx.default_scale_mode = .NEAREST
    } else if mode_str == "linear" {
        Gfx_Ctx.default_scale_mode = .LINEAR
    } else {
        lua.L_error(L, "graphics.set_default_filter: expected 'nearest' or 'linear'")
        return 0
    }

    return 0
}

// lua_graphics_get_image_size implements: graphics.get_image_size(img) -> w, h
// Returns nil, nil if the image has been freed.
lua_graphics_get_image_size :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    img := cast(^Image)lua.L_checkudata(L, 1, "Image")
    if img == nil || img.texture == nil {
        lua.pushnil(L)
        lua.pushnil(L)
        return 2
    }

    lua.pushnumber(L, cast(lua.Number)img.width)
    lua.pushnumber(L, cast(lua.Number)img.height)
    return 2
}

// - Render State

parse_gpu_blend_mode_checked :: #force_inline proc(
    L: ^lua.State,
    mode_str: cstring,
    fn_name: cstring,
) -> sdl.BlendMode {
    if mode_str == nil do return sdl.BLENDMODE_BLEND

    switch string(mode_str) {
    case "replace":
        return sdl.BLENDMODE_NONE
    case "blend":
        return sdl.BLENDMODE_BLEND
    case "add":
        return sdl.BLENDMODE_ADD
    case "multiply":
        return sdl.BLENDMODE_MUL
    case "modulate":
        return sdl.BLENDMODE_MOD
    case "premultiplied":
        return sdl.BLENDMODE_BLEND_PREMULTIPLIED
    case:
        lua.L_error(L, "%s: unknown blend mode '%s'", fn_name, mode_str)
        return sdl.BLENDMODE_BLEND
    }
}

// lua_graphics_set_blend_mode implements: graphics.set_blend_mode([mode])
lua_graphics_set_blend_mode :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.set_blend_mode")

    mode_str := lua.L_optstring(L, 1, "blend")
    mode := parse_gpu_blend_mode_checked(L, mode_str, "graphics.set_blend_mode")

    sdl.SetRenderDrawBlendMode(Renderer, mode)
    Gfx_Ctx.current_blend_mode = mode

    return 0
}

// lua_graphics_set_clip_rect implements: graphics.set_clip_rect([x, y, w, h])
// Sets a hardware clipping rectangle in absolute window coordinates.
// Passing no arguments disables the clipping entirely.
lua_graphics_set_clip_rect :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.set_clip_rect")

    // Disable clipping if called with zero arguments: graphics.set_clip_rect()
    if lua.gettop(L) == 0 {
        sdl.SetRenderClipRect(Renderer, nil)
        return 0
    }

    // Clip hardware requires integers.
    // NOTE: This operates in physical screen-space and ignores the current transform matrix.
    x := cast(c.int)lua.L_checkinteger(L, 1)
    y := cast(c.int)lua.L_checkinteger(L, 2)
    w := cast(c.int)lua.L_checkinteger(L, 3)
    h := cast(c.int)lua.L_checkinteger(L, 4)

    rect := sdl.Rect{x, y, w, h}
    sdl.SetRenderClipRect(Renderer, &rect)

    return 0
}

// lua_graphics_get_clip_rect implements: x, y, w, h = graphics.get_clip_rect()
// Returns the current hardware clip rectangle.
// Returns nothing if clipping is disabled.
lua_graphics_get_clip_rect :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.get_clip_rect")

    rect: sdl.Rect
    enabled := sdl.GetRenderClipRect(Renderer, &rect)

    if !enabled do return 0

    lua.pushinteger(L, cast(lua.Integer)rect.x)
    lua.pushinteger(L, cast(lua.Integer)rect.y)
    lua.pushinteger(L, cast(lua.Integer)rect.w)
    lua.pushinteger(L, cast(lua.Integer)rect.h)

    return 4
}

// graphics.new_canvas(w, h) -> Image | nil, err
lua_graphics_new_canvas :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.new_canvas")

    w := f32(lua.L_checknumber(L, 1))
    h := f32(lua.L_checknumber(L, 2))

    texture := sdl.CreateTexture(Renderer, .RGBA32, .TARGET, cast(c.int)w, cast(c.int)h)
    if texture == nil {
        lua.pushnil(L)

        err := sdl.GetError()
        if err != nil {
            lua.pushfstring(L, "graphics.new_canvas: failed to create canvas texture: %s", err)
        } else {
            lua.pushstring(L, "graphics.new_canvas: failed to create canvas texture")
        }
        return 2
    }

    sdl.SetTextureBlendMode(texture, {.BLEND})
    sdl.SetTextureScaleMode(texture, Gfx_Ctx.default_scale_mode)

    data := cast(^Image)lua.newuserdata(L, size_of(Image))
    data^ = Image { texture = texture, width = w, height = h }

    lua.L_getmetatable(L, "Image")
    lua.setmetatable(L, -2)

    return 1
}

// graphics.set_canvas([image])
lua_graphics_set_canvas :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.set_canvas")

    if lua.gettop(L) == 0 || lua.isnil(L, 1) {
        sdl.SetRenderTarget(Renderer, nil)
        return 0
    }

    img := cast(^Image)lua.L_checkudata(L, 1, "Image")
    if img == nil || img.texture == nil do return 0

    props := sdl.GetTextureProperties(img.texture)
    access := cast(sdl.TextureAccess)sdl.GetNumberProperty(props, sdl.PROP_TEXTURE_ACCESS_NUMBER, cast(i64)sdl.TextureAccess.STATIC)

    if access != .TARGET {
        lua.L_error( L, "graphics.set_canvas: image is not a render target (must be created with graphics.new_canvas)")
        return 0
    }

    if !sdl.SetRenderTarget(Renderer, img.texture) {
        lua.L_error(L, "graphics.set_canvas: failed to set render target: %s", sdl.GetError())
        return 0
    }

    return 0
}

// - Pixelmap API

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

// - Pixelmap I/O

// lua_graphics_new_pixelmap implements: graphics.new_pixelmap(w, h) -> pmap | nil, err
lua_graphics_new_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    w := cast(c.int)lua.L_checkinteger(L, 1)
    h := cast(c.int)lua.L_checkinteger(L, 2)

    surface := sdl.CreateSurface(w, h, sdl.PixelFormat.RGBA32)
    if surface == nil {
        lua.pushnil(L)

        err := sdl.GetError()
        if err != nil {
            lua.pushfstring(L, "graphics.new_pixelmap: failed to create pixelmap surface: %s", err)
        } else {
            lua.pushstring(L, "graphics.new_pixelmap: failed to create pixelmap surface")
        }

        return 2
    }

    sdl.FillSurfaceRect(surface, nil, 0x00000000)

    pmap := cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap))
    pmap^ = Pixelmap {
        surface = surface,
    }

    lua.L_getmetatable(L, "Pixelmap")
    lua.setmetatable(L, -2)

    return 1
}

// lua_graphics_load_pixelmap implements: graphics.load_pixelmap(path) -> pmap, w, h | nil, err
lua_graphics_load_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    path_cstr := cast(cstring)lua.L_checklstring(L, 1, nil)

    w, h, channels: c.int
    pixels := stbi.load(path_cstr, &w, &h, &channels, 4)
    if pixels == nil {
        lua.pushnil(L)

        err := stbi.failure_reason()
        if err != nil {
            lua.pushfstring(L, "graphics.load_pixelmap: failed to decode image: %s", err)
        } else {
            lua.pushstring(L, "graphics.load_pixelmap: failed to decode image")
        }

        return 2
    }
    defer stbi.image_free(pixels)

    surface := sdl.CreateSurface(w, h, sdl.PixelFormat.RGBA32)
    if surface == nil {
        lua.pushnil(L)

        err := sdl.GetError()
        if err != nil {
            lua.pushfstring(L, "graphics.load_pixelmap: failed to create pixelmap surface: %s", err)
        } else {
            lua.pushstring(L, "graphics.load_pixelmap: failed to create pixelmap surface")
        }

        return 2
    }

    runtime.mem_copy(surface.pixels, pixels, int(surface.pitch * h))

    pmap := cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap))
    pmap^ = Pixelmap {
        surface = surface,
    }

    lua.L_getmetatable(L, "Pixelmap")
    lua.setmetatable(L, -2)

    lua.pushinteger(L, cast(lua.Integer)w)
    lua.pushinteger(L, cast(lua.Integer)h)

    return 3
}

// lua_graphics_get_pixelmap_size implements: graphics.get_pixelmap_size(pmap) -> w, h
// Returns nil, nil if the pixelmap has been freed.
lua_graphics_get_pixelmap_size :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil {
        lua.pushnil(L)
        lua.pushnil(L)
        return 2
    }
    lua.pushinteger(L, cast(lua.Integer)pmap.surface.w)
    lua.pushinteger(L, cast(lua.Integer)pmap.surface.h)
    return 2
}

// lua_graphics_save_pixelmap implements: graphics.save_pixelmap(pmap, path) -> ok, err?
lua_graphics_save_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    path_cstr := cast(cstring)lua.L_checklstring(L, 2, nil)

    if pmap == nil || pmap.surface == nil {
        lua.pushboolean(L, b32(false))
        lua.pushstring(L, "graphics.save_pixelmap: pixelmap has been freed")
        return 2
    }

    res := stbi.write_png(path_cstr, pmap.surface.w, pmap.surface.h, 4, pmap.surface.pixels, pmap.surface.pitch)

    if res == 0 {
        lua.pushboolean(L, b32(false))
        lua.pushstring(L, "graphics.save_pixelmap: failed to write PNG (check file path and permissions)")
        return 2
    }

    lua.pushboolean(L, b32(true))
    return 1
}

// - Pixelmap Atomic Ops

// lua_graphics_pixelmap_set_pixel implements: graphics.pixelmap_set_pixel(pmap, x, y, color)
lua_graphics_pixelmap_set_pixel :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
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
// Returns nil if the pixelmap has been freed.
// Returns 0 for out-of-bounds reads.
lua_graphics_pixelmap_get_pixel :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil {
        lua.pushnil(L)
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
    logical_color := u32_rgba_to_abgr(mem_color)

    lua.pushinteger(L, cast(lua.Integer)logical_color)
    return 1
}

// lua_graphics_pixelmap_flood_fill implements: graphics.pixelmap_flood_fill(pmap, x, y, color)
lua_graphics_pixelmap_flood_fill :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
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
            for x in span_left ..= span_right {
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
            for x in span_left ..= span_right {
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

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
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
        if e2 >= dy {err += dy; x0 += sx}
        if e2 <= dx {err += dx; y0 += sy}
    }

    // Missed
    lua.pushboolean(L, false)
    return 1
}

// - Pixelmap Geometry

// lua_graphics_blit_rect implements: graphics.blit_rect(pmap, x, y, w, h, [color], [mode])
lua_graphics_blit_rect :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil do return 0

    x := cast(int)lua.L_checkinteger(L, 2)
    y := cast(int)lua.L_checkinteger(L, 3)
    w := cast(int)lua.L_checkinteger(L, 4)
    h := cast(int)lua.L_checkinteger(L, 5)
    color_u32 := cast(u32)lua.L_optinteger(L, 6, -1)
    mode := parse_blend_mode_checked(L, lua.L_optstring(L, 7, "blend"), "graphics.blit_rect")

    if w <= 0 || h <= 0 do return 0
    surf := pmap.surface

    start_x, start_y := max(0, x), max(0, y)
    end_x, end_y := min(int(surf.w), x + w), min(int(surf.h), y + h)
    if start_x >= end_x || start_y >= end_y do return 0

    mem_color := u32_rgba_to_abgr(color_u32)
    pixels := cast([^]u32)surf.pixels
    stride := int(surf.pitch) / 4

    for row in start_y ..< end_y {
        row_idx := row * stride
        for col in start_x ..< end_x {
            idx := row_idx + col
            pixels[idx] = blend_memory_colors(pixels[idx], mem_color, mode)
        }
    }
    return 0
}

// lua_graphics_blit_triangle implements: graphics.blit_triangle(pmap, x1, y1, x2, y2, x3, y3, [color], [mode])
lua_graphics_blit_triangle :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil do return 0

    x1 := cast(f32)lua.L_checknumber(L, 2)
    y1 := cast(f32)lua.L_checknumber(L, 3)
    x2 := cast(f32)lua.L_checknumber(L, 4)
    y2 := cast(f32)lua.L_checknumber(L, 5)
    x3 := cast(f32)lua.L_checknumber(L, 6)
    y3 := cast(f32)lua.L_checknumber(L, 7)

    color_u32 := cast(u32)lua.L_optinteger(L, 8, -1)
    mode := parse_blend_mode_checked(L, lua.L_optstring(L, 9, "blend"), "graphics.blit_triangle")

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

    for y_px in start_y ..< end_y {
        row_idx := y_px * stride
        py := f32(y_px) + 0.5 // Sample at pixel center

        for x_px in start_x ..< end_x {
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

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil do return 0

    x0 := cast(int)lua.L_checkinteger(L, 2)
    y0 := cast(int)lua.L_checkinteger(L, 3)
    x1 := cast(int)lua.L_checkinteger(L, 4)
    y1 := cast(int)lua.L_checkinteger(L, 5)
    color_u32 := cast(u32)lua.L_optinteger(L, 6, -1)
    mode := parse_blend_mode_checked(L, lua.L_optstring(L, 7, "blend"), "graphics.blit_line")

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
        if e2 >= dy {err += dy; x0 += sx}
        if e2 <= dx {err += dx; y0 += sy}
    }
    return 0
}

// lua_graphics_blit_circle implements: graphics.blit_circle(pmap, cx, cy, radius, [color], [mode])
lua_graphics_blit_circle :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil do return 0

    cx := cast(f32)lua.L_checknumber(L, 2)
    cy := cast(f32)lua.L_checknumber(L, 3)
    r := cast(f32)lua.L_checknumber(L, 4)
    color := cast(u32)lua.L_optinteger(L, 5, -1)
    mode := parse_blend_mode_checked(L, lua.L_optstring(L, 6, "blend"), "graphics.blit_circle")

    surf := pmap.surface
    mem_c := u32_rgba_to_abgr(color)
    r_sq := r * r

    start_x, start_y, end_x, end_y, ok := get_clipped_bounds(surf, cx - r, cy - r, cx + r, cy + r)
    if !ok do return 0

    pixels := cast([^]u32)surf.pixels
    stride := int(surf.pitch) / 4

    for y_px in start_y ..< end_y {
        row_idx := y_px * stride
        dy := f32(y_px) + 0.5 - cy
        dy_sq := dy * dy
        for x_px in start_x ..< end_x {
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

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil do return 0

    cx := cast(f32)lua.L_checknumber(L, 2)
    cy := cast(f32)lua.L_checknumber(L, 3)
    r := cast(f32)lua.L_checknumber(L, 4)
    thick := cast(f32)lua.L_checknumber(L, 5)
    color := cast(u32)lua.L_optinteger(L, 6, -1)
    mode := parse_blend_mode_checked(L, lua.L_optstring(L, 7, "blend"), "graphics.blit_circle_outline")

    surf := pmap.surface
    mem_c := u32_rgba_to_abgr(color)
    r_sq := r * r

    inner_r := max(0.0, r - thick)
    inner_r_sq := inner_r * inner_r

    start_x, start_y, end_x, end_y, ok := get_clipped_bounds(surf, cx - r, cy - r, cx + r, cy + r)
    if !ok do return 0

    pixels := cast([^]u32)surf.pixels
    stride := int(surf.pitch) / 4

    for y_px in start_y ..< end_y {
        row_idx := y_px * stride
        dy := f32(y_px) + 0.5 - cy
        dy_sq := dy * dy
        for x_px in start_x ..< end_x {
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

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil do return 0

    cx := cast(int)lua.L_checkinteger(L, 2)
    cy := cast(int)lua.L_checkinteger(L, 3)
    radius := cast(int)lua.L_checkinteger(L, 4)
    color_u32 := cast(u32)lua.L_optinteger(L, 5, -1)
    mode := parse_blend_mode_checked(L, lua.L_optstring(L, 6, "blend"), "graphics.blit_circle_pixel_outline")

    if radius < 0 do return 0

    surf := pmap.surface
    mem_color := u32_rgba_to_abgr(color_u32)

    x := 0
    y := radius
    d := 3 - 2 * radius

    for x <= y {
        blit_pixel(surf, cx + x, cy + y, mem_color, mode)
        if x != 0 do blit_pixel(surf, cx - x, cy + y, mem_color, mode)
        if y != 0 do blit_pixel(surf, cx + x, cy - y, mem_color, mode)
        if x != 0 && y != 0 do blit_pixel(surf, cx - x, cy - y, mem_color, mode)

        if x != y {
            blit_pixel(surf, cx + y, cy + x, mem_color, mode)
            if x != 0 do blit_pixel(surf, cx + y, cy - x, mem_color, mode)
            if y != 0 do blit_pixel(surf, cx - y, cy + x, mem_color, mode)
            if x != 0 && y != 0 do blit_pixel(surf, cx - y, cy - x, mem_color, mode)
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

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil do return 0

    x1 := cast(f32)lua.L_checknumber(L, 2)
    y1 := cast(f32)lua.L_checknumber(L, 3)
    x2 := cast(f32)lua.L_checknumber(L, 4)
    y2 := cast(f32)lua.L_checknumber(L, 5)
    r := cast(f32)lua.L_checknumber(L, 6)
    color_u32 := cast(u32)lua.L_optinteger(L, 7, -1)
    mode := parse_blend_mode_checked(L, lua.L_optstring(L, 8, "blend"), "graphics.blit_capsule")

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

    for y_px in start_y ..< end_y {
        row_idx := y_px * stride
        for x_px in start_x ..< end_x {
            if dist_sq_to_segment({f32(x_px) + 0.5, f32(y_px) + 0.5}, a, b) <= r_sq {
                idx := row_idx + x_px
                pixels[idx] = blend_memory_colors(pixels[idx], mem_color, mode)
            }
        }
    }
    return 0
}

// - Pixelmap Blit

// lua_graphics_blit implements: graphics.blit(dst_map, src_map, dx, dy, [mode])
lua_graphics_blit :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    dst_pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    src_pmap := cast(^Pixelmap)lua.L_checkudata(L, 2, "Pixelmap")
    if dst_pmap == nil || dst_pmap.surface == nil || src_pmap == nil || src_pmap.surface == nil do return 0

    dest_x := cast(int)lua.L_checkinteger(L, 3)
    dest_y := cast(int)lua.L_checkinteger(L, 4)
    mode := parse_blend_mode_checked(L, lua.L_optstring(L, 5, "blend"), "graphics.blit")

    dst_surf, src_surf := dst_pmap.surface, src_pmap.surface

    start_x, start_y := max(0, -dest_x), max(0, -dest_y)
    end_x, end_y :=
        min(int(src_surf.w), int(dst_surf.w) - dest_x),
        min(int(src_surf.h), int(dst_surf.h) - dest_y)
    if start_x >= end_x || start_y >= end_y do return 0

    dst_pixels := cast([^]u32)dst_surf.pixels
    src_pixels := cast([^]u32)src_surf.pixels
    dst_stride, src_stride := int(dst_surf.pitch) / 4, int(src_surf.pitch) / 4

    for y in start_y ..< end_y {
        src_row, dst_row := y * src_stride, (dest_y + y) * dst_stride
        for x in start_x ..< end_x {
            src_idx, dst_idx := src_row + x, dst_row + (dest_x + x)
            dst_pixels[dst_idx] = blend_memory_colors(dst_pixels[dst_idx], src_pixels[src_idx], mode)
        }
    }
    return 0
}

// lua_graphics_blit_region implements: graphics.blit_region(dst, src, sx, sy, w, h, dx, dy, [mode])
lua_graphics_blit_region :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    dst_pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    src_pmap := cast(^Pixelmap)lua.L_checkudata(L, 2, "Pixelmap")
    if dst_pmap == nil || dst_pmap.surface == nil || src_pmap == nil || src_pmap.surface == nil do return 0

    src_x := cast(int)lua.L_checkinteger(L, 3)
    src_y := cast(int)lua.L_checkinteger(L, 4)
    bw := cast(int)lua.L_checkinteger(L, 5)
    bh := cast(int)lua.L_checkinteger(L, 6)
    dst_x := cast(int)lua.L_checkinteger(L, 7)
    dst_y := cast(int)lua.L_checkinteger(L, 8)
    mode := parse_blend_mode_checked(L, lua.L_optstring(L, 9, "blend"), "graphics.blit_region")

    dst_surf, src_surf := dst_pmap.surface, src_pmap.surface
    if bw <= 0 || bh <= 0 do return 0

    if src_x < 0 {bw += src_x; dst_x -= src_x; src_x = 0}
    if src_y < 0 {bh += src_y; dst_y -= src_y; src_y = 0}
    if dst_x < 0 {bw += dst_x; src_x -= dst_x; dst_x = 0}
    if dst_y < 0 {bh += dst_y; src_y -= dst_y; dst_y = 0}

    if src_x + bw > int(src_surf.w) do bw = int(src_surf.w) - src_x
    if src_y + bh > int(src_surf.h) do bh = int(src_surf.h) - src_y
    if dst_x + bw > int(dst_surf.w) do bw = int(dst_surf.w) - dst_x
    if dst_y + bh > int(dst_surf.h) do bh = int(dst_surf.h) - dst_y
    if bw <= 0 || bh <= 0 do return 0

    dst_pixels := cast([^]u32)dst_surf.pixels
    src_pixels := cast([^]u32)src_surf.pixels
    dst_stride, src_stride := int(dst_surf.pitch) / 4, int(src_surf.pitch) / 4

    for y in 0 ..< bh {
        src_row, dst_row := (src_y + y) * src_stride, (dst_y + y) * dst_stride
        for x in 0 ..< bw {
            src_idx, dst_idx := src_row + (src_x + x), dst_row + (dst_x + x)
            dst_pixels[dst_idx] = blend_memory_colors(dst_pixels[dst_idx], src_pixels[src_idx], mode)
        }
    }
    return 0
}

// - Image Mutation And VRAM Sync

// lua_graphics_new_image_from_pixelmap implements: graphics.new_image_from_pixelmap(pmap) -> img | nil, err
lua_graphics_new_image_from_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.new_image_from_pixelmap")

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil {
        lua.pushnil(L)
        lua.pushstring(L, "graphics.new_image_from_pixelmap: source pixelmap has been freed")
        return 2
    }

    surf := pmap.surface

    texture := sdl.CreateTextureFromSurface(Renderer, surf)
    if texture == nil {
        lua.pushnil(L)

        err := sdl.GetError()
        if err != nil {
            lua.pushfstring(L, "graphics.new_image_from_pixelmap: failed to create texture from pixelmap: %s", err)
        } else {
            lua.pushstring(L,"graphics.new_image_from_pixelmap: failed to create texture from pixelmap")
        }
        return 2
    }

    sdl.SetTextureBlendMode(texture, {.BLEND})
    sdl.SetTextureScaleMode(texture, Gfx_Ctx.default_scale_mode)

    img := cast(^Image)lua.newuserdata(L, size_of(Image))
    img^ = Image { texture = texture, width = f32(surf.w), height = f32(surf.h) }

    lua.L_getmetatable(L, "Image")
    lua.setmetatable(L, -2)

    return 1
}

// lua_graphics_update_image_from_pixelmap implements: graphics.update_image_from_pixelmap(img, pmap, [dx, dy])
// Syncs the entire CPU pixelmap to the GPU image at an optional destination offset.
lua_graphics_update_image_from_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.update_image_from_pixelmap")

    img := cast(^Image)lua.L_checkudata(L, 1, "Image")
    pmap := cast(^Pixelmap)lua.L_checkudata(L, 2, "Pixelmap")

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
    check_render_safety(L, "graphics.update_image_region_from_pixelmap")

    img := cast(^Image)lua.L_checkudata(L, 1, "Image")
    pmap := cast(^Pixelmap)lua.L_checkudata(L, 2, "Pixelmap")

    if img == nil || img.texture == nil || pmap == nil || pmap.surface == nil do return 0

    sx := cast(c.int)lua.L_checkinteger(L, 3)
    sy := cast(c.int)lua.L_checkinteger(L, 4)
    w := cast(c.int)lua.L_checkinteger(L, 5)
    h := cast(c.int)lua.L_checkinteger(L, 6)
    dx := cast(c.int)lua.L_checkinteger(L, 7)
    dy := cast(c.int)lua.L_checkinteger(L, 8)

    surf := pmap.surface

    // Guard against reading physical CPU memory out of bounds
    if sx < 0 || sy < 0 || sx + w > surf.w || sy + h > surf.h || w <= 0 || h <= 0 {
        return 0
    }

    dst_rect := sdl.Rect{dx, dy, w, h}

    // Pitch is bytes-per-row. x * 4 is bytes-per-column.
    byte_offset := (int(sy) * int(surf.pitch)) + (int(sx) * 4)
    src_ptr := rawptr(uintptr(surf.pixels) + uintptr(byte_offset))

    // By passing surf.pitch, SDL knows how to step to the next row in memory
    // even though we are pointing to the middle of the array.
    sdl.UpdateTexture(img.texture, &dst_rect, src_ptr, surf.pitch)

    return 0
}

// - FFI Utils

// lua_graphics_pixelmap_get_cptr implements: graphics.pixelmap_get_cptr(pmap) -> lightuserdata
lua_graphics_pixelmap_get_cptr :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil {
        lua.pushnil(L)
        return 1
    }

    // Push as lightuserdata (raw C pointer)
    lua.pushlightuserdata(L, pmap.surface.pixels)
    return 1
}

// lua_graphics_pixelmap_clone implements: graphics.pixelmap_clone(pmap) -> new_pmap | nil, err
lua_graphics_pixelmap_clone :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if pmap == nil || pmap.surface == nil {
        lua.pushnil(L)
        lua.pushstring(L, "graphics.pixelmap_clone: source pixelmap has been freed")
        return 2
    }

    clone_surf := sdl.DuplicateSurface(pmap.surface)
    if clone_surf == nil {
        lua.pushnil(L)

        err := sdl.GetError()
        if err != nil {
            lua.pushfstring(L,"graphics.pixelmap_clone: failed to duplicate pixelmap surface: %s", err,)
        } else {
            lua.pushstring(L, "graphics.pixelmap_clone: failed to duplicate pixelmap surface")
        }
        return 2
    }

    new_pmap := cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap))
    new_pmap^ = Pixelmap { surface = clone_surf }

    lua.L_getmetatable(L, "Pixelmap")
    lua.setmetatable(L, -2)

    return 1
}


// ============================================================================
// Memory Management And Metatables
// ============================================================================
// This section bridges Lua's Garbage Collector with Odin's manual memory management.
// Each userdata type has a specific `__gc` metamethod to safely free C-allocated RAM/VRAM
// when the Lua object falls out of scope. Null-checking the inner pointers (texture/surface)
// prevents double-free segfaults if a user manually calls free(userdata) before GC sweeps.

// lua_image_gc: Destroys the VRAM texture.
lua_image_gc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    img := cast(^Image)lua.L_checkudata(L, 1, "Image")

    if img != nil && img.texture != nil {
        sdl.DestroyTexture(img.texture)
        img.texture = nil
    }
    return 0
}

// lua_pixelmap_gc: Destroys the CPU-side SDL Surface.
lua_pixelmap_gc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    pmap := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")

    if pmap != nil && pmap.surface != nil {
        sdl.DestroySurface(pmap.surface)
        pmap.surface = nil
    }
    return 0
}

// setup_graphics_metatables: Initializes the hidden registry tables for all graphics userdata,
// linking Odin GC procedures to Lua objects to prevent memory leaks.
setup_graphics_metatables :: proc() {
    // 1. IMAGE METATABLE
    lua.L_newmetatable(Lua, "Image")
    lua.pushcfunction(Lua, lua_image_gc)
    lua.setfield(Lua, -2, "__gc")
    lua.pop(Lua, 1)

    // 3. PIXELMAP METATABLE
    lua.L_newmetatable(Lua, "Pixelmap")
    lua.pushcfunction(Lua, lua_pixelmap_gc)
    lua.setfield(Lua, -2, "__gc")
    lua.pop(Lua, 1)
}

// - Lua Registration

register_graphics_api :: proc() {
    setup_graphics_metatables()

    lua.newtable(Lua) // [graphics]

    // High-Level Drawing
    lua_bind_function(lua_graphics_draw_image, "draw_image")
    lua_bind_function(lua_graphics_draw_image_region, "draw_image_region")
    lua_bind_function(lua_graphics_draw_rect, "draw_rect")

    // VRAM Resource Management
    lua_bind_function(lua_graphics_load_image, "load_image")
    lua_bind_function(lua_graphics_get_image_size, "get_image_size")
    lua_bind_function(lua_graphics_set_default_filter, "set_default_filter")

    // Render Targets
    lua_bind_function(lua_graphics_new_canvas, "new_canvas")
    lua_bind_function(lua_graphics_set_canvas, "set_canvas")

    // Frame And Pipeline State
    lua_bind_function(lua_graphics_clear, "clear")
    lua_bind_function(lua_graphics_set_blend_mode, "set_blend_mode")
    lua_bind_function(lua_graphics_set_clip_rect, "set_clip_rect")
    lua_bind_function(lua_graphics_get_clip_rect, "get_clip_rect")

    // Transformations And Coordinate Spaces
    lua_bind_function(lua_graphics_begin_transform, "begin_transform")
    lua_bind_function(lua_graphics_end_transform, "end_transform")
    lua_bind_function(lua_graphics_set_translation, "set_translation")
    lua_bind_function(lua_graphics_set_rotation, "set_rotation")
    lua_bind_function(lua_graphics_set_scale, "set_scale")
    lua_bind_function(lua_graphics_set_origin, "set_origin")
    lua_bind_function(lua_graphics_use_screen_space, "use_screen_space")
    lua_bind_function(lua_graphics_screen_to_local, "screen_to_local")
    lua_bind_function(lua_graphics_local_to_screen, "local_to_screen")

    // Debug Drawing
    lua_bind_function(lua_graphics_debug_text, "debug_text")
    lua_bind_function(lua_graphics_debug_line, "debug_line")
    lua_bind_function(lua_graphics_debug_rect, "debug_rect")

    // Pixelmap Lifecycle And I/O
    lua_bind_function(lua_graphics_new_pixelmap, "new_pixelmap")
    lua_bind_function(lua_graphics_load_pixelmap, "load_pixelmap")
    lua_bind_function(lua_graphics_save_pixelmap, "save_pixelmap")
    lua_bind_function(lua_graphics_get_pixelmap_size, "get_pixelmap_size")

    // Pixelmap Software Rasterization
    lua_bind_function(lua_graphics_blit, "blit")
    lua_bind_function(lua_graphics_blit_region, "blit_region")
    lua_bind_function(lua_graphics_blit_rect, "blit_rect")
    lua_bind_function(lua_graphics_blit_line, "blit_line")
    lua_bind_function(lua_graphics_blit_triangle, "blit_triangle")
    lua_bind_function(lua_graphics_blit_circle, "blit_circle")
    lua_bind_function(lua_graphics_blit_circle_outline, "blit_circle_outline")
    lua_bind_function(lua_graphics_blit_circle_pixel_outline, "blit_circle_pixel_outline")
    lua_bind_function(lua_graphics_blit_capsule, "blit_capsule")

    // Pixelmap Atomic Ops And Analysis
    lua_bind_function(lua_graphics_pixelmap_set_pixel, "pixelmap_set_pixel")
    lua_bind_function(lua_graphics_pixelmap_get_pixel, "pixelmap_get_pixel")
    lua_bind_function(lua_graphics_pixelmap_flood_fill, "pixelmap_flood_fill")
    lua_bind_function(lua_graphics_pixelmap_raycast, "pixelmap_raycast")

    // Pixelmap VRAM Sync
    lua_bind_function(lua_graphics_new_image_from_pixelmap, "new_image_from_pixelmap")
    lua_bind_function(lua_graphics_update_image_from_pixelmap, "update_image_from_pixelmap")
    lua_bind_function(lua_graphics_update_image_region_from_pixelmap, "update_image_region_from_pixelmap")

    // Pixelmap FFI And Memory
    lua_bind_function(lua_graphics_pixelmap_clone, "pixelmap_clone")
    lua_bind_function(lua_graphics_pixelmap_get_cptr, "pixelmap_get_cptr")

    lua.setglobal(Lua, "graphics")
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
