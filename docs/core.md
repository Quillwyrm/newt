# core

The Luagame core API provides fundamental engine primitives. These functions are injected directly into the global Lua environment and do not require a module prefix.

### Functions
* [`free`](#free)
* [`rgba`](#rgba)

---

## free

Immediately executes the garbage collection metamethod (`__gc`) of an engine userdata object, explicitly reclaiming its backend memory without waiting for the Lua garbage collector.

### Usage
```lua
free(object)
```

### Arguments
* `userdata: object` - The engine resource to destroy (e.g., a loaded Sound or Image).

---

## rgba

Constructs a packed 32-bit integer color used by the graphics pipeline. It can parse distinct RGBA values, hex strings, or passthrough an existing packed integer.

### Usage
```lua
color = rgba(r, g, b, a?)
-- or
color = rgba(hex_string)
```

### Arguments
* `number: r`, `number: g`, `number: b` - Red, green, and blue components (0-255).
* `number: a` (Optional) - Alpha component (0-255, defaults to 255).
* `string: hex_string` - A hex color string (e.g., `"#FF00FF"` or `"FF00FF"`).

### Returns
* `number: color` - The packed 32-bit color integer (`0xRRGGBBAA`).