# window

The `window` module provides access to the main window and related OS window features.  
Unless noted otherwise, functions in this module throw on wrong arity or wrong argument types.

## Functions

**Lifecycle**
* [`close`](#close)
* [`cancel_close`](#cancel_close)
* [`should_close`](#should_close)

**Getters**
* [`get_size`](#get_size)
* [`get_position`](#get_position)

**Setters**
* [`set_title`](#set_title)
* [`set_size`](#set_size)
* [`set_position`](#set_position)
* [`set_flags`](#set_flags)
* [`maximize`](#maximize)
* [`minimize`](#minimize)

**Cursor & Clipboard**
* [`set_cursor`](#set_cursor)
* [`cursor_show`](#cursor_show)
* [`cursor_hide`](#cursor_hide)
* [`is_cursor_visible`](#is_cursor_visible)
* [`get_clipboard`](#get_clipboard)
* [`set_clipboard`](#set_clipboard)

## Lifecycle
These functions close the window or query close requests.

---
### close

Closes the window.

```lua
window.close()
```

---
### cancel_close

Cancels a close request.  
Use this to keep the application running after a close request.

```lua
window.cancel_close()
```

---
### should_close

Returns whether a close has been requested.  
This returns `true` after the close button is pressed, or after `window.close()` is called.

```lua
window.should_close() -> bool
```

## Getters
These functions return the current window state.

---
### get_size

Returns the current window size in pixels.

```lua
window.get_size() -> width, height
```

---
### get_position

Returns the current window position on the desktop.

```lua
window.get_position() -> x, y
```

## Setters
These functions change window properties such as title, size, position, and flags.

---
### set_title

Sets the window title.

```lua
window.set_title(text)
```

---
### set_size

Sets the window size in pixels.

```lua
window.set_size(width, height)
```

---
### set_position

Sets the window position on the desktop.

```lua
window.set_position(x, y)
```

---
### set_flags

Sets the window flags.

Passing no arguments or `nil` clears all optional flags.  
`flags` is a table containing any combination of these strings:

- `"fullscreen"`: switches the window to fullscreen mode.
- `"borderless"`: removes the window border and title bar.
- `"resizable"`: allows the window to be resized.

```lua
window.set_flags()
window.set_flags(nil)
window.set_flags(flags)
```

#### Error Cases

- Throws if any flag string is invalid.

---
### maximize

Maximizes the window.

```lua
window.maximize()
```

---
### minimize

Minimizes the window.

```lua
window.minimize()
```

## Cursor & Clipboard
These functions control the cursor and read or write clipboard text.

---
### set_cursor

Sets the cursor shape.  
Supported cursor names:

- `"arrow"`: standard arrow cursor.
- `"ibeam"`: text input cursor.
- `"wait"`: busy cursor.
- `"waitarrow"`: arrow with busy indicator.
- `"crosshair"`: crosshair cursor.
- `"sizenwse"`: diagonal resize cursor.
- `"sizenesw"`: diagonal resize cursor.
- `"sizewe"`: horizontal resize cursor.
- `"sizens"`: vertical resize cursor.
- `"sizeall"`: move cursor.
- `"no"`: unavailable cursor.
- `"hand"`: hand cursor.

```lua
window.set_cursor(name)
```

#### Error Cases

- Throws if `name` is not a valid cursor name.

---
### cursor_show

Shows the cursor.

```lua
window.cursor_show()
```

---
### cursor_hide

Hides the cursor.

```lua
window.cursor_hide()
```

---
### is_cursor_visible

Returns whether the cursor is visible.

```lua
window.is_cursor_visible() -> bool
```

---
### get_clipboard

Returns the current clipboard text as a string.

```lua
window.get_clipboard() -> text
```

---
### set_clipboard

Sets the clipboard text.

```lua
window.set_clipboard(text)
```

#### Error Cases

- Throws if `text` contains a NUL byte.