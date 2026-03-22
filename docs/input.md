# monotome.input
The input API handles keyboard and mouse events. It provides both polling for live state and frame-accurate state changes (pressed/released).

### Functions
* [`down`](#monotomeinputdown)
* [`pressed`](#monotomeinputpressed)
* [`released`](#monotomeinputreleased)
* [`repeated`](#monotomeinputrepeated)
* [`mouse_position`](#monotomeinputmouse_position)
* [`mouse_wheel`](#monotomeinputmouse_wheel)
* [`start_text`](#monotomeinputstart_text)
* [`stop_text`](#monotomeinputstop_text)
* [`text`](#monotomeinputtext)

### Valid Input Tokens
All input functions expecting a `key` argument must use one of the following string tokens.
- **Mouse:** `"mouse1"` (left), `"mouse2"` (right), `"mouse3"` (middle)
- **Letters:** `"a"` to `"z"`
- **Numbers:** `"0"` to `"9"`
- **Keypad:** `"kp0"` to `"kp9"`, `"kp."`, `"kp,"`, `"kp/"`, `"kp*"`, `"kp-"`, `"kp+"`, `"kpenter"`, `"kp="`
- **F-Keys:** `"f1"` to `"f18"`
- **Controls:** `"space"`, `"tab"`, `"return"`, `"backspace"`, `"escape"`, `"delete"`, `"insert"`, `"home"`, `"end"`, `"pageup"`, `"pagedown"`, `"up"`, `"down"`, `"left"`, `"right"`
- **Modifiers:** `"lshift"`, `"rshift"`, `"lctrl"`, `"rctrl"`, `"lalt"`, `"ralt"`, `"lsuper"`, `"rsuper"`, `"capslock"`, `"numlock"`, `"scrolllock"`, `"mode"`
- **Symbols:** `"!"`, `"\""`, `"#"`, `"$"`, `"&"`, `"'"`, `"("`, `")"`, `"*"` `"+"`, `","`, `"-"`, `"."`, `"/"`, `":"`, `";"`, `"<"`, `"="`, `">"`, `"?"`, `"@"`, `"["`, `"\\"`, `"]"`, `"^"`, `"_"`, `"`"`
- **System:** `"pause"`, `"printscreen"`, `"menu"`, `"power"`, `"undo"`, `"help"`, `"sysreq"`, `"application"`, `"currencyunit"`
- **App Control:** `"appsearch"`, `"apphome"`, `"appback"`, `"appforward"`, `"apprefresh"`, `"appbookmarks"`

---

## monotome.input.down
Checks if a key or mouse button is currently held down.

### Usage
```lua
is_down = monotome.input.down(key)
```

### Arguments
- `string: key` - A valid key name or mouse token (e.g., `"space"`, `"mouse1"`, `"a"`).

### Returns
- `boolean: is_down` - `true` if the key is held, `false` otherwise.

---

## monotome.input.pressed
Checks if a key or mouse button was pressed **this frame**.

### Usage
```lua
was_pressed = monotome.input.pressed(key)
```

### Arguments
- `string: key` - A valid key name or mouse token.

### Returns
- `boolean: was_pressed` - `true` if the key was pressed since the last frame.

---

## monotome.input.released
Checks if a key or mouse button was released **this frame**.

### Usage
```lua
was_released = monotome.input.released(key)
```

### Arguments
- `string: key` - A valid key name or mouse token.

### Returns
- `boolean: was_released` - `true` if the key was released since the last frame.

---

## monotome.input.repeated
Checks if a key generated a repeat event **this frame** (OS typematic repeat). This returns true only on the "echo" events when a key is held down, **excluding** the initial press.

### Usage
```lua
is_repeat = monotome.input.repeated(key)
```

### Arguments
- `string: key` - A valid key name (e.g., `"space"`, `"a"`, `"backspace"`). **Mouse tokens are not valid.**

### Returns
- `boolean: is_repeat` - `true` if the key triggered a repeat event this frame.

---

## monotome.input.mouse_position
Gets the current mouse cursor position in **grid coordinates**.

### Usage
```lua
col, row = monotome.input.mouse_position()
```

### Arguments
None.

### Returns
- `number: col` - The column index under the mouse (integers, may be negative or OOB).
- `number: row` - The row index under the mouse.

---

## monotome.input.mouse_wheel
Gets the accumulated mouse wheel scroll delta for this frame.

### Usage
```lua
dx, dy = monotome.input.mouse_wheel()
```

### Arguments
None.

### Returns
- `number: dx` - Horizontal scroll amount.
- `number: dy` - Vertical scroll amount.

---

## monotome.input.start_text
Enables text input events. While enabled, typing will generate characters accessible via `input.text()`.

### Usage
```lua
monotome.input.start_text()
```

### Arguments
None.

### Returns
None.

---

## monotome.input.stop_text
Disables text input events.

### Usage
```lua
monotome.input.stop_text()
```

### Arguments
None.

### Returns
None.

---

## monotome.input.text
Gets the UTF-8 text characters typed during this frame. Requires `start_text()` to be active.

### Usage
```lua
text = monotome.input.text()
```

### Arguments
None.

### Returns
- `string: text` - The string of characters typed this frame (empty if none).
