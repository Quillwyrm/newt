# window
The Luagame windowing API manages the display context, input state, and OS-level window controls. All functions are available under the global `window` module.

### Functions
**Lifecycle**
* [`init`](#windowinit)
* [`close`](#windowclose)
* [`should_close`](#windowshould_close)

**Getters**
* [`get_size`](#windowget_size)
* [`get_position`](#windowget_position)

**Setters**
* [`set_title`](#windowset_title)
* [`set_size`](#windowset_size)
* [`set_position`](#windowset_position)
* [`maximize`](#windowmaximize)
* [`minimize`](#windowminimize)

**Cursor & Clipboard**
* [`set_cursor`](#windowset_cursor)
* [`cursor_show`](#windowcursor_show)
* [`cursor_hide`](#windowcursor_hide)
* [`cursor_visible`](#windowcursor_visible)
* [`get_clipboard`](#windowget_clipboard)
* [`set_clipboard`](#windowset_clipboard)

---

## window.init
Initializes the main window and renderer context.

### Usage
```lua
window.init(width, height, title, flags?)
```

### Arguments
- `number: width` - Initial window width in pixels.
- `number: height` - Initial window height in pixels.
- `string: title` - The window title.
- `table: flags` (Optional) - A list of string flags: `{"fullscreen", "borderless", "resizable"}`.

### Returns
None.

---

## window.close
Closes the window and destroys the rendering context.

### Usage
```lua
window.close()
```

### Returns
None.

---

## window.should_close
Checks if the user has requested the window to close (e.g., clicking the 'X' button).

### Usage
```lua
running = window.should_close()
```

### Returns
- `boolean: requested` - `true` if a close event is pending.

---

## window.get_size
Returns the current window dimensions.

### Usage
```lua
w, h = window.get_size()
```

### Returns
- `number: w` - Width in pixels.
- `number: h` - Height in pixels.

---

## window.get_position
Returns the window's position on the screen.

### Usage
```lua
x, y = window.get_position()
```

### Returns
- `number: x` - X coordinate.
- `number: y` - Y coordinate.

---

## window.set_title
Updates the window title text.

### Usage
```lua
window.set_title(text)
```

### Arguments
- `string: text` - New title string.

---

## window.set_size
Sets the window dimensions.

### Usage
```lua
window.set_size(w, h)
```

### Arguments
- `number: w`
- `number: h`

---

## window.set_position
Sets the window position on the screen.

### Usage
```lua
window.set_position(x, y)
```

### Arguments
- `number: x`
- `number: y`

---

## window.maximize
Maximizes the window to fill the screen.

### Usage
```lua
window.maximize()
```

---

## window.minimize
Minimizes the window to the taskbar/dock.

### Usage
```lua
window.minimize()
```

---

## window.set_cursor
Sets the system mouse cursor shape.

### Usage
```lua
window.set_cursor(name)
```

### Arguments
- `string: name` - One of: `"arrow"`, `"ibeam"`, `"wait"`, `"waitarrow"`, `"crosshair"`, `"sizenwse"`, `"sizenesw"`, `"sizewe"`, `"sizens"`, `"sizeall"`, `"no"`, `"hand"`.

---

## window.cursor_show
Shows the mouse cursor.

### Usage
```lua
window.cursor_show()
```

---

## window.cursor_hide
Hides the mouse cursor.

### Usage
```lua
window.cursor_hide()
```

---

## window.cursor_visible
Checks if the cursor is currently visible.

### Usage
```lua
visible = window.cursor_visible()
```

### Returns
- `boolean: visible` - `true` if the cursor is visible.

---

## window.get_clipboard
Gets the text currently in the OS clipboard.

### Usage
```lua
text = window.get_clipboard()
```

### Returns
- `string: text` - The clipboard content, or `nil` if empty.

---

## window.set_clipboard
Sets the OS clipboard text.

### Usage
```lua
window.set_clipboard(text)
```

### Arguments
- `string: text` - The string to copy to the clipboard.