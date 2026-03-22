package main

import "base:runtime"
import "core:c"
import "core:strings"
import math "core:math"

import sdl "vendor:sdl3"
import lua "luajit"

//========================================================================================================================================
// INPUT API
// Keys + mouse buttons + mouse position + mouse wheel + text input + key repeat
//========================================================================================================================================
//
// Lua surface (input):
//   down(name: string)        -> bool
//   pressed(name: string)     -> bool   // initial edge only (non-repeat)
//   repeated(name: string)      -> bool   // OS typematic repeat edge only
//   released(name: string)    -> bool
//   get_mouse_position()          -> (col:int, row:int)       // cell coords, may be OOB
//   get_mouse_wheel()             -> (dx:number, dy:number)   // per-frame accumulated, cleared each new frame
//   start_text()              -> nil
//   stop_text()               -> nil
//   get_text()                    -> string // UTF-8 received this frame, cleared each new frame
//
// Contract:
// - ONLY the curated token set below is valid.
// - Unknown tokens error loudly (and include the bad token).

//========================================================================================================================================
// CURATED KEY TOKEN LIST
// token -> SDL keycode
//========================================================================================================================================

Key_Def :: struct {
	token: string,
	key:   sdl.Keycode,
}

KEYS := [?]Key_Def{
	// Letters
	{"a", sdl.K_A}, {"b", sdl.K_B}, {"c", sdl.K_C}, {"d", sdl.K_D}, {"e", sdl.K_E},
	{"f", sdl.K_F}, {"g", sdl.K_G}, {"h", sdl.K_H}, {"i", sdl.K_I}, {"j", sdl.K_J},
	{"k", sdl.K_K}, {"l", sdl.K_L}, {"m", sdl.K_M}, {"n", sdl.K_N}, {"o", sdl.K_O},
	{"p", sdl.K_P}, {"q", sdl.K_Q}, {"r", sdl.K_R}, {"s", sdl.K_S}, {"t", sdl.K_T},
	{"u", sdl.K_U}, {"v", sdl.K_V}, {"w", sdl.K_W}, {"x", sdl.K_X}, {"y", sdl.K_Y},
	{"z", sdl.K_Z},

	// Digits
	{"0", sdl.K_0}, {"1", sdl.K_1}, {"2", sdl.K_2}, {"3", sdl.K_3}, {"4", sdl.K_4},
	{"5", sdl.K_5}, {"6", sdl.K_6}, {"7", sdl.K_7}, {"8", sdl.K_8}, {"9", sdl.K_9},

	// Whitespace / editing
	{"space",     sdl.K_SPACE},
	{"tab",       sdl.K_TAB},
	{"backspace", sdl.K_BACKSPACE},
	{"return",    sdl.K_RETURN},
	{"insert",    sdl.K_INSERT},
	{"delete",    sdl.K_DELETE},
	{"clear",     sdl.K_CLEAR},

	// Navigation
	{"up",       sdl.K_UP},
	{"down",     sdl.K_DOWN},
	{"left",     sdl.K_LEFT},
	{"right",    sdl.K_RIGHT},
	{"home",     sdl.K_HOME},
	{"end",      sdl.K_END},
	{"pageup",   sdl.K_PAGEUP},
	{"pagedown", sdl.K_PAGEDOWN},

	// Function keys
	{"f1",  sdl.K_F1},  {"f2",  sdl.K_F2},  {"f3",  sdl.K_F3},  {"f4",  sdl.K_F4},
	{"f5",  sdl.K_F5},  {"f6",  sdl.K_F6},  {"f7",  sdl.K_F7},  {"f8",  sdl.K_F8},
	{"f9",  sdl.K_F9},  {"f10", sdl.K_F10}, {"f11", sdl.K_F11}, {"f12", sdl.K_F12},
	{"f13", sdl.K_F13}, {"f14", sdl.K_F14}, {"f15", sdl.K_F15}, {"f16", sdl.K_F16},
	{"f17", sdl.K_F17}, {"f18", sdl.K_F18},

	// Locks
	{"capslock",   sdl.K_CAPSLOCK},
	{"numlock",    sdl.K_NUMLOCKCLEAR},
	{"scrolllock", sdl.K_SCROLLLOCK},

	// Modifiers
	{"lshift", sdl.K_LSHIFT},
	{"rshift", sdl.K_RSHIFT},
	{"lctrl",  sdl.K_LCTRL},
	{"rctrl",  sdl.K_RCTRL},
	{"lalt",   sdl.K_LALT},
	{"ralt",   sdl.K_RALT},
	{"lsuper", sdl.K_LGUI},
	{"rsuper", sdl.K_RGUI},
	{"mode",   sdl.K_MODE},

	// Misc/system
	{"escape",       sdl.K_ESCAPE},
	{"pause",        sdl.K_PAUSE},
	{"help",         sdl.K_HELP},
	{"printscreen",  sdl.K_PRINTSCREEN},
	{"sysreq",       sdl.K_SYSREQ},
	{"menu",         sdl.K_MENU},
	{"application",  sdl.K_APPLICATION},
	{"power",        sdl.K_POWER},
	{"currencyunit", sdl.K_CURRENCYUNIT},
	{"undo",         sdl.K_UNDO},

	// App control
	{"appsearch",    sdl.K_AC_SEARCH},
	{"apphome",      sdl.K_AC_HOME},
	{"appback",      sdl.K_AC_BACK},
	{"appforward",   sdl.K_AC_FORWARD},
	{"apprefresh",   sdl.K_AC_REFRESH},
	{"appbookmarks", sdl.K_AC_BOOKMARKS},

	// Punctuation / symbols
	{"!", sdl.K_EXCLAIM},
	{"\"", sdl.K_DBLAPOSTROPHE},
	{"#", sdl.K_HASH},
	{"$", sdl.K_DOLLAR},
	{"&", sdl.K_AMPERSAND},
	{"'", sdl.K_APOSTROPHE},
	{"(", sdl.K_LEFTPAREN},
	{")", sdl.K_RIGHTPAREN},
	{"*", sdl.K_ASTERISK},
	{"+", sdl.K_PLUS},
	{",", sdl.K_COMMA},
	{"-", sdl.K_MINUS},
	{".", sdl.K_PERIOD},
	{"/", sdl.K_SLASH},
	{":", sdl.K_COLON},
	{";", sdl.K_SEMICOLON},
	{"<", sdl.K_LESS},
	{"=", sdl.K_EQUALS},
	{">", sdl.K_GREATER},
	{"?", sdl.K_QUESTION},
	{"@", sdl.K_AT},
	{"[", sdl.K_LEFTBRACKET},
	{"\\", sdl.K_BACKSLASH},
	{"]", sdl.K_RIGHTBRACKET},
	{"^", sdl.K_CARET},
	{"_", sdl.K_UNDERSCORE},
	{"`", sdl.K_GRAVE},

	// Keypad (kp*)
	{"kp0", sdl.K_KP_0}, {"kp1", sdl.K_KP_1}, {"kp2", sdl.K_KP_2}, {"kp3", sdl.K_KP_3}, {"kp4", sdl.K_KP_4},
	{"kp5", sdl.K_KP_5}, {"kp6", sdl.K_KP_6}, {"kp7", sdl.K_KP_7}, {"kp8", sdl.K_KP_8}, {"kp9", sdl.K_KP_9},
	{"kp.", sdl.K_KP_PERIOD},
	{"kp,", sdl.K_KP_COMMA},
	{"kp/", sdl.K_KP_DIVIDE},
	{"kp*", sdl.K_KP_MULTIPLY},
	{"kp-", sdl.K_KP_MINUS},
	{"kp+", sdl.K_KP_PLUS},
	{"kpenter", sdl.K_KP_ENTER},
	{"kp=",     sdl.K_KP_EQUALS},
}

//========================================================================================================================================
// HOST INPUT STATE
//========================================================================================================================================

Keyboard_State: [^]bool = nil
Keyboard_State_Count: int = 0

Key_Pressed:     [dynamic]bool
Key_Repeat:      [dynamic]bool
Key_Released:    [dynamic]bool
Key_State_Index: [dynamic]int

Token_To_Index:   map[string]int
Keycode_To_Index: map[sdl.Keycode]int

Curr_MouseButtons: sdl.MouseButtonFlags = {}
Mouse_Pressed:   [3]bool
Mouse_Released:  [3]bool
Mouse_X:         f32
Mouse_Y:         f32
Wheel_X:         f32
Wheel_Y:         f32

TEXT_BUF_CAP :: 4096
Text_Active: bool
Text_Len:    int
Text_Buffer: [TEXT_BUF_CAP]u8

Input_Initialized: bool = false

// mouse_token_to_index maps "mouse1/2/3" to 0..2.
mouse_token_to_index :: proc(token: string) -> (idx: int, ok: bool) {
	switch token {
	case "mouse1": return 0, true
	case "mouse2": return 1, true
	case "mouse3": return 2, true
	}
	return 0, false
}

// mouse_down returns whether the given mouse button index is currently held.
mouse_down :: proc(idx: int) -> bool {
	switch idx {
	case 0: return .LEFT   in Curr_MouseButtons
	case 1: return .RIGHT  in Curr_MouseButtons
	case 2: return .MIDDLE in Curr_MouseButtons
	}
	return false
}

//========================================================================================================================================
// FRAME LIFECYCLE HOOKS
//========================================================================================================================================

// input_init builds token/keycode maps and precomputes indices for SDL live keyboard state.
input_init :: proc() {
	if Input_Initialized {
		return
	}

	num_keys: c.int = 0
	Keyboard_State = sdl.GetKeyboardState(&num_keys)
	Keyboard_State_Count = cast(int)(num_keys)
	if Keyboard_State == nil || Keyboard_State_Count <= 0 {
		panic("SDL_GetKeyboardState failed")
	}

	n := len(KEYS)

	Key_Pressed     = make([dynamic]bool, n)
	Key_Repeat      = make([dynamic]bool, n)
	Key_Released    = make([dynamic]bool, n)
	Key_State_Index = make([dynamic]int,  n)

	Token_To_Index   = make(map[string]int)
	Keycode_To_Index = make(map[sdl.Keycode]int)

	for idx in 0..<n {
		def := KEYS[idx]

		Token_To_Index[def.token] = idx
		Keycode_To_Index[def.key] = idx

		mod: sdl.Keymod
		sc := sdl.GetScancodeFromKey(def.key, &mod)
		sc_i := cast(int)(sc)

		if sc_i > 0 && sc_i < Keyboard_State_Count {
			Key_State_Index[idx] = sc_i
		} else {
			Key_State_Index[idx] = -1
		}
	}

	mx, my: f32
	Curr_MouseButtons = sdl.GetMouseState(&mx, &my)
	Mouse_X = mx
	Mouse_Y = my

	Wheel_X = 0
	Wheel_Y = 0

	Text_Active = false
	Text_Len = 0

	Input_Initialized = true
}

// input_begin_frame clears per-frame edge flags and per-frame accumulators.
input_begin_frame :: proc() {
	if !Input_Initialized {
		return
	}

	sdl.PumpEvents()

	for i in 0..<len(Key_Pressed)  { Key_Pressed[i]  = false }
	for i in 0..<len(Key_Repeat)   { Key_Repeat[i]   = false }
	for i in 0..<len(Key_Released) { Key_Released[i] = false }

	Mouse_Pressed  = {}
	Mouse_Released = {}

	Wheel_X = 0
	Wheel_Y = 0

	Text_Len = 0
}

// input_handle_event updates edge flags / accumulators from one SDL event.
input_handle_event :: proc(event: ^sdl.Event) {
	if !Input_Initialized {
		return
	}

	#partial switch event.type {
	case .KEY_DOWN:
		if idx, ok := Keycode_To_Index[event.key.key]; ok {
			if event.key.repeat {
				Key_Repeat[idx] = true
			} else {
				Key_Pressed[idx] = true
			}
		}

	case .KEY_UP:
		if idx, ok := Keycode_To_Index[event.key.key]; ok {
			Key_Released[idx] = true
		}

	case .MOUSE_BUTTON_DOWN:
		switch event.button.button {
		case sdl.BUTTON_LEFT:   Mouse_Pressed[0] = true
		case sdl.BUTTON_RIGHT:  Mouse_Pressed[1] = true
		case sdl.BUTTON_MIDDLE: Mouse_Pressed[2] = true
		}

	case .MOUSE_BUTTON_UP:
		switch event.button.button {
		case sdl.BUTTON_LEFT:   Mouse_Released[0] = true
		case sdl.BUTTON_RIGHT:  Mouse_Released[1] = true
		case sdl.BUTTON_MIDDLE: Mouse_Released[2] = true
		}

	case .MOUSE_WHEEL:
		Wheel_X += event.wheel.x
		Wheel_Y += event.wheel.y

	case .TEXT_INPUT:
		if Text_Active && event.text.text != nil {
			n := runtime.cstring_len(event.text.text)
			if n > 0 {
				space := TEXT_BUF_CAP - Text_Len
				if space > 0 {
					if n > space { n = space }
					runtime.mem_copy(rawptr(&Text_Buffer[Text_Len]), rawptr(event.text.text), n)
					Text_Len += n
				}
			}
		}

	case .WINDOW_FOCUS_LOST:
		sdl.ResetKeyboard()
	}
}

// input_end_frame samples final live mouse state for this frame.
input_end_frame :: proc() {
	if !Input_Initialized {
		return
	}

	mx, my: f32
	Curr_MouseButtons = sdl.GetMouseState(&mx, &my)
	Mouse_X = mx
	Mouse_Y = my
}

// input_shutdown frees input-owned allocations and resets state.
// Host-only. Safe to call even if init never happened.
input_shutdown :: proc() {
	if !Input_Initialized {
		return
	}

	// dynamic arrays
	delete(Key_Pressed);     Key_Pressed     = nil
	delete(Key_Repeat);      Key_Repeat      = nil
	delete(Key_Released);    Key_Released    = nil
	delete(Key_State_Index); Key_State_Index = nil

	// maps
	if Token_To_Index != nil {
		delete(Token_To_Index)
		Token_To_Index = nil
	}
	if Keycode_To_Index != nil {
		delete(Keycode_To_Index)
		Keycode_To_Index = nil
	}

	// state reset (no external ownership)
	Keyboard_State = nil
	Keyboard_State_Count = 0

	Curr_MouseButtons = {}
	Mouse_Pressed  = {}
	Mouse_Released = {}

	Mouse_X = 0
	Mouse_Y = 0
	Wheel_X = 0
	Wheel_Y = 0

	Text_Active = false
	Text_Len = 0

	Input_Initialized = false
}

//========================================================================================================================================
// LUA SURFACE (C CALLS)
//========================================================================================================================================

// down(name) -> bool
lua_input_down :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if !Input_Initialized {
		lua.L_error(L, cstring("input.down: input not initialized"))
		return 0
	}
	if lua.gettop(L) != 1 {
		lua.L_error(L, cstring("input.down expects 1 arg: name"))
		return 0
	}

	name_len: c.size_t
	name_c := lua.L_checklstring(L, 1, &name_len)
	name := strings.string_from_ptr(cast(^byte)(name_c), int(name_len))

	if mouse_idx, is_mouse := mouse_token_to_index(name); is_mouse {
		lua.pushboolean(L, b32(mouse_down(mouse_idx)))
		return 1
	}

	idx, ok := Token_To_Index[name]
	if !ok {
		lua.L_error(L, cstring("input.down: unknown token '%.*s'"), c.int(name_len), name_c)
		return 0
	}

	state_i := Key_State_Index[idx]
	if state_i < 0 {
		lua.L_error(L, cstring("input.down: token '%.*s' not supported on this keyboard/layout"), c.int(name_len), name_c)
		return 0
	}

	lua.pushboolean(L, b32(Keyboard_State[state_i]))
	return 1
}

// pressed(name) -> bool
lua_input_pressed :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if !Input_Initialized {
		lua.L_error(L, cstring("input.pressed: input not initialized"))
		return 0
	}
	if lua.gettop(L) != 1 {
		lua.L_error(L, cstring("input.pressed expects 1 arg: name"))
		return 0
	}

	name_len: c.size_t
	name_c := lua.L_checklstring(L, 1, &name_len)
	name := strings.string_from_ptr(cast(^byte)(name_c), int(name_len))

	if mouse_idx, is_mouse := mouse_token_to_index(name); is_mouse {
		lua.pushboolean(L, b32(Mouse_Pressed[mouse_idx]))
		return 1
	}

	idx, ok := Token_To_Index[name]
	if !ok {
		lua.L_error(L, cstring("input.pressed: unknown token '%.*s'"), c.int(name_len), name_c)
		return 0
	}

	lua.pushboolean(L, b32(Key_Pressed[idx]))
	return 1
}

// repeated(name) -> bool (repeat-only; does not include initial press)
lua_input_repeated :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if !Input_Initialized {
		lua.L_error(L, cstring("input.repeated: input not initialized"))
		return 0
	}
	if lua.gettop(L) != 1 {
		lua.L_error(L, cstring("input.repeated expects 1 arg: name"))
		return 0
	}

	name_len: c.size_t
	name_c := lua.L_checklstring(L, 1, &name_len)
	name := strings.string_from_ptr(cast(^byte)(name_c), int(name_len))

	if _, is_mouse := mouse_token_to_index(name); is_mouse {
		lua.L_error(L, cstring("input.repeated: '%.*s' is a mouse token"), c.int(name_len), name_c)
		return 0
	}

	idx, ok := Token_To_Index[name]
	if !ok {
		lua.L_error(L, cstring("input.repeated: unknown token '%.*s'"), c.int(name_len), name_c)
		return 0
	}

	lua.pushboolean(L, b32(Key_Repeat[idx]))
	return 1
}

// released(name) -> bool
lua_input_released :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if !Input_Initialized {
		lua.L_error(L, cstring("input.released: input not initialized"))
		return 0
	}
	if lua.gettop(L) != 1 {
		lua.L_error(L, cstring("input.released expects 1 arg: name"))
		return 0
	}

	name_len: c.size_t
	name_c := lua.L_checklstring(L, 1, &name_len)
	name := strings.string_from_ptr(cast(^byte)(name_c), int(name_len))

	if mouse_idx, is_mouse := mouse_token_to_index(name); is_mouse {
		lua.pushboolean(L, b32(Mouse_Released[mouse_idx]))
		return 1
	}

	idx, ok := Token_To_Index[name]
	if !ok {
		lua.L_error(L, cstring("input.released: unknown token '%.*s'"), c.int(name_len), name_c)
		return 0
	}

	lua.pushboolean(L, b32(Key_Released[idx]))
	return 1
}

// get_mouse_position() -> (x:number, y:number)
lua_input_get_mouse_position :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if !Input_Initialized {
		lua.L_error(L, cstring("input.get_mouse_position: input not initialized"))
		return 0
	}
	if lua.gettop(L) != 0 {
		lua.L_error(L, cstring("input.get_mouse_position expects 0 args"))
		return 0
	}

	mx, my: f32
	_ = sdl.GetMouseState(&mx, &my)

	lua.pushnumber(L, lua.Number(mx))
	lua.pushnumber(L, lua.Number(my))
	return 2
}

// get_mouse_wheel() -> (dx:number, dy:number)
lua_input_get_mouse_wheel :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if !Input_Initialized {
		lua.L_error(L, cstring("input.get_mouse_wheel: input not initialized"))
		return 0
	}
	if lua.gettop(L) != 0 {
		lua.L_error(L, cstring("input.get_mouse_wheel expects 0 args"))
		return 0
	}

	lua.pushnumber(L, cast(lua.Number)(Wheel_X))
	lua.pushnumber(L, cast(lua.Number)(Wheel_Y))
	return 2
}

// start_text() -> nil
lua_input_start_text :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if !Input_Initialized {
		lua.L_error(L, cstring("input.start_text: input not initialized"))
		return 0
	}
	if lua.gettop(L) != 0 {
		lua.L_error(L, cstring("input.start_text expects 0 args"))
		return 0
	}
	if Window == nil {
		lua.L_error(L, cstring("input.start_text: window not initialized"))
		return 0
	}

	if !sdl.StartTextInput(Window) {
		lua.L_error(L, cstring("input.start_text: SDL_StartTextInput failed: %s"), sdl.GetError())
		return 0
	}

	Text_Active = true
	return 0
}

// stop_text() -> nil
lua_input_stop_text :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if !Input_Initialized {
		lua.L_error(L, cstring("input.stop_text: input not initialized"))
		return 0
	}
	if lua.gettop(L) != 0 {
		lua.L_error(L, cstring("input.stop_text expects 0 args"))
		return 0
	}
	if Window == nil {
		lua.L_error(L, cstring("input.stop_text: window not initialized"))
		return 0
	}

	if !sdl.StopTextInput(Window) {
		lua.L_error(L, cstring("input.stop_text: SDL_StopTextInput failed: %s"), sdl.GetError())
		return 0
	}

	Text_Active = false
	return 0
}

// text() -> string
lua_input_get_text :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	if !Input_Initialized {
		lua.L_error(L, cstring("input.get_text: input not initialized"))
		return 0
	}
	if lua.gettop(L) != 0 {
		lua.L_error(L, cstring("input.get_text expects 0 args"))
		return 0
	}

	if Text_Len <= 0 {
		lua.pushlstring(L, cstring(""), 0)
		return 1
	}

	lua.pushlstring(L, cast(cstring)(&Text_Buffer[0]), c.size_t(Text_Len))
	return 1
}

// register_input_api creates the input table and leaves it on the Lua stack.
register_input_api :: proc(Lua: ^lua.State) {
	lua.newtable(Lua)

	lua.pushcfunction(Lua, lua_input_down)
	lua.setfield(Lua, -2, cstring("down"))

	lua.pushcfunction(Lua, lua_input_pressed)
	lua.setfield(Lua, -2, cstring("pressed"))

	lua.pushcfunction(Lua, lua_input_repeated)
	lua.setfield(Lua, -2, cstring("repeated"))

	lua.pushcfunction(Lua, lua_input_released)
	lua.setfield(Lua, -2, cstring("released"))

	lua.pushcfunction(Lua, lua_input_get_mouse_position)
	lua.setfield(Lua, -2, cstring("get_mouse_position"))

	lua.pushcfunction(Lua, lua_input_get_mouse_wheel)
	lua.setfield(Lua, -2, cstring("get_mouse_wheel"))

	lua.pushcfunction(Lua, lua_input_start_text)
	lua.setfield(Lua, -2, cstring("start_text"))

	lua.pushcfunction(Lua, lua_input_stop_text)
	lua.setfield(Lua, -2, cstring("stop_text"))

	lua.pushcfunction(Lua, lua_input_get_text)
	lua.setfield(Lua, -2, cstring("get_text"))
	
	// Set the table as a global named "input"
	lua.setglobal(Lua, cstring("input"))
}

