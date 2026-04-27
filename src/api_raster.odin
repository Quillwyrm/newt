package main

import "base:runtime"
import "core:c"
import "core:math"
import "core:strings"
import lua "luajit"
import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

// ============================================================================
// Raster State
// ============================================================================

// Pixelmap is a CPU-side pixel buffer backed by an SDL surface.
Pixelmap :: ^sdl.Surface

PixelmapBlendMode :: enum {
    Replace,
    Blend,
    Add,
    Multiply,
    Erase,
    Mask,
}

// ============================================================================
// Host Helpers
// ============================================================================

// Helper to flip Lua's 0xRRGGBBAA to the physical 0xAABBGGRR memory layout.
u32_rgba_to_abgr :: #force_inline proc(c: u32) -> u32 {
    return (c >> 24) | ((c >> 8) & 0xFF00) | ((c << 8) & 0x00FF0000) | (c << 24)
}

lua_check_raster_blend_mode :: #force_inline proc(L: ^lua.State, mode_str: cstring, fn_name: cstring) -> PixelmapBlendMode {
    if mode_str == nil do return .Blend

    switch string(mode_str) {
        case "replace" : return .Replace
        case "blend"   : return .Blend
        case "add"     : return .Add
        case "multiply": return .Multiply
        case "erase"   : return .Erase
        case "mask"    : return .Mask
        case:
            lua.L_error(L, "raster.%s: unknown blend mode '%s'", fn_name, mode_str)
            return .Blend
    }
}

blend_memory_colors :: #force_inline proc(dst, src: u32, mode: PixelmapBlendMode) -> u32 {
    sa := (src >> 24) & 0xFF
    if sa == 0 && mode != .Replace && mode != .Mask do return dst

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
            nr = min(255, dr + (sr * sa) / 255)
            ng = min(255, dg + (sg * sa) / 255)
            nb = min(255, db + (sb * sa) / 255)
            na = min(255, da + sa)
        case .Multiply:
            nr = (dr * sr) / 255
            ng = (dg * sg) / 255
            nb = (db * sb) / 255
            na = da
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
get_clipped_bounds :: #force_inline proc(surf: ^sdl.Surface, min_x, min_y, max_x, max_y: f32) -> (start_x, start_y, end_x, end_y: int, valid: bool) {
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
// Lua Raster Bindings
// ============================================================================

// == Pixelmap I/O ==

// raster.new_pixelmap(w, h) -> Pixelmap
lua_raster_new_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    w := cast(c.int)lua.L_checkinteger(L, 1)
    h := cast(c.int)lua.L_checkinteger(L, 2)

    if w <= 0 || h <= 0 {
        lua.L_error(L, "raster.new_pixelmap: width and height must be positive")
        return 0
    }

    surface := sdl.CreateSurface(w, h, sdl.PixelFormat.RGBA32)
    if surface == nil {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "raster.new_pixelmap: failed to create pixelmap surface: %s", err)
        } else {
            lua.L_error(L, "raster.new_pixelmap: failed to create pixelmap surface")
        }
        return 0
    }

    sdl.FillSurfaceRect(surface, nil, 0x00000000)

    (cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap)))^ = surface

    lua.L_getmetatable(L, "Pixelmap")
    lua.setmetatable(L, -2)

    return 1
}

// raster.load_pixelmap(path) -> Pixelmap, width, height | nil, err
lua_raster_load_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    path := string(lua.L_checkstring(L, 1))
    resolved_path := resolve_resource_path(path)
    path_cstr := strings.clone_to_cstring(resolved_path, context.temp_allocator)

    w, h, channels: c.int
    pixels := stbi.load(path_cstr, &w, &h, &channels, 4)
    if pixels == nil {
        lua.pushnil(L)

        err := stbi.failure_reason()
        if err != nil {
            lua.pushfstring(L, "raster.load_pixelmap: failed to decode image: %s", err)
        } else {
            lua.pushstring(L, "raster.load_pixelmap: failed to decode image")
        }

        return 2
    }
    defer stbi.image_free(pixels)

    surface := sdl.CreateSurface(w, h, sdl.PixelFormat.RGBA32)
    if surface == nil {
        lua.pushnil(L)

        err := sdl.GetError()
        if err != nil {
            lua.pushfstring(L, "raster.load_pixelmap: failed to create pixelmap surface: %s", err)
        } else {
            lua.pushstring(L, "raster.load_pixelmap: failed to create pixelmap surface")
        }

        return 2
    }

    src_stride := int(w) * 4
    dst_stride := int(surface.pitch)

    for row in 0..<int(h) {
        src_row := rawptr(uintptr(pixels) + uintptr(row * src_stride))
        dst_row := rawptr(uintptr(surface.pixels) + uintptr(row * dst_stride))
        runtime.mem_copy(dst_row, src_row, src_stride)
    }

    (cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap)))^ = surface

    lua.L_getmetatable(L, "Pixelmap")
    lua.setmetatable(L, -2)

    lua.pushinteger(L, cast(lua.Integer)w)
    lua.pushinteger(L, cast(lua.Integer)h)

    return 3
}

// raster.get_pixelmap_size(pixelmap) -> width, height | nil, nil
lua_raster_get_pixelmap_size :: proc "c" (L: ^lua.State) -> c.int {
    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^

    if surf == nil {
        lua.pushnil(L)
        lua.pushnil(L)
        return 2
    }

    lua.pushinteger(L, cast(lua.Integer)surf.w)
    lua.pushinteger(L, cast(lua.Integer)surf.h)
    return 2
}

// raster.save_pixelmap(pixelmap, path) -> true | false, err
lua_raster_save_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^

    path := string(lua.L_checkstring(L, 2))
    resolved_path := resolve_resource_path(path)
    path_cstr := strings.clone_to_cstring(resolved_path, context.temp_allocator)

    if surf == nil {
        lua.L_error(L, "raster.save_pixelmap: pixelmap has been freed")
        return 0
    }

    res := stbi.write_png(path_cstr, surf.w, surf.h, 4, surf.pixels, surf.pitch)

    if res == 0 {
        lua.pushboolean(L, b32(false))
        lua.pushstring(L, "raster.save_pixelmap: failed to write PNG (check file path and permissions)")
        return 2
    }

    lua.pushboolean(L, b32(true))
    return 1
}

// == Pixelmap Bridges ==

// raster.new_pixelmap_from_datagrid(datagrid, color_map, default_color?) -> pixelmap
lua_raster_new_pixelmap_from_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        lua.L_error(L, "raster.new_pixelmap_from_datagrid: datagrid has been freed")
        return 0
    }

    lua.L_checktype(L, 2, lua.Type.TABLE)

    has_default := lua.type(L, 3) != lua.Type.NONE && lua.type(L, 3) != lua.Type.NIL
    default_color: u32
    if has_default {
        raw_default := i64(lua.L_checkinteger(L, 3))
        if raw_default < 0 || raw_default > i64(max(u32)) {
            lua.L_error(L, "raster.new_pixelmap_from_datagrid: default_color must be a color integer")
            return 0
        }
        default_color = u32(raw_default)
    }

    value_colors := make(map[i32]u32)
    defer delete(value_colors)

    lua.pushnil(L)
    for bool(lua.next(L, 2)) {
        if !bool(lua.isnumber(L, -2)) {
            lua.L_error(L, "raster.new_pixelmap_from_datagrid: color_map keys must be integers")
            return 0
        }

        if !bool(lua.isnumber(L, -1)) {
            lua.L_error(L, "raster.new_pixelmap_from_datagrid: color_map values must be color integers")
            return 0
        }

        raw_color := i64(lua.tointeger(L, -1))
        if raw_color < 0 || raw_color > i64(max(u32)) {
            lua.L_error(L, "raster.new_pixelmap_from_datagrid: color_map values must be color integers")
            return 0
        }

        value_colors[i32(lua.tointeger(L, -2))] = u32(raw_color)

        lua.pop(L, 1)
    }

    surface := sdl.CreateSurface(c.int(g.width), c.int(g.height), sdl.PixelFormat.RGBA32)
    if surface == nil {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "raster.new_pixelmap_from_datagrid: failed to create pixelmap surface: %s", err)
        } else {
            lua.L_error(L, "raster.new_pixelmap_from_datagrid: failed to create pixelmap surface")
        }
        return 0
    }

    pixels := cast([^]u32)surface.pixels
    stride := int(surface.pitch) / 4

    for y := 0; y < g.height; y += 1 {
        src_row := y * g.width
        dst_row := y * stride

        for x := 0; x < g.width; x += 1 {
            cell_value := g.cells[src_row + x]

            if logical_color, ok := value_colors[cell_value]; ok {
                pixels[dst_row + x] = u32_rgba_to_abgr(logical_color)
            } else if has_default {
                pixels[dst_row + x] = u32_rgba_to_abgr(default_color)
            } else {
                sdl.DestroySurface(surface)
                lua.L_error(
                    L,
                    "raster.new_pixelmap_from_datagrid: cell value %d has no mapped color",
                    cell_value,
                )
                return 0
            }
        }
    }

    (cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap)))^ = surface

    lua.L_getmetatable(L, "Pixelmap")
    lua.setmetatable(L, -2)

    return 1
}


// == Pixel Access And Analysis ==

// raster.set_pixel(pixelmap, x, y, color)
lua_raster_set_pixel :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil do return 0

    x := int(lua.L_checkinteger(L, 2))
    y := int(lua.L_checkinteger(L, 3))
    color_u32 := u32(lua.L_checkinteger(L, 4))

    if x < 0 || x >= int(surf.w) || y < 0 || y >= int(surf.h) do return 0

    pixels := cast([^]u32)surf.pixels
    stride := int(surf.pitch) / 4

    pixels[y * stride + x] = u32_rgba_to_abgr(color_u32)

    return 0
}

// raster.get_pixel(pixelmap, x, y) -> color | nil
lua_raster_get_pixel :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^

    if surf == nil {
        lua.pushnil(L)
        return 1
    }

    x := int(lua.L_checkinteger(L, 2))
    y := int(lua.L_checkinteger(L, 3))

    if x < 0 || x >= int(surf.w) || y < 0 || y >= int(surf.h) {
        lua.pushnil(L)
        return 1
    }

    pixels := cast([^]u32)surf.pixels
    stride := int(surf.pitch) / 4

    mem_color := pixels[y * stride + x]
    logical_color := u32_rgba_to_abgr(mem_color)

    lua.pushinteger(L, cast(lua.Integer)logical_color)
    return 1
}

// raster.flood_fill(pixelmap, x, y, color)
lua_raster_flood_fill :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil do return 0

    start_x := int(lua.L_checkinteger(L, 2))
    start_y := int(lua.L_checkinteger(L, 3))
    color_u32 := u32(lua.L_checkinteger(L, 4))

    width, height := int(surf.w), int(surf.h)
    if start_x < 0 || start_x >= width || start_y < 0 || start_y >= height do return 0

    pixels := cast([^]u32)surf.pixels
    stride := int(surf.pitch) / 4

    mem_fill_color := u32_rgba_to_abgr(color_u32)
    target_color := pixels[start_y * stride + start_x]

    // Nothing to fill.
    if target_color == mem_fill_color do return 0

    // Span-fill work stack.
    stack := make([dynamic][2]int, 0, 1024)
    defer delete(stack)

    append(&stack, [2]int{start_x, start_y})

    for len(stack) > 0 {
        pt := pop(&stack)
        cx, cy := pt.x, pt.y

        for cx > 0 && pixels[cy * stride + (cx - 1)] == target_color {
            cx -= 1
        }

        span_left := cx
        row_idx := cy * stride

        for cx < width && pixels[row_idx + cx] == target_color {
            pixels[row_idx + cx] = mem_fill_color
            cx += 1
        }

        span_right := cx - 1

        seed_rows := [2]int{cy - 1, cy + 1}
        for seed_y in seed_rows {
            if seed_y < 0 || seed_y >= height do continue

            in_span := false
            seed_row := seed_y * stride

            for x in span_left ..= span_right {
                if pixels[seed_row + x] == target_color {
                    if !in_span {
                        append(&stack, [2]int{x, seed_y})
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

// raster.raycast(pixelmap, x1, y1, x2, y2) -> true, x, y, color | false
lua_raster_raycast :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil {
        lua.pushboolean(L, false)
        return 1
    }

    x0 := int(lua.L_checkinteger(L, 2))
    y0 := int(lua.L_checkinteger(L, 3))
    x1 := int(lua.L_checkinteger(L, 4))
    y1 := int(lua.L_checkinteger(L, 5))

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

// == Pixelmap Geometry ==

// raster.blit_rect(pixelmap, x, y, w, h, color?, mode?)
lua_raster_blit_rect :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil do return 0

    x := int(lua.L_checkinteger(L, 2))
    y := int(lua.L_checkinteger(L, 3))
    w := int(lua.L_checkinteger(L, 4))
    h := int(lua.L_checkinteger(L, 5))
    color_u32 := u32(lua.L_optinteger(L, 6, -1))
    mode := lua_check_raster_blend_mode(L, lua.L_optstring(L, 7, "blend"), "blit_rect")

    if w <= 0 || h <= 0 do return 0

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

// raster.blit_triangle(pixelmap, x1, y1, x2, y2, x3, y3, color?, mode?)
lua_raster_blit_triangle :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil do return 0

    x1 := f32(lua.L_checknumber(L, 2))
    y1 := f32(lua.L_checknumber(L, 3))
    x2 := f32(lua.L_checknumber(L, 4))
    y2 := f32(lua.L_checknumber(L, 5))
    x3 := f32(lua.L_checknumber(L, 6))
    y3 := f32(lua.L_checknumber(L, 7))

    color_u32 := u32(lua.L_optinteger(L, 8, -1))
    mode := lua_check_raster_blend_mode(L, lua.L_optstring(L, 9, "blend"), "blit_triangle")

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

// raster.blit_line(pixelmap, x1, y1, x2, y2, color?, mode?)
lua_raster_blit_line :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil do return 0

    x0 := int(lua.L_checkinteger(L, 2))
    y0 := int(lua.L_checkinteger(L, 3))
    x1 := int(lua.L_checkinteger(L, 4))
    y1 := int(lua.L_checkinteger(L, 5))
    color_u32 := u32(lua.L_optinteger(L, 6, -1))
    mode := lua_check_raster_blend_mode(L, lua.L_optstring(L, 7, "blend"), "blit_line")

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

// raster.blit_circle(pixelmap, cx, cy, radius, color?, mode?)
lua_raster_blit_circle :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil do return 0

    cx := f32(lua.L_checknumber(L, 2))
    cy := f32(lua.L_checknumber(L, 3))
    r := f32(lua.L_checknumber(L, 4))
    color := u32(lua.L_optinteger(L, 5, -1))
    mode := lua_check_raster_blend_mode(L, lua.L_optstring(L, 6, "blend"), "blit_circle")
    if r < 0 do return 0

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

// raster.blit_ring(pixelmap, cx, cy, radius, thickness, color?, mode?)
lua_raster_blit_ring :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil do return 0

    cx := f32(lua.L_checknumber(L, 2))
    cy := f32(lua.L_checknumber(L, 3))
    r := f32(lua.L_checknumber(L, 4))
    thick := f32(lua.L_checknumber(L, 5))
    color := u32(lua.L_optinteger(L, 6, -1))
    mode := lua_check_raster_blend_mode(L, lua.L_optstring(L, 7, "blend"), "blit_ring")
    if r < 0 || thick <= 0 do return 0

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

// lua_raster_blit_circle_pixel_outline implements: raster.blit_circle_pixel_outline(pixelmap, cx, cy, radius, color?, mode?)
lua_raster_blit_circle_pixel_outline :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    
    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil do return 0

    cx := int(lua.L_checkinteger(L, 2))
    cy := int(lua.L_checkinteger(L, 3))
    radius := int(lua.L_checkinteger(L, 4))
    color_u32 := u32(lua.L_optinteger(L, 5, -1))
    mode := lua_check_raster_blend_mode(L, lua.L_optstring(L, 6, "blend"), "blit_circle_pixel_outline")

    if radius < 0 do return 0

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

// raster.blit_capsule(pixelmap, x1, y1, x2, y2, radius, color?, mode?)
lua_raster_blit_capsule :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil do return 0

    x1 := f32(lua.L_checknumber(L, 2))
    y1 := f32(lua.L_checknumber(L, 3))
    x2 := f32(lua.L_checknumber(L, 4))
    y2 := f32(lua.L_checknumber(L, 5))
    r := f32(lua.L_checknumber(L, 6))
    color_u32 := u32(lua.L_optinteger(L, 7, -1))
    mode := lua_check_raster_blend_mode(L, lua.L_optstring(L, 8, "blend"), "blit_capsule")
    if r < 0 do return 0

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

// == Pixelmap Blitting ==

// raster.blit(dst, src, dx, dy, mode?)
lua_raster_blit :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    dst_surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    src_surf := (cast(^Pixelmap)lua.L_checkudata(L, 2, "Pixelmap"))^

    if dst_surf == nil || src_surf == nil do return 0

    dest_x := int(lua.L_checkinteger(L, 3))
    dest_y := int(lua.L_checkinteger(L, 4))
    mode := lua_check_raster_blend_mode(L, lua.L_optstring(L, 5, "blend"), "blit")

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

// raster.blit_region(dst, src, sx, sy, w, h, dx, dy, mode?)
lua_raster_blit_region :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()
    
    dst_surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    src_surf := (cast(^Pixelmap)lua.L_checkudata(L, 2, "Pixelmap"))^

    if dst_surf == nil || src_surf == nil do return 0

    src_x := int(lua.L_checkinteger(L, 3))
    src_y := int(lua.L_checkinteger(L, 4))
    bw := int(lua.L_checkinteger(L, 5))
    bh := int(lua.L_checkinteger(L, 6))
    dst_x := int(lua.L_checkinteger(L, 7))
    dst_y := int(lua.L_checkinteger(L, 8))
    mode := lua_check_raster_blend_mode(L, lua.L_optstring(L, 9, "blend"), "blit_region")
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

// == Memory & FFI ==

// raster.get_pixelmap_cptr(pixelmap) -> lightuserdata | nil
lua_raster_get_pixelmap_cptr :: proc "c" (L: ^lua.State) -> c.int {
    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil {
        lua.pushnil(L)
        return 1
    }

    // Push as lightuserdata (raw C pointer)
    lua.pushlightuserdata(L, surf.pixels)
    return 1
}

// raster.clone_pixelmap(pixelmap) -> Pixelmap
lua_raster_clone_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil {
        lua.L_error(L, "raster.clone_pixelmap: source pixelmap has been freed")
        return 0
    }

    clone_surf := sdl.DuplicateSurface(surf)
    if clone_surf == nil {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "raster.clone_pixelmap: failed to duplicate pixelmap surface: %s", err)
        } else {
            lua.L_error(L, "raster.clone_pixelmap: failed to duplicate pixelmap surface")
        }
        return 0
    }

    (cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap)))^ = clone_surf

    lua.L_getmetatable(L, "Pixelmap")
    lua.setmetatable(L, -2)

    return 1
}

// ============================================================================
// Memory Management And Metatables
// ============================================================================

// lua_pixelmap_gc destroys the CPU-side SDL surface owned by a Pixelmap.
lua_pixelmap_gc :: proc "c" (L: ^lua.State) -> c.int {
    surface := cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap")
    if surface^ != nil {
        sdl.DestroySurface(surface^)
        surface^ = nil
    }
    return 0
}

setup_raster_metatables :: proc() {
    lua.L_newmetatable(Lua, "Pixelmap")
    lua.pushcfunction(Lua, lua_pixelmap_gc)
    lua.setfield(Lua, -2, "__gc")
    lua.pop(Lua, 1)
}

// == Lua Registration  ==

register_raster_api :: proc() {
    setup_raster_metatables()

    lua.newtable(Lua) // [raster]

    // Pixelmap Lifecycle And I/O
    lua_bind_function(lua_raster_new_pixelmap, "new_pixelmap")
    lua_bind_function(lua_raster_load_pixelmap, "load_pixelmap")
    lua_bind_function(lua_raster_save_pixelmap, "save_pixelmap")
    lua_bind_function(lua_raster_get_pixelmap_size, "get_pixelmap_size")

    // Pixelmap Bridges
    lua_bind_function(lua_raster_new_pixelmap_from_datagrid, "new_pixelmap_from_datagrid")

    // Software Drawing
    lua_bind_function(lua_raster_blit, "blit")
    lua_bind_function(lua_raster_blit_region, "blit_region")
    lua_bind_function(lua_raster_blit_rect, "blit_rect")
    lua_bind_function(lua_raster_blit_line, "blit_line")
    lua_bind_function(lua_raster_blit_triangle, "blit_triangle")
    lua_bind_function(lua_raster_blit_circle, "blit_circle")
    lua_bind_function(lua_raster_blit_ring, "blit_ring")
    lua_bind_function(lua_raster_blit_circle_pixel_outline, "blit_circle_pixel_outline")
    lua_bind_function(lua_raster_blit_capsule, "blit_capsule")

    // Pixel Access And Analysis
    lua_bind_function(lua_raster_set_pixel, "set_pixel")
    lua_bind_function(lua_raster_get_pixel, "get_pixel")
    lua_bind_function(lua_raster_flood_fill, "flood_fill")
    lua_bind_function(lua_raster_raycast, "raycast")

    // Memory
    lua_bind_function(lua_raster_clone_pixelmap, "clone_pixelmap")
    lua_bind_function(lua_raster_get_pixelmap_cptr, "get_pixelmap_cptr")

    lua.setglobal(Lua, "raster")
}