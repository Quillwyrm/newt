# input

The `input` module provides keyboard, mouse, and text input queries.  
Unless noted otherwise, functions in this module throw on wrong arity or wrong argument types.

## Functions

**Button State**
* [`down`](#down)
* [`pressed`](#pressed)
* [`released`](#released)
* [`repeated`](#repeated)

**Mouse**
* [`get_mouse_position`](#get_mouse_position)
* [`get_mouse_wheel`](#get_mouse_wheel)

**Text Input**
* [`start_text`](#start_text)
* [`stop_text`](#stop_text)
* [`get_text`](#get_text)

## Input Tokens

The button-state functions use string tokens for keyboard keys and mouse buttons.

- **Mouse:** `"mouse1"` (left), `"mouse2"` (right), `"mouse3"` (middle)
- **Letters:** `"a"` to `"z"`
- **Numbers:** `"0"` to `"9"`
- **Keypad:** `"kp0"` to `"kp9"`, `"kp."`, `"kp,"`, `"kp/"`, `"kp*"`, `"kp-"`, `"kp+"`, `"kpenter"`, `"kp="`
- **Function Keys:** `"f1"` to `"f18"`
- **Controls:** `"space"`, `"tab"`, `"backspace"`, `"return"`, `"insert"`, `"delete"`, `"clear"`, `"escape"`
- **Navigation:** `"up"`, `"down"`, `"left"`, `"right"`, `"home"`, `"end"`, `"pageup"`, `"pagedown"`
- **Modifiers:** `"lshift"`, `"rshift"`, `"lctrl"`, `"rctrl"`, `"lalt"`, `"ralt"`, `"lsuper"`, `"rsuper"`, `"capslock"`, `"numlock"`, `"scrolllock"`, `"mode"`
- **System:** `"pause"`, `"help"`, `"printscreen"`, `"sysreq"`, `"menu"`, `"application"`, `"power"`, `"currencyunit"`, `"undo"`
- **App Control:** `"appsearch"`, `"apphome"`, `"appback"`, `"appforward"`, `"apprefresh"`, `"appbookmarks"`
- **Symbols:** `"!"`, `"\""`, `"#"`, `"$"`, `"&"`, `"'"`, `"("`, `")"`, `"*"`, `"+"`, `","`, `"-"`, `"."`, `"/"`, `":"`, `";"`, `"<"`, `"="`, `">"`, `"?"`, `"@"`, `"["`, `"\\"`, `"]"`, `"^"`, `"_"`, ``"`"``

## Button State

### down

Returns whether a key or mouse button is currently held down.

```lua
input.down(name) -> bool
```

#### Error Cases

Throws if `name` is not a valid input token.

---

### pressed

Returns whether a key or mouse button was pressed during the current frame.

```lua
input.pressed(name) -> bool
```

#### Error Cases

Throws if `name` is not a valid input token.

---

### released

Returns whether a key or mouse button was released during the current frame.

```lua
input.released(name) -> bool
```

#### Error Cases

Throws if `name` is not a valid input token.

---

### repeated

Returns whether a key generated a repeat event during the current frame. This does not include the initial press.

```lua
input.repeated(name) -> bool
```

#### Error Cases

Throws if `name` is not a valid input token.  
Throws if `name` is a mouse token.

## Mouse

### get_mouse_position

Returns the current mouse cursor position in window coordinates.

```lua
input.get_mouse_position() -> x, y
```

---

### get_mouse_wheel

Returns the mouse wheel delta accumulated during the current frame.

```lua
input.get_mouse_wheel() -> dx, dy
```

## Text Input

### start_text

Enables text input. While enabled, text received during the current frame is available through `input.get_text()`.

```lua
input.start_text()
```

---

### stop_text

Disables text input.

```lua
input.stop_text()
```

---

### get_text

Returns the UTF-8 text received during the current frame. Returns an empty string if no text was received.

```lua
input.get_text() -> text
```