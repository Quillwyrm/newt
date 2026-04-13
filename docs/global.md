# Global Functions

These functions are global and do not require a module prefix.

### free

Immediately releases an engine userdata resource instead of waiting for garbage collection. This is used for values such as `Image`, `Sound`, `Font`, or `Pixelmap`.  
Passing a non-userdata value does nothing.

```lua
free(resource)
```

---

### rgba

Constructs a packed 32-bit color value for use in color arguments.

- `r`, `g`, `b`, and `a` are clamped to `0` through `255`
- `a` defaults to `255`
- 6-digit hex strings or numbers default to full opacity
- `hex_string` may include `#`
- invalid inputs return solid white (`0xFFFFFFFF`)

```lua
rgba(r, g, b)
rgba(r, g, b, a)
rgba(hex_string)
rgba(hex_number)
```

#### Returns

A packed color integer in `0xRRGGBBAA` format.