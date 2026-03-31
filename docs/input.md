# input

The Luagame input API handles keyboard and mouse events. It provides polling for live state, frame-accurate edge detection (pressed/released), and text input buffering. All functions are available under the global `input` module.

#### Functions
* [`down`](#inputdown)
* [`pressed`](#inputpressed)
* [`released`](#inputreleased)
* [`repeated`](#inputrepeated)
* [`get_mouse_position`](#inputget_mouse_position)
* [`get_mouse_wheel`](#inputget_mouse_wheel)
* [`start_text`](#inputstart_text)
* [`stop_text`](#inputstop_text)
* [`get_text`](#inputget_text)

#### Valid Input Tokens
All input functions expecting a `key` argument must use one of the following string tokens.
- **Mouse:** `"mouse1"` (left), `"mouse2"` (right), `"mouse3"` (middle)
- **Letters:** `"a"` to `"z"`
- **Numbers:** `"0"` to `"9"`
- **Keypad:** `"kp0"` to `"kp9"`, `"kp."`, `"kp,"`, `"kp/"`, `"kp*"`, `"kp-"`, `"kp+"`, `"kpenter"`, `"kp="`
- **F-Keys:** `"f1"` to `"f18"`
- **Controls:** `"space"`, `"tab"`, `"return"`, `"backspace"`, `"escape"`, `"delete"`, `"insert"`, `"home"`, `"end"`, `"pageup"`, `"pagedown"`, `"up"`, `"down"`, `"left"`, `"right"`
- **Modifiers:** `"lshift"`, `"rshift"`, `"lctrl"`, `"rctrl"`, `"lalt"`, `"ralt"`, `"lsuper"`, `"rsuper"`, `"capslock"`, `"numlock"`, `"scrolllock"`, `"mode"`
- **Symbols:** `"!"`, `"\""`, `"#"`, `"$"`, `"&"`, `"'"`, `"("`, `")"`, `*"`, `"+"`, `","`, `"-"`, `"."`, `"/"`, `":"`, `";"`, `"<"`, `"="`, `">"`, `"?"`, `"@"`, `"["`, `"\\"`, `"]"`, `"^"`, `"_"`, `"\`"`
- **System:** `"pause"`, `"printscreen"`, `"menu"`, `"power"`, `"undo"`, `"help"`, `"sysreq"`, `"application"`, `"currencyunit"`
- **App Control:** `"appsearch"`, `"apphome"`, `"appback"`, `"appforward"`, `"apprefresh"`, `"appbookmarks"`

---

### input.down
Checks if a key or mouse button is currently held down.

#### Usage
```lua
is_down = input.down(key)
```

#### Arguments
- `string: key` - A valid key name or mouse token (e.g., `"space"`, `"mouse1"`, `"a"`).

#### Returns
- `boolean: is_down` - `true` if the key is held.

---

### input.pressed
Checks if a key or mouse button was pressed **this frame**.

#### Usage
```lua
was_pressed = input.pressed(key)
```

#### Arguments
- `string: key` - A valid key name or mouse token.

#### Returns
- `boolean: was_pressed` - `true` if the key was pressed since the last frame.

---

### input.released
Checks if a key or mouse button was released **this frame**.

#### Usage
```lua
was_released = input.released(key)
```

#### Arguments
- `string: key` - A valid key name or mouse token.

#### Returns
- `boolean: was_released` - `true` if the key was released since the last frame.

---

### input.repeated
Checks if a key generated a repeat event **this frame** (OS typematic repeat). This returns true only on the "echo" events when a key is held down, **excluding** the initial press.

#### Usage
```lua
is_repeat = input.repeated(key)
```

#### Arguments
- `string: key` - A valid key name. **Mouse tokens are not valid.**

#### Returns
- `boolean: is_repeat` - `true` if the key triggered a repeat event this frame.

---

### input.get_mouse_position
Gets the current mouse cursor position in window coordinates.

#### Usage
```lua
x, y = input.get_mouse_position()
```

#### Returns
- `number: x` - The horizontal position.
- `number: y` - The vertical position.

---

### input.get_mouse_wheel
Gets the accumulated mouse wheel scroll delta for this frame.

#### Usage
```lua
dx, dy = input.get_mouse_wheel()
```

#### Returns
- `number: dx` - Horizontal scroll amount.
- `number: dy` - Vertical scroll amount.

---

### input.start_text
Enables text input events. While enabled, typing will generate characters accessible via `input.get_text()`.

#### Usage
```lua
input.start_text()
```

---

### input.stop_text
Disables text input events.

#### Usage
```lua
input.stop_text()
```

---

### input.get_text
Gets the UTF-8 text characters typed during this frame. Requires `start_text()` to be active.

#### Usage
```lua
text = input.get_text()
```

#### Returns
- `string: text` - The string of characters typed this frame (empty if none).