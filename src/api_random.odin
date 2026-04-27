package main

import "base:runtime"
import "core:c"
import rand "core:math/rand"
import lua "luajit"

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

// == List Selection ==

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

// ============================================================================
// Lua Registration
// ============================================================================

register_random_api :: proc() {
    lua.newtable(Lua)

    lua_bind_function(lua_random_set_seed,      "set_seed")
    lua_bind_function(lua_random_new_generator, "new_generator")
    lua_bind_function(lua_random_set_generator, "set_generator")

    lua_bind_function(lua_random_float, "float")
    lua_bind_function(lua_random_int,   "int")
    lua_bind_function(lua_random_pick,  "pick")

    lua.setglobal(Lua, "random")
}
