package main

import "base:runtime"
import "core:c"
import rand "core:math/rand"
import noise "core:math/noise"
import lua "luajit"
import sdl "vendor:sdl3"


// ============================================================================
// Random State
// ============================================================================

Rng :: rand.Xoshiro256_Random_State
MAX_RNGS :: 16

rngs: [MAX_RNGS]Rng
rng_count := 1
active_rng: int

// ============================================================================
// Lua Argument Checks
// ============================================================================

lua_check_seed :: proc(L: ^lua.State, arg_idx: c.int, fn_name: cstring) -> u64 {
    seed := i64(lua.L_checkinteger(L, arg_idx))
    if seed < 0 {
        lua.L_error(L, "random.%s: seed must be >= 0", fn_name)
        return 0
    }
    return u64(seed)
}

lua_check_rng_handle :: proc(L: ^lua.State, arg_idx: c.int, fn_name: cstring) -> int {
    handle := int(lua.L_checkinteger(L, arg_idx))

    if handle < 0 || handle >= rng_count {
        lua.L_error(L, "random.%s: invalid generator handle", fn_name)
        return 0
    }
    return handle
}

// ============================================================================
// Noise Helpers
// ============================================================================

Noise_Opts :: struct {
    frequency:  f64,
    octaves:    int,
    lacunarity: f64,
    gain:       f64,
}

lua_check_noise_opts :: proc(L: ^lua.State, arg_idx: c.int, fn_name: cstring) -> Noise_Opts {
    opts := Noise_Opts{
        frequency  = 1.0,
        octaves    = 1,
        lacunarity = 2.0,
        gain       = 0.5,
    }

    idx := lua.Index(arg_idx)

    if bool(lua.isnoneornil(L, idx)) {
        return opts
    }

    lua.L_checktype(L, arg_idx, lua.Type.TABLE)

    lua.getfield(L, idx, "frequency")
    if !bool(lua.isnoneornil(L, -1)) {
        opts.frequency = f64(lua.L_checknumber(L, -1))
    }
    lua.pop(L, 1)

    lua.getfield(L, idx, "octaves")
    if !bool(lua.isnoneornil(L, -1)) {
        opts.octaves = int(lua.L_checkinteger(L, -1))
    }
    lua.pop(L, 1)

    lua.getfield(L, idx, "lacunarity")
    if !bool(lua.isnoneornil(L, -1)) {
        opts.lacunarity = f64(lua.L_checknumber(L, -1))
    }
    lua.pop(L, 1)

    lua.getfield(L, idx, "gain")
    if !bool(lua.isnoneornil(L, -1)) {
        opts.gain = f64(lua.L_checknumber(L, -1))
    }
    lua.pop(L, 1)

    if opts.frequency <= 0 {
        lua.L_error(L, "random.%s: frequency must be greater than zero", fn_name)
        return opts
    }

    if opts.octaves < 1 {
        lua.L_error(L, "random.%s: octaves must be >= 1", fn_name)
        return opts
    }

    if opts.lacunarity <= 0 {
        lua.L_error(L, "random.%s: lacunarity must be greater than zero", fn_name)
        return opts
    }

    if opts.gain < 0 {
        lua.L_error(L, "random.%s: gain must be non-negative", fn_name)
        return opts
    }

    return opts
}


sample_noise_2d :: proc(x, y: f64, seed: i64, opts: Noise_Opts) -> f64 {
    frequency := opts.frequency
    amplitude := 1.0

    value_sum: f64
    amplitude_sum: f64

    for octave := 0; octave < opts.octaves; octave += 1 {
        raw := f64(noise.noise_2d(seed, noise.Vec2{x * frequency, y * frequency}))

        value_sum += raw * amplitude
        amplitude_sum += amplitude

        frequency *= opts.lacunarity
        amplitude *= opts.gain
    }

    value := (value_sum / amplitude_sum) * 0.5 + 0.5

    if value < 0 do return 0
    if value > 1 do return 1
    return value
}

noise_lerp_color :: proc(low_color, high_color: u32, t: f64) -> u32 {
    lr := (low_color  >> 24) & 0xFF
    lg := (low_color  >> 16) & 0xFF
    lb := (low_color  >> 8)  & 0xFF
    la :=  low_color         & 0xFF

    hr := (high_color >> 24) & 0xFF
    hg := (high_color >> 16) & 0xFF
    hb := (high_color >> 8)  & 0xFF
    ha :=  high_color        & 0xFF

    r := u32(f64(lr) + (f64(hr) - f64(lr)) * t + 0.5)
    g := u32(f64(lg) + (f64(hg) - f64(lg)) * t + 0.5)
    b := u32(f64(lb) + (f64(hb) - f64(lb)) * t + 0.5)
    a := u32(f64(la) + (f64(ha) - f64(la)) * t + 0.5)

    return (r << 24) | (g << 16) | (b << 8) | a
}

noise_datagrid_range_from_opts :: proc(L: ^lua.State, arg_idx: c.int, fn_name: cstring) -> (min_value, max_value: i32) {
    min_value = 0
    max_value = 1

    idx := lua.Index(arg_idx)
    if bool(lua.isnoneornil(L, idx)) {
        return
    }

    lua.getfield(L, idx, "min")
    if !bool(lua.isnoneornil(L, -1)) {
        raw_min := i64(lua.L_checkinteger(L, -1))
        if raw_min < i64(min(i32)) || raw_min > i64(max(i32)) {
            lua.L_error(L, "random.%s: min must fit in a datagrid cell", fn_name)
            return
        }
        min_value = i32(raw_min)
    }
    lua.pop(L, 1)

    lua.getfield(L, idx, "max")
    if !bool(lua.isnoneornil(L, -1)) {
        raw_max := i64(lua.L_checkinteger(L, -1))
        if raw_max < i64(min(i32)) || raw_max > i64(max(i32)) {
            lua.L_error(L, "random.%s: max must fit in a datagrid cell", fn_name)
            return
        }
        max_value = i32(raw_max)
    }
    lua.pop(L, 1)

    if min_value > max_value {
        lua.L_error(L, "random.%s: min must be <= max", fn_name)
        return
    }

    return
}

fill_noise_datagrid_cells :: proc(g: ^Datagrid, seed: i64, opts: Noise_Opts, min_value, max_value: i32) {
    value_count := i64(max_value) - i64(min_value) + 1

    for y := 0; y < g.height; y += 1 {
        row := y * g.width

        for x := 0; x < g.width; x += 1 {
            value := sample_noise_2d(f64(x), f64(y), seed, opts)
            cell_value := i64(min_value) + i64(value * f64(value_count))

            if cell_value > i64(max_value) {
                cell_value = i64(max_value)
            }

            g.cells[row + x] = i32(cell_value)
        }
    }
}

noise_pixelmap_colors_from_opts :: proc(L: ^lua.State, arg_idx: c.int, fn_name: cstring) -> (low_color, high_color: u32) {
    low_color = u32(0x000000FF)
    high_color = u32(0xFFFFFFFF)

    idx := lua.Index(arg_idx)
    if bool(lua.isnoneornil(L, idx)) {
        return
    }

    lua.getfield(L, idx, "low_color")
    if !bool(lua.isnoneornil(L, -1)) {
        raw_color := i64(lua.L_checkinteger(L, -1))
        if raw_color < 0 || raw_color > i64(max(u32)) {
            lua.L_error(L, "random.%s: low_color must be a color integer", fn_name)
            return
        }
        low_color = u32(raw_color)
    }
    lua.pop(L, 1)

    lua.getfield(L, idx, "high_color")
    if !bool(lua.isnoneornil(L, -1)) {
        raw_color := i64(lua.L_checkinteger(L, -1))
        if raw_color < 0 || raw_color > i64(max(u32)) {
            lua.L_error(L, "random.%s: high_color must be a color integer", fn_name)
            return
        }
        high_color = u32(raw_color)
    }
    lua.pop(L, 1)

    return
}

fill_noise_pixelmap_pixels :: proc(surf: Pixelmap, seed: i64, opts: Noise_Opts, low_color, high_color: u32) {
    pixels := cast([^]u32)surf.pixels
    stride := int(surf.pitch) / 4

    for y := 0; y < int(surf.h); y += 1 {
        row := y * stride

        for x := 0; x < int(surf.w); x += 1 {
            value := sample_noise_2d(f64(x), f64(y), seed, opts)
            logical_color := noise_lerp_color(low_color, high_color, value)
            pixels[row + x] = u32_rgba_to_abgr(logical_color)
        }
    }
}



// ============================================================================
// Lua API
// ============================================================================

// == Generator Control ==

// random.set_seed(seed)
lua_random_set_seed :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    seed := lua_check_seed(L, 1, "set_seed")
    rand.reset_u64(seed, rand.xoshiro256_random_generator(&rngs[active_rng]))
    return 0
}

// random.new_generator(seed) -> generator
lua_random_new_generator :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    seed := lua_check_seed(L, 1, "new_generator")

    if rng_count >= MAX_RNGS {
        lua.L_error(L, "random.new_generator: too many generators")
        return 0
    }

    idx := rng_count
    rng_count += 1

    rngs[idx] = {}
    rand.reset_u64(seed, rand.xoshiro256_random_generator(&rngs[idx]))

    lua.pushinteger(L, lua.Integer(idx))
    return 1
}

// random.set_generator(generator)
lua_random_set_generator :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    active_rng = lua_check_rng_handle(L, 1, "set_generator")
    return 0
}


// == Scalar Random ==

// random.float() -> number
lua_random_float :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    value := rand.float64(rand.xoshiro256_random_generator(&rngs[active_rng]))
    lua.pushnumber(L, lua.Number(value))
    return 1
}

// random.int(min, max) -> int
lua_random_int :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    lo := int(lua.L_checkinteger(L, 1))
    hi := int(lua.L_checkinteger(L, 2))

    if lo > hi {
        lua.L_error(L, "random.int: min must be <= max")
        return 0
    }

    if hi == max(int) {
        lua.L_error(L, "random.int: max is too large")
        return 0
    }

    value := rand.int_range(lo, hi + 1, rand.xoshiro256_random_generator(&rngs[active_rng]))
    lua.pushinteger(L, lua.Integer(value))
    return 1
}

// == List Random ==

// random.pick(list, weights?) -> value
lua_random_pick :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    lua.L_checktype(L, 1, lua.Type.TABLE)

    item_count := int(lua.objlen(L, 1))
    if item_count <= 0 {
        lua.L_error(L, "random.pick: list must not be empty")
        return 0
    }

    gen := rand.xoshiro256_random_generator(&rngs[active_rng])

    // Uniform pick.
    if lua.type(L, 2) == lua.Type.NONE || lua.type(L, 2) == lua.Type.NIL {
        item_index := rand.int_range(1, item_count + 1, gen)
        lua.rawgeti(L, 1, lua.Integer(item_index))
        return 1
    }

    lua.L_checktype(L, 2, lua.Type.TABLE)

    if int(lua.objlen(L, 2)) != item_count {
        lua.L_error(L, "random.pick: weights length must match list length")
        return 0
    }

    total_weight: f64

    // Validate weights before consuming random state.
    for i := 1; i <= item_count; i += 1 {
        lua.rawgeti(L, 2, lua.Integer(i))

        if !bool(lua.isnumber(L, -1)) {
            lua.L_error(L, "random.pick: weights must be numbers")
            return 0
        }

        weight := f64(lua.tonumber(L, -1))
        lua.pop(L, 1)

        if weight < 0 {
            lua.L_error(L, "random.pick: weights must be non-negative")
            return 0
        }

        total_weight += weight
    }

    if total_weight <= 0 {
        lua.L_error(L, "random.pick: sum of weights must be greater than zero")
        return 0
    }

    roll := rand.float64(gen) * total_weight
    for i := 1; i <= item_count; i += 1 {
        lua.rawgeti(L, 2, lua.Integer(i))
        weight := f64(lua.tonumber(L, -1))
        lua.pop(L, 1)

        if roll < weight {
            lua.rawgeti(L, 1, lua.Integer(i))
            return 1
        }

        roll -= weight
    }
    // Defensive fallback for floating-point rounding.
    lua.rawgeti(L, 1, lua.Integer(item_count))
    return 1
}

// random.shuffle(list) -> list
lua_random_shuffle :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    lua.L_checktype(L, 1, lua.Type.TABLE)

    item_count := int(lua.objlen(L, 1))
    gen := rand.xoshiro256_random_generator(&rngs[active_rng])

    for i := item_count; i >= 2; i -= 1 {
        j := rand.int_range(1, i + 1, gen)

        lua.rawgeti(L, 1, lua.Integer(i))
        lua.rawgeti(L, 1, lua.Integer(j))

        lua.rawseti(L, 1, c.int(i))
        lua.rawseti(L, 1, c.int(j))
    }

    lua.pushvalue(L, 1)
    return 1
}



// == Noise Fields ==

// random.noise(x, y, seed, opts?) -> number
lua_random_noise :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    x := f64(lua.L_checknumber(L, 1))
    y := f64(lua.L_checknumber(L, 2))
    seed := i64(lua_check_seed(L, 3, "noise"))
    opts := lua_check_noise_opts(L, 4, "noise")

    lua.pushnumber(L, lua.Number(sample_noise_2d(x, y, seed, opts)))
    return 1
}

// random.new_noise_datagrid(width, height, seed, opts?) -> datagrid
lua_random_new_noise_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    width  := int(lua.L_checkinteger(L, 1))
    height := int(lua.L_checkinteger(L, 2))

    if width <= 0 || height <= 0 {
        lua.L_error(L, "random.new_noise_datagrid: width and height must be positive")
        return 0
    }

    seed := i64(lua_check_seed(L, 3, "new_noise_datagrid"))
    opts := lua_check_noise_opts(L, 4, "new_noise_datagrid")
    min_value, max_value := noise_datagrid_range_from_opts(L, 4, "new_noise_datagrid")

    g := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    g^ = new_datagrid(width, height)

    fill_noise_datagrid_cells(g, seed, opts, min_value, max_value)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    return 1
}

// random.fill_noise_datagrid(datagrid, seed, opts?)
lua_random_fill_noise_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        lua.L_error(L, "random.fill_noise_datagrid: datagrid has been freed")
        return 0
    }

    seed := i64(lua_check_seed(L, 2, "fill_noise_datagrid"))
    opts := lua_check_noise_opts(L, 3, "fill_noise_datagrid")
    min_value, max_value := noise_datagrid_range_from_opts(L, 3, "fill_noise_datagrid")

    fill_noise_datagrid_cells(g, seed, opts, min_value, max_value)
    return 0
}

// random.new_noise_pixelmap(width, height, seed, opts?) -> pixelmap
lua_random_new_noise_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    width  := c.int(lua.L_checkinteger(L, 1))
    height := c.int(lua.L_checkinteger(L, 2))

    if width <= 0 || height <= 0 {
        lua.L_error(L, "random.new_noise_pixelmap: width and height must be positive")
        return 0
    }

    seed := i64(lua_check_seed(L, 3, "new_noise_pixelmap"))
    opts := lua_check_noise_opts(L, 4, "new_noise_pixelmap")
    low_color, high_color := noise_pixelmap_colors_from_opts(L, 4, "new_noise_pixelmap")

    surface := sdl.CreateSurface(width, height, sdl.PixelFormat.RGBA32)
    if surface == nil {
        err := sdl.GetError()
        if err != nil {
            lua.L_error(L, "random.new_noise_pixelmap: failed to create pixelmap surface: %s", err)
        } else {
            lua.L_error(L, "random.new_noise_pixelmap: failed to create pixelmap surface")
        }
        return 0
    }

    fill_noise_pixelmap_pixels(surface, seed, opts, low_color, high_color)

    (cast(^Pixelmap)lua.newuserdata(L, size_of(Pixelmap)))^ = surface

    lua.L_getmetatable(L, "Pixelmap")
    lua.setmetatable(L, -2)

    return 1
}

// random.fill_noise_pixelmap(pixelmap, seed, opts?)
lua_random_fill_noise_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil {
        lua.L_error(L, "random.fill_noise_pixelmap: pixelmap has been freed")
        return 0
    }

    seed := i64(lua_check_seed(L, 2, "fill_noise_pixelmap"))
    opts := lua_check_noise_opts(L, 3, "fill_noise_pixelmap")
    low_color, high_color := noise_pixelmap_colors_from_opts(L, 3, "fill_noise_pixelmap")

    fill_noise_pixelmap_pixels(surf, seed, opts, low_color, high_color)
    return 0
}


// ============================================================================
// Lua Registration
// ============================================================================

register_random_api :: proc() {
    lua.newtable(Lua)

    lua_bind_function(lua_random_set_seed,      "set_seed")
    lua_bind_function(lua_random_new_generator, "new_generator")
    lua_bind_function(lua_random_set_generator, "set_generator")

    // == Scalar Random ==
    lua_bind_function(lua_random_float, "float")
    lua_bind_function(lua_random_int,   "int")

    // == List Random ==
    lua_bind_function(lua_random_pick,  "pick")
    lua_bind_function(lua_random_shuffle, "shuffle")

    // == Noise Fields ==
    lua_bind_function(lua_random_noise,                "noise")
    lua_bind_function(lua_random_new_noise_pixelmap,   "new_noise_pixelmap")
    lua_bind_function(lua_random_fill_noise_pixelmap,  "fill_noise_pixelmap")
    lua_bind_function(lua_random_new_noise_datagrid,   "new_noise_datagrid")
    lua_bind_function(lua_random_fill_noise_datagrid,  "fill_noise_datagrid")


    lua.setglobal(Lua, "random")
}
