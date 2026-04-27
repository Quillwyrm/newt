# Global Functions

These functions are global and do not require a module prefix.

### free

Immediately calls a userdata resource value's `__gc` metamethod. This is used to release Newt engine resources such as `Image`, `Sound`, `Font`, `Pixelmap`, and `Datagrid` before Lua's garbage collector runs.

Passing a non-userdata value, or userdata without a `__gc` metamethod, does nothing.

Calling `free` more than once on a Newt resource is safe; resource finalizers clear their owned handles after releasing them.

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