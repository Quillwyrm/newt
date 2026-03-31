# monotome.font
The font management API, handling typeface loading and sizing.

### Functions
* [`init`](#monotomefontinit)
* [`load`](#monotomefontload)
* [`set_size`](#monotomefontset_size)
* [`size`](#monotomefontsize)
* [`paths`](#monotomefontpaths)

---

## monotome.font.init
Initializes the font engine with a size and a set of 4 font paths.

### Usage
```lua
monotome.font.init(size, paths)
```

### Arguments
- `number: size` - The font size in pixels (must be > 0).
- `table: paths` - A list of 4 string file paths corresponding to `{ Regular, Bold, Italic, Bold-Italic }`.

### Returns
None.

---

## monotome.font.load
Updates the font paths without changing the current font size.

### Usage
```lua
monotome.font.load(paths)
```

### Arguments
- `table: paths` - A list of 4 string file paths corresponding to `{ Regular, Bold, Italic, Bold-Italic }`.

### Returns
None.

---

## monotome.font.set_size
Sets the target font size in pixels.

### Usage
```lua
monotome.font.set_size(size)
```

### Arguments
- `number: size` - The new font size in pixels (must be > 0).

### Returns
None.

---

## monotome.font.size
Gets the current font size.

### Usage
```lua
size = monotome.font.size()
```

### Arguments
None.

### Returns
- `number: size` - The current font size in pixels.

---

## monotome.font.paths
Gets the currently configured font file paths.

### Usage
```lua
paths = monotome.font.paths()
```

### Arguments
None.

### Returns
- `table: paths` - A list of 4 string file paths `{ Regular, Bold, Italic, Bold-Italic }`.
