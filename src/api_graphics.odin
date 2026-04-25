package main

import "base:runtime"
import "core:c"
import "core:math"
import "core:strings"
import "core:math/linalg"
import lua "luajit"
import sdl "vendor:sdl3"
import "vendor:sdl3/ttf"
import stbi "vendor:stb/image"

BUILTIN_DEFAULT_FONT_SIZE :: f32(16)
FATAL_FONT_SIZE           :: f32(14)
BUILTIN_DEFAULT_FONT_BYTES :: #load("../res/iAWriterQuattroS-Regular.ttf")

// ============================================================================
// Graphics State
// ============================================================================

// == Types And Global Context ==

u32rgba :: distinct u32

// Image represents a hardware texture allocated in GPU VRAM.
Image :: struct {
    texture: ^sdl.Texture,
    width:   f32,
    height:  f32,
}

TextCacheEntry :: struct {
    texture: ^sdl.Texture,
    width:   f32,
    height:  f32,
}

WrapTextKey :: struct {
    text:  string,
    width: c.int,
    align: ttf.HorizontalAlignment,
}

Font :: struct {
    handle:     ^ttf.Font,
    size:       f32,
    text_cache: map[string]TextCacheEntry,
    wrap_cache: map[WrapTextKey]TextCacheEntry,
}

// == global graphics context

Gfx_Ctx: struct {
    active_sdl_color:  u32rgba,
    default_scale_mode: sdl.ScaleMode,
    active_blend_mode: sdl.BlendMode,
    active_text_alignment: ttf.HorizontalAlignment,

    active_font: ^Font,
    default_font: Font,

    transform: struct {
        matrix_stack: [32]matrix[3, 3]f32,
        group_depth:  int,
    },
}

// ============================================================================
// Graphics System Helpers
// ============================================================================

// == Graphics System Helpers ==

check_render_safety :: proc "contextless"(L: ^lua.State, fn_name: cstring) {
    if Renderer == nil {
        lua.L_error(L, "%s: graphics system not initialized yet", fn_name)
    }
}

// CPU state only. Safe to call at boot.
init_graphics_state :: proc() {
    Gfx_Ctx.active_sdl_color = u32rgba(0xFFFFFFFF)
    Gfx_Ctx.default_scale_mode = .LINEAR
    Gfx_Ctx.active_blend_mode = sdl.BLENDMODE_BLEND
    Gfx_Ctx.active_font = nil
    Gfx_Ctx.default_font = {}
    Gfx_Ctx.active_text_alignment = ttf.HorizontalAlignment.LEFT

    // '1' is the Odin literal for an Identity Matrix
    Gfx_Ctx.transform.matrix_stack[0] = 1
    Gfx_Ctx.transform.group_depth = 0
}

graphics_shutdown :: proc() {
    font := &Gfx_Ctx.default_font

    if font.text_cache != nil {
        for key, entry in font.text_cache {
            if entry.texture != nil {
                sdl.DestroyTexture(entry.texture)
            }
            delete(key)
        }
        delete(font.text_cache)
        font.text_cache = nil
    }

    if font.wrap_cache != nil {
        for key, entry in font.wrap_cache {
            if entry.texture != nil {
                sdl.DestroyTexture(entry.texture)
            }
            delete(key.text)
        }
        delete(font.wrap_cache)
        font.wrap_cache = nil
    }

    if font.handle != nil {
        ttf.CloseFont(font.handle)
        font.handle = nil
    }

    Gfx_Ctx.default_font = {}
    Gfx_Ctx.active_font = nil
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
    if Gfx_Ctx.active_sdl_color != c {
        r := u8((u32(c) >> 24) & 0xFF)
        g := u8((u32(c) >> 16) & 0xFF)
        b := u8((u32(c) >> 8) & 0xFF)
        a := u8(u32(c) & 0xFF)
        sdl.SetRenderDrawColor(Renderer, r, g, b, a)
        Gfx_Ctx.active_sdl_color = c
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

// == Render Geometry Helpers ==

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
        sdl.SetTextureBlendMode(tex, Gfx_Ctx.active_blend_mode)
    }

    sdl.RenderGeometry(Renderer, tex, raw_data(verts[:]), 4, raw_data(indices[:]), 6)
}

// == Font & Text Helpers

graphics_init_default_font :: proc() -> (cstring, bool) {
    if len(BUILTIN_DEFAULT_FONT_BYTES) == 0 {
        return "built-in default font bytes are empty", false
    }

    // NOTE:
    // I could verify TTF_OpenFontIO from your uploaded SDL_ttf binding.
    // I could not verify the exact SDL core binding symbol because that file was not in the upload.
    // This is very likely `sdl.IOFromConstMem`. If your compiler says otherwise,
    // grep your vendor:sdl3 binding for `IOFromConstMem` and swap the symbol name here.
    stream := sdl.IOFromConstMem(raw_data(BUILTIN_DEFAULT_FONT_BYTES),uint(len(BUILTIN_DEFAULT_FONT_BYTES)))
    if stream == nil {
        err := sdl.GetError()
        if err == nil do err = "SDL_IOFromConstMem failed"
        return err, false
    }

    handle := ttf.OpenFontIO(stream, true, BUILTIN_DEFAULT_FONT_SIZE)
    if handle == nil {
        err := sdl.GetError()
        if err == nil do err = "TTF_OpenFontIO failed"
        return err, false
    }

    Gfx_Ctx.default_font = Font{
        handle     = handle,
        size       = BUILTIN_DEFAULT_FONT_SIZE,
        text_cache = make(map[string]TextCacheEntry),
        wrap_cache = make(map[WrapTextKey]TextCacheEntry),
    }

    Gfx_Ctx.active_font = &Gfx_Ctx.default_font
    return nil, true
}

// Uploads a rasterized text surface into a cached texture entry.
load_text_texture_from_surface :: proc(surf: ^sdl.Surface) -> (TextCacheEntry, cstring, bool) {
    texture := sdl.CreateTextureFromSurface(Renderer, surf)
    if texture == nil {
        reason := sdl.GetError()
        if reason == nil do reason = "failed to create texture from text surface"
        return {}, reason, false
    }

    sdl.SetTextureBlendMode(texture, {.BLEND})
    sdl.SetTextureScaleMode(texture, Gfx_Ctx.default_scale_mode)

    return TextCacheEntry {
        texture = texture,
        width   = f32(surf.w),
        height  = f32(surf.h),
    }, nil, true
}

// Parses wrapped text alignment for graphics.draw_text_wrap.
parse_text_align_checked :: #force_inline proc(
    L: ^lua.State,
    align_str: cstring,
    fn_name: cstring,
) -> ttf.HorizontalAlignment {
    if align_str == nil do return .LEFT

    switch string(align_str) {
    case "left":
        return .LEFT
    case "center":
        return .CENTER
    case "right":
        return .RIGHT
    case:
        lua.L_error(L, "%s: unknown alignment '%s'", fn_name, align_str)
        return .LEFT
    }
}



// ============================================================================
// Lua Graphics Bindings
// ============================================================================

// == Image I/O ==

// graphics.load_image(path) -> image | nil, err
lua_graphics_load_image :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.load_image")

    if lua.gettop(L) != 1 {
        lua.L_error(L, "graphics.load_image: expected 1 argument: path")
        return 0
    }

    path := string(lua.L_checkstring(L, 1))
    resolved_path := resolve_resource_path(path)
    path_cstr := strings.clone_to_cstring(resolved_path, context.temp_allocator)

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

// == GPU Drawing ==

// graphics.draw_image(image, x, y, color?)
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

// graphics.draw_image_region(image, sx, sy, sw, sh, dx, dy, color?)
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

// graphics.draw_rect(x, y, w, h, color?)
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

// graphics.clear(color?)
// Clears the entire render target. Defaults to black.
lua_graphics_clear :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.clear")

    raw_color := lua.L_optinteger(L, 1, 0x000000FF)
    set_global_sdl_color(u32rgba(raw_color))
    sdl.RenderClear(Renderer)

    return 0
}

// == Debug Draws (no transform)

// graphics.debug_line(x1, y1, x2, y2, color?)
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

// graphics.debug_rect(x, y, w, h, color?)
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

// graphics.debug_text(x, y, text, color?)
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

// == Transform Pipeline ==


// graphics.begin_transform()
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

// graphics.end_transform()
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

// graphics.set_translation(x, y)
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

// graphics.set_rotation(radians)
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

// graphics.set_scale(sx, sy?)
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

// graphics.set_origin(ox, oy)
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

// == Draw Utilities ==

// graphics.set_default_filter(mode)
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

// graphics.get_image_size(image) -> width, height | nil, nil
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

// == Render State ==


// graphics.set_blend_mode(mode?)
lua_graphics_set_blend_mode :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.set_blend_mode")

    mode_str := lua.L_optstring(L, 1, "blend")
    mode := parse_gpu_blend_mode_checked(L, mode_str, "graphics.set_blend_mode")

    sdl.SetRenderDrawBlendMode(Renderer, mode)
    Gfx_Ctx.active_blend_mode = mode

    return 0
}

// graphics.set_clip_rect(x, y, w, h)
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


// graphics.get_clip_rect() -> x, y, w, h | nil, nil, nil, nil
// Returns the current hardware clip rectangle.
lua_graphics_get_clip_rect :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.get_clip_rect")

    rect: sdl.Rect
    enabled := sdl.GetRenderClipRect(Renderer, &rect)

    if !enabled {
        lua.pushnil(L)
        lua.pushnil(L)
        lua.pushnil(L)
        lua.pushnil(L)
        return 4
    }

    lua.pushinteger(L, cast(lua.Integer)rect.x)
    lua.pushinteger(L, cast(lua.Integer)rect.y)
    lua.pushinteger(L, cast(lua.Integer)rect.w)
    lua.pushinteger(L, cast(lua.Integer)rect.h)
    return 4
}

// graphics.new_canvas(w, h) -> Image
lua_graphics_new_canvas :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.new_canvas")

    w_i := int(lua.L_checkinteger(L, 1))
    h_i := int(lua.L_checkinteger(L, 2))

    if w_i <= 0 || h_i <= 0 {
        lua.L_error(L, "graphics.new_canvas: width and height must be positive integers")
        return 0
    }

    texture := sdl.CreateTexture(Renderer, .RGBA32, .TARGET, cast(c.int)w_i, cast(c.int)h_i)
    if texture == nil {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "graphics.new_canvas: failed to create canvas texture: %s", err)
        } else {
            lua.L_error(L, "graphics.new_canvas: failed to create canvas texture")
        }
        return 0
    }

    sdl.SetTextureBlendMode(texture, {.BLEND})
    sdl.SetTextureScaleMode(texture, Gfx_Ctx.default_scale_mode)

    data := cast(^Image)lua.newuserdata(L, size_of(Image))
    data^ = Image {
        texture = texture,
        width   = f32(w_i),
        height  = f32(h_i),
    }

    lua.L_getmetatable(L, "Image")
    lua.setmetatable(L, -2)

    return 1
}

// graphics.set_canvas(image?)
// noargs returns to window canvas
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

// == Text Drawing ==

// graphics.load_font(path, size) -> Font | nil, err
lua_graphics_load_font :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    path := string(lua.L_checkstring(L, 1))
    resolved_path := resolve_resource_path(path)
    path_c := strings.clone_to_cstring(resolved_path, context.temp_allocator)
    size := f32(lua.L_checknumber(L, 2))

    if size <= 0 {
        lua.pushnil(L)
        lua.pushstring(L, "graphics.load_font: size must be positive")
        return 2
    }

    handle := ttf.OpenFont(path_c, size)
    if handle == nil {
        lua.pushnil(L)

        err := sdl.GetError()
        if err != nil {
            lua.pushfstring(L, "graphics.load_font: failed to open font: %s", err)
        } else {
            lua.pushstring(L, "graphics.load_font: failed to open font")
        }
        return 2
    }

    font := cast(^Font)lua.newuserdata(L, size_of(Font))
    font^ = Font {
        handle     = handle,
        size       = size,
        text_cache = make(map[string]TextCacheEntry),
        wrap_cache = make(map[WrapTextKey]TextCacheEntry),
    }

    lua.L_getmetatable(L, "Font")
    lua.setmetatable(L, -2)

    return 1
}

// graphics.set_font(font)
lua_graphics_set_font :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)

    if argc == 0 {
        Gfx_Ctx.active_font = &Gfx_Ctx.default_font
        return 0
    }

    if argc != 1 {
        lua.L_error(L, "graphics.set_font: expected 0 or 1 arguments")
        return 0
    }

    if lua.isnil(L, 1) {
        Gfx_Ctx.active_font = &Gfx_Ctx.default_font
        return 0
    }

    font := cast(^Font)lua.L_testudata(L, 1, "Font")
    if font == nil {
        lua.L_error(L, "graphics.set_font: expected Font or nil")
        return 0
    }

    if font.handle == nil {
        Gfx_Ctx.active_font = &Gfx_Ctx.default_font
        return 0
    }

    Gfx_Ctx.active_font = font
    return 0
}

// graphics.draw_text(text, x, y, color?)
lua_graphics_draw_text :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.draw_text")

    font := Gfx_Ctx.active_font
    if font == nil || font.handle == nil {
        panic("graphics.draw_text: active font invariant broken")
    }

    text_len: c.size_t
    text_c := lua.L_checklstring(L, 1, &text_len)

    x := f32(lua.L_checknumber(L, 2))
    y := f32(lua.L_checknumber(L, 3))
    raw_color := lua.L_optinteger(L, 4, 0xFFFFFFFF)

    if text_len == 0 do return 0

    probe_key := strings.string_from_ptr(cast(^u8)text_c, int(text_len))

    entry, ok := font.text_cache[probe_key]
    if !ok {
        owned_key, err := strings.clone_from_ptr(cast(^u8)text_c, int(text_len))
        if err != nil {
            lua.L_error(L, "graphics.draw_text: failed to allocate cache key")
            return 0
        }

        // draw_text is newline-aware, but not width-wrapped, so always force left alignment.
        ttf.SetFontWrapAlignment(font.handle, .LEFT)

        surf := ttf.RenderText_Blended_Wrapped(font.handle, text_c, text_len, sdl.Color{255, 255, 255, 255}, 0)
        if surf == nil {
            delete(owned_key)

            err_msg := sdl.GetError()
            if err_msg != nil {
                lua.L_error(L, "graphics.draw_text: failed to rasterize text: %s", err_msg)
            } else {
                lua.L_error(L, "graphics.draw_text: failed to rasterize text")
            }
            return 0
        }
        defer sdl.DestroySurface(surf)

        new_entry, surf_err, ok2 := load_text_texture_from_surface(surf)
        if !ok2 {
            delete(owned_key)

            if surf_err != nil {
                lua.L_error(L, "graphics.draw_text: %s", surf_err)
            } else {
                lua.L_error(L, "graphics.draw_text: failed to create texture from text surface")
            }
            return 0
        }

        font.text_cache[owned_key] = new_entry
        entry = new_entry
    }

    world_m := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]
    draw_geometry(entry.texture, x, y, entry.width, entry.height, 0.0, 0.0, 1.0, 1.0, u32rgba(raw_color), world_m)

    return 0
}

// graphics.draw_text_wrap(text, x, y, width, color?)
lua_graphics_draw_text_wrap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.draw_text_wrap")

    font := Gfx_Ctx.active_font
    if font == nil || font.handle == nil {
        panic("graphics.draw_text_wrap: active font invariant broken")
    }

    argc := lua.gettop(L)
    if argc < 4 || argc > 5 {
        lua.L_error(L, "graphics.draw_text_wrap: expected 4 or 5 arguments: text, x, y, width, color?")
        return 0
    }

    text_len: c.size_t
    text_c := lua.L_checklstring(L, 1, &text_len)

    x := f32(lua.L_checknumber(L, 2))
    y := f32(lua.L_checknumber(L, 3))
    wrap_width := cast(c.int)lua.L_checkinteger(L, 4)

    if wrap_width <= 0 {
        lua.L_error(L, "graphics.draw_text_wrap: width must be positive")
        return 0
    }

    if text_len == 0 do return 0

    align := Gfx_Ctx.active_text_alignment
    raw_color := lua.Integer(0xFFFFFFFF)

    if argc == 5 {
        raw_color = lua.L_checkinteger(L, 5)
    }

    probe_key := WrapTextKey{
        text  = strings.string_from_ptr(cast(^u8)text_c, int(text_len)),
        width = wrap_width,
        align = align,
    }

    entry, ok := font.wrap_cache[probe_key]
    if !ok {
        owned_text, err := strings.clone_from_ptr(cast(^u8)text_c, int(text_len))
        if err != nil {
            lua.L_error(L, "graphics.draw_text_wrap: failed to allocate cache key")
            return 0
        }

        owned_key := WrapTextKey{
            text  = owned_text,
            width = wrap_width,
            align = align,
        }

        ttf.SetFontWrapAlignment(font.handle, align)

        surf := ttf.RenderText_Blended_Wrapped(font.handle, text_c, text_len, sdl.Color{255, 255, 255, 255}, wrap_width)
        if surf == nil {
            delete(owned_key.text)

            err_msg := sdl.GetError()
            if err_msg != nil {
                lua.L_error(L, "graphics.draw_text_wrap: failed to rasterize text: %s", err_msg)
            } else {
                lua.L_error(L, "graphics.draw_text_wrap: failed to rasterize text")
            }
            return 0
        }
        defer sdl.DestroySurface(surf)

        new_entry, surf_err, ok2 := load_text_texture_from_surface(surf)
        if !ok2 {
            delete(owned_key.text)

            if surf_err != nil {
                lua.L_error(L, "graphics.draw_text_wrap: %s", surf_err)
            } else {
                lua.L_error(L, "graphics.draw_text_wrap: failed to create texture from text surface")
            }
            return 0
        }

        font.wrap_cache[owned_key] = new_entry
        entry = new_entry
    }

    world_m := Gfx_Ctx.transform.matrix_stack[Gfx_Ctx.transform.group_depth]
    draw_geometry(entry.texture, x, y, entry.width, entry.height, 0.0, 0.0, 1.0, 1.0, u32rgba(raw_color), world_m)

    return 0
}

// graphics.set_text_alignment(mode)
lua_graphics_set_text_alignment :: proc "c" (L: ^lua.State) -> c.int {
    mode := string(lua.L_checkstring(L, 1))

    switch mode {
    case "left":
        Gfx_Ctx.active_text_alignment = .LEFT
    case "center":
        Gfx_Ctx.active_text_alignment = .CENTER
    case "right":
        Gfx_Ctx.active_text_alignment = .RIGHT
    case:
        lua.L_error(L, "graphics.set_text_alignment: expected 'left', 'center', or 'right'")
    }

    return 0
}

// == Text Querys ==

// graphics.get_font_height(font?) -> height | nil
lua_graphics_get_font_height :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)
    font := &Gfx_Ctx.default_font

    if argc > 1 {
        lua.L_error(L, "graphics.get_font_height: expected 0 or 1 arguments")
        return 0
    }

    if argc == 1 && !lua.isnil(L, 1) {
        explicit_font := cast(^Font)lua.L_testudata(L, 1, "Font")
        if explicit_font == nil {
            lua.L_error(L, "graphics.get_font_height: expected Font or nil")
            return 0
        }

        if explicit_font.handle == nil {
            lua.pushnil(L)
            return 1
        }

        font = explicit_font
    }

    height := ttf.GetFontHeight(font.handle)
    lua.pushinteger(L, cast(lua.Integer)height)
    return 1
}

// graphics.get_font_ascent(font?) -> ascent | nil
lua_graphics_get_font_ascent :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)
    font := &Gfx_Ctx.default_font

    if argc > 1 {
        lua.L_error(L, "graphics.get_font_ascent: expected 0 or 1 arguments")
        return 0
    }

    if argc == 1 && !lua.isnil(L, 1) {
        explicit_font := cast(^Font)lua.L_testudata(L, 1, "Font")
        if explicit_font == nil {
            lua.L_error(L, "graphics.get_font_ascent: expected Font or nil")
            return 0
        }

        if explicit_font.handle == nil {
            lua.pushnil(L)
            return 1
        }

        font = explicit_font
    }

    ascent := ttf.GetFontAscent(font.handle)
    lua.pushinteger(L, cast(lua.Integer)ascent)
    return 1
}

// graphics.get_font_descent(font?) -> descent | nil
lua_graphics_get_font_descent :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)
    font := &Gfx_Ctx.default_font

    if argc > 1 {
        lua.L_error(L, "graphics.get_font_descent: expected 0 or 1 arguments")
        return 0
    }

    if argc == 1 && !lua.isnil(L, 1) {
        explicit_font := cast(^Font)lua.L_testudata(L, 1, "Font")
        if explicit_font == nil {
            lua.L_error(L, "graphics.get_font_descent: expected Font or nil")
            return 0
        }

        if explicit_font.handle == nil {
            lua.pushnil(L)
            return 1
        }

        font = explicit_font
    }

    descent := ttf.GetFontDescent(font.handle)
    lua.pushinteger(L, cast(lua.Integer)descent)
    return 1
}

// graphics.get_font_line_skip(font?) -> line_skip | nil
lua_graphics_get_font_line_skip :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)
    font := &Gfx_Ctx.default_font

    if argc > 1 {
        lua.L_error(L, "graphics.get_font_line_skip: expected 0 or 1 arguments")
        return 0
    }

    if argc == 1 && !lua.isnil(L, 1) {
        explicit_font := cast(^Font)lua.L_testudata(L, 1, "Font")
        if explicit_font == nil {
            lua.L_error(L, "graphics.get_font_line_skip: expected Font or nil")
            return 0
        }

        if explicit_font.handle == nil {
            lua.pushnil(L)
            return 1
        }

        font = explicit_font
    }

    line_skip := ttf.GetFontLineSkip(font.handle)
    lua.pushinteger(L, cast(lua.Integer)line_skip)
    return 1
}

// graphics.measure_text(text, font?) -> width, height | nil, nil
lua_graphics_measure_text :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)
    font := &Gfx_Ctx.default_font

    text_len: c.size_t
    text_c: cstring

    if argc == 1 {
        text_c = lua.L_checklstring(L, 1, &text_len)

    } else if argc == 2 {
        text_c = lua.L_checklstring(L, 1, &text_len)

        if !lua.isnil(L, 2) {
            explicit_font := cast(^Font)lua.L_testudata(L, 2, "Font")
            if explicit_font == nil {
                lua.L_error(L, "graphics.measure_text: expected text, Font?")
                return 0
            }

            if explicit_font.handle == nil {
                lua.pushnil(L)
                lua.pushnil(L)
                return 2
            }

            font = explicit_font
        }

    } else {
        lua.L_error(L, "graphics.measure_text: expected 1 or 2 arguments: text, font?")
        return 0
    }

    w, h: c.int
    if !ttf.GetStringSizeWrapped(font.handle, text_c, text_len, 0, &w, &h) {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "graphics.measure_text: failed to measure text: %s", err)
        } else {
            lua.L_error(L, "graphics.measure_text: failed to measure text")
        }
        return 0
    }

    lua.pushinteger(L, cast(lua.Integer)w)
    lua.pushinteger(L, cast(lua.Integer)h)
    return 2
}

// graphics.measure_text_wrap(text, width, font?) -> width, height | nil, nil
lua_graphics_measure_text_wrap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)
    font := &Gfx_Ctx.default_font

    text_len: c.size_t
    text_c: cstring
    wrap_width: c.int

    if argc == 2 {
        text_c = lua.L_checklstring(L, 1, &text_len)
        wrap_width = cast(c.int)lua.L_checkinteger(L, 2)

    } else if argc == 3 {
        text_c = lua.L_checklstring(L, 1, &text_len)
        wrap_width = cast(c.int)lua.L_checkinteger(L, 2)

        if !lua.isnil(L, 3) {
            explicit_font := cast(^Font)lua.L_testudata(L, 3, "Font")
            if explicit_font == nil {
                lua.L_error(L, "graphics.measure_text_wrap: expected text, width, Font?")
                return 0
            }

            if explicit_font.handle == nil {
                lua.pushnil(L)
                lua.pushnil(L)
                return 2
            }

            font = explicit_font
        }

    } else {
        lua.L_error(L, "graphics.measure_text_wrap: expected 2 or 3 arguments: text, width, font?")
        return 0
    }

    if wrap_width <= 0 {
        lua.L_error(L, "graphics.measure_text_wrap: width must be positive")
        return 0
    }

    w, h: c.int
    if !ttf.GetStringSizeWrapped(font.handle, text_c, text_len, wrap_width, &w, &h) {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "graphics.measure_text_wrap: failed to measure wrapped text: %s", err)
        } else {
            lua.L_error(L, "graphics.measure_text_wrap: failed to measure wrapped text")
        }
        return 0
    }

    lua.pushinteger(L, cast(lua.Integer)w)
    lua.pushinteger(L, cast(lua.Integer)h)
    return 2
}

// graphics.measure_text_fit(text, width, font?) -> fit_width, fit_length | nil, nil
lua_graphics_measure_text_fit :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)
    font := &Gfx_Ctx.default_font

    text_len: c.size_t
    text_c: cstring
    max_width: c.int

    if argc == 2 {
        text_c = lua.L_checklstring(L, 1, &text_len)
        max_width = cast(c.int)lua.L_checkinteger(L, 2)

    } else if argc == 3 {
        text_c = lua.L_checklstring(L, 1, &text_len)
        max_width = cast(c.int)lua.L_checkinteger(L, 2)

        if !lua.isnil(L, 3) {
            explicit_font := cast(^Font)lua.L_testudata(L, 3, "Font")
            if explicit_font == nil {
                lua.L_error(L, "graphics.measure_text_fit: expected text, width, Font?")
                return 0
            }

            if explicit_font.handle == nil {
                lua.pushnil(L)
                lua.pushnil(L)
                return 2
            }

            font = explicit_font
        }

    } else {
        lua.L_error(L, "graphics.measure_text_fit: expected 2 or 3 arguments: text, width, font?")
        return 0
    }

    if max_width < 0 {
        lua.L_error(L, "graphics.measure_text_fit: width must be non-negative")
        return 0
    }

    measured_width: c.int
    measured_length: c.size_t
    if !ttf.MeasureString(font.handle, text_c, text_len, max_width, &measured_width, &measured_length) {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "graphics.measure_text_fit: failed to measure text fit: %s", err)
        } else {
            lua.L_error(L, "graphics.measure_text_fit: failed to measure text fit")
        }
        return 0
    }

    lua.pushinteger(L, cast(lua.Integer)measured_width)
    lua.pushinteger(L, cast(lua.Integer)measured_length)
    return 2
}

// graphics.font_has_glyph(codepoint, font?) -> bool | nil
lua_graphics_font_has_glyph :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)
    font := &Gfx_Ctx.default_font

    codepoint: u32

    if argc == 1 {
        codepoint = cast(u32)lua.L_checkinteger(L, 1)

    } else if argc == 2 {
        codepoint = cast(u32)lua.L_checkinteger(L, 1)

        if !lua.isnil(L, 2) {
            explicit_font := cast(^Font)lua.L_testudata(L, 2, "Font")
            if explicit_font == nil {
                lua.L_error(L, "graphics.font_has_glyph: expected codepoint, Font?")
                return 0
            }

            if explicit_font.handle == nil {
                lua.pushnil(L)
                return 1
            }

            font = explicit_font
        }

    } else {
        lua.L_error(L, "graphics.font_has_glyph: expected 1 or 2 arguments: codepoint, font?")
        return 0
    }

    has_glyph := ttf.FontHasGlyph(font.handle, codepoint)
    lua.pushboolean(L, b32(has_glyph))
    return 1
}

// graphics.get_glyph_metrics(codepoint, font?) -> minx, maxx, miny, maxy, advance | nil, nil, nil, nil, nil
lua_graphics_get_glyph_metrics :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    argc := lua.gettop(L)
    font := &Gfx_Ctx.default_font

    codepoint: u32

    if argc == 1 {
        codepoint = cast(u32)lua.L_checkinteger(L, 1)

    } else if argc == 2 {
        codepoint = cast(u32)lua.L_checkinteger(L, 1)

        if !lua.isnil(L, 2) {
            explicit_font := cast(^Font)lua.L_testudata(L, 2, "Font")
            if explicit_font == nil {
                lua.L_error(L, "graphics.get_glyph_metrics: expected codepoint, Font?")
                return 0
            }

            if explicit_font.handle == nil {
                lua.pushnil(L)
                lua.pushnil(L)
                lua.pushnil(L)
                lua.pushnil(L)
                lua.pushnil(L)
                return 5
            }

            font = explicit_font
        }

    } else {
        lua.L_error(L, "graphics.get_glyph_metrics: expected 1 or 2 arguments: codepoint, font?")
        return 0
    }

    minx, maxx, miny, maxy, advance: c.int
    if !ttf.GetGlyphMetrics(font.handle, codepoint, &minx, &maxx, &miny, &maxy, &advance) {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "graphics.get_glyph_metrics: failed to query glyph metrics: %s", err)
        } else {
            lua.L_error(L, "graphics.get_glyph_metrics: failed to query glyph metrics")
        }
        return 0
    }

    lua.pushinteger(L, cast(lua.Integer)minx)
    lua.pushinteger(L, cast(lua.Integer)maxx)
    lua.pushinteger(L, cast(lua.Integer)miny)
    lua.pushinteger(L, cast(lua.Integer)maxy)
    lua.pushinteger(L, cast(lua.Integer)advance)
    return 5
}

// == Images From Pixelmaps ==

// graphics.new_image_from_pixelmap(pixelmap) -> image
lua_graphics_new_image_from_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.new_image_from_pixelmap")

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil {
        lua.L_error(L, "graphics.new_image_from_pixelmap: source pixelmap has been freed")
        return 0
    }

    texture := sdl.CreateTextureFromSurface(Renderer, surf)
    if texture == nil {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "graphics.new_image_from_pixelmap: failed to create texture from pixelmap: %s", err)
        } else {
            lua.L_error(L, "graphics.new_image_from_pixelmap: failed to create texture from pixelmap")
        }
        return 0
    }

    sdl.SetTextureBlendMode(texture, {.BLEND})
    sdl.SetTextureScaleMode(texture, Gfx_Ctx.default_scale_mode)

    img := cast(^Image)lua.newuserdata(L, size_of(Image))
    img^ = Image{texture = texture, width = f32(surf.w), height = f32(surf.h)}

    lua.L_getmetatable(L, "Image")
    lua.setmetatable(L, -2)

    return 1
}

// graphics.update_image_from_pixelmap(image, pixelmap, dx?, dy?)
lua_graphics_update_image_from_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.update_image_from_pixelmap")

    img := cast(^Image)lua.L_checkudata(L, 1, "Image")
    surf := (cast(^Pixelmap)lua.L_checkudata(L, 2, "Pixelmap"))^
    if img.texture == nil || surf == nil do return 0

    dx := c.int(lua.L_optinteger(L, 3, 0))
    dy := c.int(lua.L_optinteger(L, 4, 0))

    dst_rect := sdl.Rect{dx, dy, surf.w, surf.h}

    sdl.UpdateTexture(img.texture, &dst_rect, surf.pixels, surf.pitch)

    return 0
}

// graphics.update_image_region_from_pixelmap(image, pixelmap, sx, sy, w, h, dx, dy)
lua_graphics_update_image_region_from_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    check_render_safety(L, "graphics.update_image_region_from_pixelmap")

    img := cast(^Image)lua.L_checkudata(L, 1, "Image")
    surf := (cast(^Pixelmap)lua.L_checkudata(L, 2, "Pixelmap"))^
    if img.texture == nil || surf == nil do return 0

    sx := c.int(lua.L_checkinteger(L, 3))
    sy := c.int(lua.L_checkinteger(L, 4))
    w  := c.int(lua.L_checkinteger(L, 5))
    h  := c.int(lua.L_checkinteger(L, 6))
    dx := c.int(lua.L_checkinteger(L, 7))
    dy := c.int(lua.L_checkinteger(L, 8))

    if w <= 0 || h <= 0 || sx < 0 || sy < 0 || sx + w > surf.w || sy + h > surf.h { return 0 }

    dst_rect := sdl.Rect{dx, dy, w, h}

    byte_offset := (int(sy) * int(surf.pitch)) + (int(sx) * 4)
    src_ptr := rawptr(uintptr(surf.pixels) + uintptr(byte_offset))

    sdl.UpdateTexture(img.texture, &dst_rect, src_ptr, surf.pitch)

    return 0
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



//lua_font_gc: frees a Lua-owned font and repairs active font state if that freed font was currently selected.
lua_font_gc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    font := cast(^Font)lua.L_checkudata(L, 1, "Font")

    if font == nil {
        return 0
    }

    if font.text_cache != nil {
        for key, entry in font.text_cache {
            if entry.texture != nil {
                sdl.DestroyTexture(entry.texture)
            }
            delete(key)
        }
        delete(font.text_cache)
        font.text_cache = nil
    }

    if font.wrap_cache != nil {
        for key, entry in font.wrap_cache {
            if entry.texture != nil {
                sdl.DestroyTexture(entry.texture)
            }
            delete(key.text)
        }
        delete(font.wrap_cache)
        font.wrap_cache = nil
    }

    if font.handle != nil {
        ttf.CloseFont(font.handle)
        font.handle = nil
    }

    if Gfx_Ctx.active_font == font {
        Gfx_Ctx.active_font = &Gfx_Ctx.default_font
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

    // FONT METATABLE
    lua.L_newmetatable(Lua, "Font")
    lua.pushcfunction(Lua, lua_font_gc)
    lua.setfield(Lua, -2, "__gc")
    lua.pop(Lua, 1)
}

// == Lua Registration  ==

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

    // Text / Fonts
    lua_bind_function(lua_graphics_load_font, "load_font")
    lua_bind_function(lua_graphics_set_font, "set_font")
    lua_bind_function(lua_graphics_draw_text, "draw_text")
    lua_bind_function(lua_graphics_draw_text_wrap, "draw_text_wrap")
    lua_bind_function(lua_graphics_set_text_alignment, "set_text_alignment")

    // Text Query
    lua_bind_function(lua_graphics_get_font_height, "get_font_height")
    lua_bind_function(lua_graphics_get_font_ascent, "get_font_ascent")
    lua_bind_function(lua_graphics_get_font_descent, "get_font_descent")
    lua_bind_function(lua_graphics_get_font_line_skip, "get_font_line_skip")
    lua_bind_function(lua_graphics_measure_text, "measure_text")
    lua_bind_function(lua_graphics_measure_text_wrap, "measure_text_wrap")
    lua_bind_function(lua_graphics_measure_text_fit, "measure_text_fit")
    lua_bind_function(lua_graphics_font_has_glyph, "font_has_glyph")
    lua_bind_function(lua_graphics_get_glyph_metrics, "get_glyph_metrics")

    // Pixelmap VRAM Sync
    lua_bind_function(lua_graphics_new_image_from_pixelmap, "new_image_from_pixelmap")
    lua_bind_function(lua_graphics_update_image_from_pixelmap, "update_image_from_pixelmap")
    lua_bind_function(lua_graphics_update_image_region_from_pixelmap, "update_image_region_from_pixelmap")


    lua.setglobal(Lua, "graphics")
}