package main

import "base:runtime"
import "core:c"
import "core:strings"
import lua "luajit"
import sdl "vendor:sdl3"

// Later possible additions:
// - stick deadzone helpers/settings
// - connection state query: wired / wireless / unknown
// - power info query: battery state + percent
// - trigger rumble support, separate from normal rumble
// - controller mapping/debug info
// - paddles

// ============================================================================
// Curated Key Tokens
// ============================================================================

GamepadButtonDef :: struct {
    token:  string,
    button: sdl.GamepadButton,
}

GAMEPAD_BUTTONS := [?]GamepadButtonDef {
    {"south", .SOUTH},
    {"east", .EAST},
    {"west", .WEST},
    {"north", .NORTH},

    {"up", .DPAD_UP},
    {"down", .DPAD_DOWN},
    {"left", .DPAD_LEFT},
    {"right", .DPAD_RIGHT},

    {"back", .BACK},
    {"guide", .GUIDE},
    {"start", .START},

    {"left_stick", .LEFT_STICK},
    {"right_stick", .RIGHT_STICK},
    {"left_shoulder", .LEFT_SHOULDER},
    {"right_shoulder", .RIGHT_SHOULDER},
}

BTN_COUNT :: len(GAMEPAD_BUTTONS)
TRIGGER_DEFAULT_THRESHOLD :: 0.5

// ============================================================================
// Gamepad State
// ============================================================================
// Pads are 1-based Lua-facing controller slots.
// Newt tracks up to 8 connected gamepads.
// Missing/nil pad means pad 1.
// New gamepads fill the first empty slot.
// Removed gamepads clear their slot; later slots do not shift.

MAX_GAMEPADS :: 8

GamepadSide :: enum {LEFT, RIGHT}
StickAxis   :: enum {X, Y}
GamepadInstance :: struct {
    handle: ^sdl.Gamepad,
    id:     sdl.JoystickID,

    buttons:      [BTN_COUNT]bool,
    buttons_prev: [BTN_COUNT]bool,

    triggers:      [GamepadSide]f32,
    triggers_prev: [GamepadSide]f32,

    sticks: [GamepadSide][StickAxis]f32,
}

Gamepad_Instances: [MAX_GAMEPADS]GamepadInstance

// ============================================================================
// Host Helpers
// ============================================================================

// Converts SDL's broad controller type enum to Newt's Lua-facing type string.
pad_type_to_string :: proc "contextless"(pad_type: sdl.GamepadType) -> cstring {
    switch pad_type {
    case .UNKNOWN:                      return "unknown"
    case .STANDARD:                     return "standard"
    case .XBOX360:                      return "xbox360"
    case .XBOXONE:                      return "xboxone"
    case .PS3:                          return "ps3"
    case .PS4:                          return "ps4"
    case .PS5:                          return "ps5"
    case .NINTENDO_SWITCH_PRO:          return "switch_pro"
    case .NINTENDO_SWITCH_JOYCON_LEFT:  return "switch_joycon_left"
    case .NINTENDO_SWITCH_JOYCON_RIGHT: return "switch_joycon_right"
    case .NINTENDO_SWITCH_JOYCON_PAIR:  return "switch_joycon_pair"
    }
    return "unknown"
}

// Finds Newt's internal 0-based slot for an SDL joystick instance id.
// Used by hotplug events, where missing ids are normal.
find_pad_idx_by_id :: proc "contextless"(pad_id: sdl.JoystickID) -> (idx: int, ok: bool) {
    for i in 0..<MAX_GAMEPADS {
        if Gamepad_Instances[i].handle != nil && Gamepad_Instances[i].id == pad_id {
            return i, true
        }
    }

    return 0, false
}

// Checks an optional Lua pad slot and returns Newt's internal 0-based slot.
// Missing/nil pad means pad 1.
lua_check_pad :: proc "contextless"(L: ^lua.State, arg_idx: int, fn_name: cstring) -> int {
    if int(lua.gettop(L)) < arg_idx || lua.isnil(L, lua.Index(arg_idx)) {
        return 0
    }

    pad := int(lua.L_checkinteger(L, c.int(arg_idx)))
    if pad < 1 || pad > MAX_GAMEPADS {
        lua.L_error(L, "gamepad.%s: pad must be between 1 and %d", fn_name, MAX_GAMEPADS)
        return 0
    }

    return pad - 1
}

// Checks a Lua button token and returns its curated button table index.
lua_check_button :: proc(L: ^lua.State, arg_idx: int, fn_name: cstring) -> int {
    button_len: c.size_t
    button_c := lua.L_checklstring(L, c.int(arg_idx), &button_len)
    button := strings.string_from_ptr(cast(^byte)(button_c), int(button_len))

    for i in 0..<BTN_COUNT {
        if GAMEPAD_BUTTONS[i].token == button {
            return i
        }
    }

    lua.L_error(L, "gamepad.%s: unknown button '%.*s'", fn_name, c.int(button_len), button_c)
    return 0
}

// Checks a Lua side token: "left" or "right".
lua_check_side :: proc(L: ^lua.State, arg_idx: int, fn_name: cstring) -> GamepadSide {
    side_len: c.size_t
    side_c := lua.L_checklstring(L, c.int(arg_idx), &side_len)
    side := strings.string_from_ptr(cast(^byte)(side_c), int(side_len))

    switch side {
    case "left":  return .LEFT
    case "right": return .RIGHT
    }

    lua.L_error(L, "gamepad.%s: unknown side '%.*s'", fn_name, c.int(side_len), side_c)
    return .LEFT
}

// Checks an optional trigger threshold.
// Missing/nil threshold uses TRIGGER_DEFAULT_THRESHOLD.
lua_check_trigger_threshold :: proc "contextless"(L: ^lua.State, arg_idx: int, fn_name: cstring) -> f32 {
    if int(lua.gettop(L)) < arg_idx || lua.isnil(L, lua.Index(arg_idx)) {
        return TRIGGER_DEFAULT_THRESHOLD
    }

    threshold := f32(lua.L_checknumber(L, c.int(arg_idx)))
    if threshold <= 0 || threshold > 1 {
        lua.L_error(L, "gamepad.%s: threshold must be > 0 and <= 1", fn_name)
        return TRIGGER_DEFAULT_THRESHOLD
    }

    return threshold
}

// Converts SDL's signed stick axis range to -1..1 stick value.
normalize_sdl_stick_axis :: proc "contextless"(value: sdl.Sint16) -> f32 {
    v := f32(value)

    if v < 0 {
        result := v / -f32(sdl.JOYSTICK_AXIS_MIN)
        if result < -1 do return -1
        return result
    }

    result := v / f32(sdl.JOYSTICK_AXIS_MAX)
    if result > 1 do return 1
    return result
}

// Converts SDL's trigger axis range to 0..1 trigger value.
normalize_sdl_trigger_axis :: proc "contextless"(value: sdl.Sint16) -> f32 {
    if value <= 0 do return 0
    result := f32(value) / f32(sdl.JOYSTICK_AXIS_MAX)
    if result > 1 do return 1
    return result
}

// ============================================================================
// Frame Lifecycle
// ============================================================================

gamepad_init :: proc() {
    Gamepad_Instances = {}
    sdl.SetGamepadEventsEnabled(true)

    count: c.int
    ids := sdl.GetGamepads(&count)
    if ids == nil {
        return
    }
    defer sdl.free(rawptr(ids))

    for id_idx in 0..<int(count) {
        idx := -1
        for i in 0..<MAX_GAMEPADS {
            if Gamepad_Instances[i].handle == nil {
                idx = i
                break
            }
        }
        if idx < 0 {
            break
        }

        handle := sdl.OpenGamepad(ids[id_idx])
        if handle == nil {
            continue
        }

        Gamepad_Instances[idx].handle = handle
        Gamepad_Instances[idx].id = ids[id_idx]
    }

    gamepad_poll_state()
}

gamepad_handle_event :: proc(event: ^sdl.Event) {
    #partial switch event.type {
    case .GAMEPAD_ADDED:
        pad_id := event.gdevice.which
        if _, exists := find_pad_idx_by_id(pad_id); exists {
            return
        }
        if !sdl.IsGamepad(pad_id) {
            return
        }

        idx := -1
        for i in 0..<MAX_GAMEPADS {
            if Gamepad_Instances[i].handle == nil {
                idx = i
                break
            }
        }
        if idx < 0 {
            return
        }

        handle := sdl.OpenGamepad(pad_id)
        if handle == nil {
            return
        }

        Gamepad_Instances[idx].handle = handle
        Gamepad_Instances[idx].id = pad_id

    case .GAMEPAD_REMOVED:
        idx, ok := find_pad_idx_by_id(event.gdevice.which)
        if !ok {
            return
        }

        sdl.CloseGamepad(Gamepad_Instances[idx].handle)
        Gamepad_Instances[idx] = {}
    }
}

gamepad_poll_state :: proc() {
    sdl.UpdateGamepads()

    for i in 0..<MAX_GAMEPADS {
        pad := &Gamepad_Instances[i]
        if pad.handle == nil {
            continue
        }

        pad.buttons_prev = pad.buttons
        pad.triggers_prev = pad.triggers

        for button_idx in 0..<BTN_COUNT {
            pad.buttons[button_idx] = sdl.GetGamepadButton(pad.handle, GAMEPAD_BUTTONS[button_idx].button)
        }

        pad.triggers[.LEFT] = normalize_sdl_trigger_axis(sdl.GetGamepadAxis(pad.handle, .LEFT_TRIGGER))
        pad.triggers[.RIGHT] = normalize_sdl_trigger_axis(sdl.GetGamepadAxis(pad.handle, .RIGHT_TRIGGER))
        
        pad.sticks[.LEFT][.X] = normalize_sdl_stick_axis(sdl.GetGamepadAxis(pad.handle, .LEFTX))
        pad.sticks[.LEFT][.Y] = normalize_sdl_stick_axis(sdl.GetGamepadAxis(pad.handle, .LEFTY))
        pad.sticks[.RIGHT][.X] = normalize_sdl_stick_axis(sdl.GetGamepadAxis(pad.handle, .RIGHTX))
        pad.sticks[.RIGHT][.Y] = normalize_sdl_stick_axis(sdl.GetGamepadAxis(pad.handle, .RIGHTY))
    }
}

gamepad_shutdown :: proc() {
    for i in 0..<MAX_GAMEPADS {
        if Gamepad_Instances[i].handle != nil {
            sdl.CloseGamepad(Gamepad_Instances[i].handle)
        }
    }

    Gamepad_Instances = {}
}

// ============================================================================
// Lua Gamepad Bindings
// ============================================================================

// == Queries ==

// gamepad.get_count() -> count
lua_gamepad_get_count :: proc "c"(L: ^lua.State) -> c.int {
    if lua.gettop(L) != 0 {
        lua.L_error(L, "gamepad.get_count: expected 0 arguments")
        return 0
    }

    count := 0
    for i in 0..<MAX_GAMEPADS {
        if Gamepad_Instances[i].handle != nil {
            count += 1
        }
    }

    lua.pushinteger(L, lua.Integer(count))
    return 1
}

// gamepad.is_connected(pad?) -> bool
lua_gamepad_is_connected :: proc "c"(L: ^lua.State) -> c.int {
    if lua.gettop(L) > 1 {
        lua.L_error(L, "gamepad.is_connected: expected 0 or 1 arguments")
        return 0
    }

    idx := lua_check_pad(L, 1, "is_connected")
    lua.pushboolean(L, b32(Gamepad_Instances[idx].handle != nil))
    return 1
}

// gamepad.get_name(pad?) -> name | nil
lua_gamepad_get_name :: proc "c"(L: ^lua.State) -> c.int {
    if lua.gettop(L) > 1 {
        lua.L_error(L, "gamepad.get_name: expected 0 or 1 arguments")
        return 0
    }

    idx := lua_check_pad(L, 1, "get_name")

    handle := Gamepad_Instances[idx].handle
    if handle == nil {
        lua.pushnil(L)
        return 1
    }

    name := sdl.GetGamepadName(handle)
    if name == nil {
        lua.pushnil(L)
        return 1
    }

    lua.pushstring(L, name)
    return 1
}

// gamepad.get_type(pad?) -> type | nil
lua_gamepad_get_type :: proc "c"(L: ^lua.State) -> c.int {
    if lua.gettop(L) > 1 {
        lua.L_error(L, "gamepad.get_type: expected 0 or 1 arguments")
        return 0
    }

    idx := lua_check_pad(L, 1, "get_type")

    handle := Gamepad_Instances[idx].handle
    if handle == nil {
        lua.pushnil(L)
        return 1
    }

    lua.pushstring(L, pad_type_to_string(sdl.GetGamepadType(handle)))
    return 1
}

// gamepad.get_button_label(button, pad?) -> label | nil
lua_gamepad_get_button_label :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) < 1 || lua.gettop(L) > 2 {
        lua.L_error(L, "gamepad.get_button_label: expected 1 or 2 arguments: button, pad")
        return 0
    }

    button_idx := lua_check_button(L, 1, "get_button_label")
    pad_idx := lua_check_pad(L, 2, "get_button_label")

    handle := Gamepad_Instances[pad_idx].handle
    if handle == nil {
        lua.pushnil(L)
        return 1
    }

    label := sdl.GetGamepadButtonLabel(handle, GAMEPAD_BUTTONS[button_idx].button)

    label_name: cstring = nil
    switch label {
    case .A: label_name = "a"
    case .B: label_name = "b"
    case .X: label_name = "x"
    case .Y: label_name = "y"
    case .CROSS: label_name = "cross"
    case .CIRCLE: label_name = "circle"
    case .SQUARE: label_name = "square"
    case .TRIANGLE: label_name = "triangle"
    case .UNKNOWN:
    }

    if label_name == nil {
        lua.pushnil(L)
        return 1
    }

    lua.pushstring(L, label_name)
    return 1
}

// == Button Polling ==

// gamepad.down(button, pad?) -> bool
lua_gamepad_down :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) < 1 || lua.gettop(L) > 2 {
        lua.L_error(L, "gamepad.down: expected 1 or 2 arguments: button, pad")
        return 0
    }

    button_idx := lua_check_button(L, 1, "down")
    pad_idx := lua_check_pad(L, 2, "down")

    lua.pushboolean(L, b32(Gamepad_Instances[pad_idx].handle != nil && Gamepad_Instances[pad_idx].buttons[button_idx]))
    return 1
}

// gamepad.pressed(button, pad?) -> bool
lua_gamepad_pressed :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) < 1 || lua.gettop(L) > 2 {
        lua.L_error(L, "gamepad.pressed: expected 1 or 2 arguments: button, pad")
        return 0
    }

    button_idx := lua_check_button(L, 1, "pressed")
    pad_idx := lua_check_pad(L, 2, "pressed")
    pad := &Gamepad_Instances[pad_idx]

    lua.pushboolean(L, b32(pad.handle != nil && !pad.buttons_prev[button_idx] && pad.buttons[button_idx]))
    return 1
}

// gamepad.released(button, pad?) -> bool
lua_gamepad_released :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) < 1 || lua.gettop(L) > 2 {
        lua.L_error(L, "gamepad.released: expected 1 or 2 arguments: button, pad")
        return 0
    }

    button_idx := lua_check_button(L, 1, "released")
    pad_idx := lua_check_pad(L, 2, "released")
    pad := &Gamepad_Instances[pad_idx]

    lua.pushboolean(L, b32(pad.handle != nil && pad.buttons_prev[button_idx] && !pad.buttons[button_idx]))
    return 1
}

// == Axis Polling ==

// gamepad.stick(side, pad?) -> x, y
lua_gamepad_stick :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) < 1 || lua.gettop(L) > 2 {
        lua.L_error(L, "gamepad.stick: expected 1 or 2 arguments: side, pad")
        return 0
    }

    side := lua_check_side(L, 1, "stick")
    pad_idx := lua_check_pad(L, 2, "stick")
    pad := &Gamepad_Instances[pad_idx]

    if pad.handle == nil {
        lua.pushnumber(L, lua.Number(0))
        lua.pushnumber(L, lua.Number(0))
        return 2
    }

    lua.pushnumber(L, lua.Number(pad.sticks[side][.X]))
    lua.pushnumber(L, lua.Number(pad.sticks[side][.Y]))
    return 2
}

// gamepad.trigger(side, pad?) -> value
lua_gamepad_trigger :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) < 1 || lua.gettop(L) > 2 {
        lua.L_error(L, "gamepad.trigger: expected 1 or 2 arguments: side, pad")
        return 0
    }

    side := lua_check_side(L, 1, "trigger")
    pad_idx := lua_check_pad(L, 2, "trigger")
    pad := &Gamepad_Instances[pad_idx]

    if pad.handle == nil {
        lua.pushnumber(L, lua.Number(0))
        return 1
    }

    lua.pushnumber(L, lua.Number(pad.triggers[side]))
    return 1
}

// == Trigger Edge Polling ==

// gamepad.trigger_down(side, threshold?, pad?) -> bool
lua_gamepad_trigger_down :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) < 1 || lua.gettop(L) > 3 {
        lua.L_error(L, "gamepad.trigger_down: expected 1 to 3 arguments: side, threshold, pad")
        return 0
    }

    side := lua_check_side(L, 1, "trigger_down")
    threshold := lua_check_trigger_threshold(L, 2, "trigger_down")
    pad_idx := lua_check_pad(L, 3, "trigger_down")
    pad := &Gamepad_Instances[pad_idx]

    lua.pushboolean(L, b32(pad.handle != nil && pad.triggers[side] >= threshold))
    return 1
}

// gamepad.trigger_pressed(side, threshold?, pad?) -> bool
lua_gamepad_trigger_pressed :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) < 1 || lua.gettop(L) > 3 {
        lua.L_error(L, "gamepad.trigger_pressed: expected 1 to 3 arguments: side, threshold, pad")
        return 0
    }

    side := lua_check_side(L, 1, "trigger_pressed")
    threshold := lua_check_trigger_threshold(L, 2, "trigger_pressed")
    pad_idx := lua_check_pad(L, 3, "trigger_pressed")
    pad := &Gamepad_Instances[pad_idx]

    lua.pushboolean(L, b32(pad.handle != nil && pad.triggers_prev[side] < threshold && pad.triggers[side] >= threshold))
    return 1
}

// gamepad.trigger_released(side, threshold?, pad?) -> bool
lua_gamepad_trigger_released :: proc "c"(L: ^lua.State) -> c.int {
    context = runtime.default_context()

    if lua.gettop(L) < 1 || lua.gettop(L) > 3 {
        lua.L_error(L, "gamepad.trigger_released: expected 1 to 3 arguments: side, threshold, pad")
        return 0
    }

    side := lua_check_side(L, 1, "trigger_released")
    threshold := lua_check_trigger_threshold(L, 2, "trigger_released")
    pad_idx := lua_check_pad(L, 3, "trigger_released")
    pad := &Gamepad_Instances[pad_idx]

    lua.pushboolean(L, b32(pad.handle != nil && pad.triggers_prev[side] >= threshold && pad.triggers[side] < threshold))
    return 1
}

// == Rumble ==

// gamepad.start_rumble(low, high, duration, pad?)
lua_gamepad_start_rumble :: proc "c"(L: ^lua.State) -> c.int {
    if lua.gettop(L) < 3 || lua.gettop(L) > 4 {
        lua.L_error(L, "gamepad.start_rumble: expected 3 or 4 arguments: low, high, duration, pad")
        return 0
    }

    low := f64(lua.L_checknumber(L, c.int(1)))
    if !(low >= 0 && low <= 1) {
        lua.L_error(L, "gamepad.start_rumble: low must be between 0 and 1")
        return 0
    }

    high := f64(lua.L_checknumber(L, c.int(2)))
    if !(high >= 0 && high <= 1) {
        lua.L_error(L, "gamepad.start_rumble: high must be between 0 and 1")
        return 0
    }

    duration := f64(lua.L_checknumber(L, c.int(3)))
    if !(duration >= 0) {
        lua.L_error(L, "gamepad.start_rumble: duration must be >= 0")
        return 0
    }

    duration_ms_value := duration * 1000.0
    if duration_ms_value > 4294967295.0 {
        lua.L_error(L, "gamepad.start_rumble: duration is too large")
        return 0
    }

    pad_idx := lua_check_pad(L, 4, "start_rumble")

    handle := Gamepad_Instances[pad_idx].handle
    if handle == nil {
        return 0
    }

    low_rumble := sdl.Uint16(low * 65535.0 + 0.5)
    high_rumble := sdl.Uint16(high * 65535.0 + 0.5)
    duration_ms := sdl.Uint32(duration_ms_value + 0.5)

    sdl.RumbleGamepad(handle, low_rumble, high_rumble, duration_ms)
    return 0
}

// gamepad.stop_rumble(pad?)
lua_gamepad_stop_rumble :: proc "c"(L: ^lua.State) -> c.int {
    if lua.gettop(L) > 1 {
        lua.L_error(L, "gamepad.stop_rumble: expected 0 or 1 arguments")
        return 0
    }

    pad_idx := lua_check_pad(L, 1, "stop_rumble")

    handle := Gamepad_Instances[pad_idx].handle
    if handle == nil {
        return 0
    }

    sdl.RumbleGamepad(handle, sdl.Uint16(0), sdl.Uint16(0), sdl.Uint32(0))
    return 0
}

// == Lua Registration ==

register_gamepad_api :: proc() {
    lua.newtable(Lua)

    // Queries
    lua_bind_function(lua_gamepad_get_count, "get_count")
    lua_bind_function(lua_gamepad_is_connected, "is_connected")
    lua_bind_function(lua_gamepad_get_name, "get_name")
    lua_bind_function(lua_gamepad_get_type, "get_type")
    lua_bind_function(lua_gamepad_get_button_label, "get_button_label")

    // Button polling
    lua_bind_function(lua_gamepad_down, "down")
    lua_bind_function(lua_gamepad_pressed, "pressed")
    lua_bind_function(lua_gamepad_released, "released")

    // Axis polling
    lua_bind_function(lua_gamepad_stick, "stick")
    lua_bind_function(lua_gamepad_trigger, "trigger")

    // Trigger edge polling
    lua_bind_function(lua_gamepad_trigger_down, "trigger_down")
    lua_bind_function(lua_gamepad_trigger_pressed, "trigger_pressed")
    lua_bind_function(lua_gamepad_trigger_released, "trigger_released")

    // Rumble
    lua_bind_function(lua_gamepad_start_rumble, "start_rumble")
    lua_bind_function(lua_gamepad_stop_rumble, "stop_rumble")

    lua.setglobal(Lua, "gamepad")
}
