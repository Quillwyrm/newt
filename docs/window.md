# monotome.window
The windowing API for Monotome, handling the main display context, sizing, positioning, cursors, and clipboard.

### Functions
**Lifecycle**
* [`init`](#monotomewindowinit)
* [`close`](#monotomewindowclose)
* [`should_close`](#monotomewindowshould_close)

**Getters**
* [`size`](#monotomewindowsize)
* [`grid_size`](#monotomewindowgrid_size)
* [`cell_size`](#monotomewindowcell_size)
* [`position`](#monotomewindowposition)
* [`metrics`](#monotomewindowmetrics)

**Setters**
* [`set_title`](#monotomewindowset_title)
* [`set_size`](#monotomewindowset_size)
* [`set_position`](#monotomewindowset_position)
* [`maximize`](#monotomewindowmaximize)
* [`minimize`](#monotomewindowminimize)

**Cursor & Clipboard**
* [`set_cursor`](#monotomewindowset_cursor)
* [`cursor_show`](#monotomewindowcursor_show)
* [`cursor_hide`](#monotomewindowcursor_hide)
* [`cursor_visible`](#monotomewindowcursor_visible)
* [`get_clipboard`](#monotomewindowget_clipboard)
* [`set_clipboard`](#monotomewindowset_clipboard)

---

## monotome.window.init
Initializes the main window and renderer context.

### Usage
```lua
monotome.window.init(width, height, title, flags?)
```

### Arguments
- `number: width` - Window width in pixels.
- `number: height` - Window height in pixels.
- `string: title` - Window header title.
- `table: flags` - Optional list of config strings (`"resizable"`, `"fullscreen"`, `"borderless"`).

### Returns
None.

---

## monotome.window.close
Requests the engine to close the window and quit. This sets a flag; the actual exit happens at the end of the current frame.

### Usage
```lua
monotome.window.close()
```

### Arguments
None.

### Returns
None.

---

## monotome.window.should_close
Checks if a quit request has been issued (e.g. by the OS window close button or `window.close()`).

### Usage
```lua
closing = monotome.window.should_close()
```

### Arguments
None.

### Returns
- `boolean: closing` - `true` if the app is scheduled to exit.

---

## monotome.window.size
Gets the current window dimensions in pixels.

### Usage
```lua
w, h = monotome.window.size()
```

### Arguments
None.

### Returns
- `number: w` - Window width in pixels.
- `number: h` - Window height in pixels.

---

## monotome.window.grid_size
Gets the current window capacity in whole text cells.

### Usage
```lua
cols, rows = monotome.window.grid_size()
```

### Arguments
None.

### Returns
- `number: cols` - Number of columns that fit in the window.
- `number: rows` - Number of rows that fit in the window.

---

## monotome.window.cell_size
Gets the current dimensions of a single character cell in pixels.

### Usage
```lua
cw, ch = monotome.window.cell_size()
```

### Arguments
None.

### Returns
- `number: cw` - Cell width in pixels.
- `number: ch` - Cell height in pixels.

---

## monotome.window.position
Gets the window's top-left coordinates on the desktop.

### Usage
```lua
x, y = monotome.window.position()
```

### Arguments
None.

### Returns
- `number: x` - Desktop X coordinate.
- `number: y` - Desktop Y coordinate.

---

## monotome.window.metrics
Efficiently retrieves all window metric data in a single call.

### Usage
```lua
cols, rows, cw, ch, w, h, x, y = monotome.window.metrics()
```

### Arguments
None.

### Returns
1. `number: cols` - Grid columns.
2. `number: rows` - Grid rows.
3. `number: cw` - Cell width.
4. `number: ch` - Cell height.
5. `number: w` - Window width.
6. `number: h` - Window height.
7. `number: x` - Window X pos.
8. `number: y` - Window Y pos.

---

## monotome.window.set_title
Updates the window header title.

### Usage
```lua
monotome.window.set_title(title)
```

### Arguments
- `string: title` - The new window title.

### Returns
None.

---

## monotome.window.set_size
Sets the window dimensions in pixels.

### Usage
```lua
monotome.window.set_size(width, height)
```

### Arguments
- `number: width` - New width in pixels.
- `number: height` - New height in pixels.

### Returns
None.

---

## monotome.window.set_position
Sets the window position on the desktop.

### Usage
```lua
monotome.window.set_position(x, y)
```

### Arguments
- `number: x` - New X coordinate.
- `number: y` - New Y coordinate.

### Returns
None.

---

## monotome.window.maximize
Maximizes the window to fill the screen.

### Usage
```lua
monotome.window.maximize()
```

### Arguments
None.

### Returns
None.

---

## monotome.window.minimize
Minimizes the window to the taskbar/dock.

### Usage
```lua
monotome.window.minimize()
```

### Arguments
None.

### Returns
None.

---

## monotome.window.set_cursor
Sets the system mouse cursor shape.

### Usage
```lua
monotome.window.set_cursor(name)
```

### Arguments
- `string: name` - One of: `"arrow"`, `"ibeam"`, `"wait"`, `"waitarrow"`, `"crosshair"`, `"sizenwse"`, `"sizenesw"`, `"sizewe"`, `"sizens"`, `"sizeall"`, `"no"`, `"hand"`.

### Returns
None.

---

## monotome.window.cursor_show
Shows the mouse cursor.

### Usage
```lua
monotome.window.cursor_show()
```

### Arguments
None.

### Returns
None.

---

## monotome.window.cursor_hide
Hides the mouse cursor.

### Usage
```lua
monotome.window.cursor_hide()
```

### Arguments
None.

### Returns
None.

---

## monotome.window.cursor_visible
Checks if the cursor is currently visible.

### Usage
```lua
visible = monotome.window.cursor_visible()
```

### Arguments
None.

### Returns
- `boolean: visible` - `true` if the cursor is visible.

---

## monotome.window.get_clipboard
Gets the text currently in the OS clipboard.

### Usage
```lua
text = monotome.window.get_clipboard()
```

### Arguments
None.

### Returns
- `string: text` - The clipboard content (or empty string).

---

## monotome.window.set_clipboard
Sets the OS clipboard text.

### Usage
```lua
monotome.window.set_clipboard(text)
```

### Arguments
- `string: text` - The text to copy to the clipboard. Must not contain NUL bytes.

### Returns
None.
