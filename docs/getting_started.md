## Getting Started

Projects are loaded relative to the `Resource Directory`, which is the directory containing the executable. The executable can be renamed, and additional files or folders can be placed anywhere under the `Resource Directory`.

All relative paths passed to public file and asset APIs resolve from the `Resource Directory` by default. Absolute paths are used as-is. The `Working Directory` is exposed separately through the `filesystem` module.

The host expects `lua/main.lua` inside the `Resource Directory`. This file is the application entry point, and is where runtime callbacks such as `runtime.init`, `runtime.update`, and `runtime.draw` are typically defined.

### Windows

```sh
your_project/
├── your_game.exe
├── SDL3.dll
├── SDL3_ttf.dll
└── lua/
    └── main.lua
```

### macOS

```sh
YourGame.app/
└── Contents/
    └── MacOS/
        ├── your_game
        └── lua/
            └── main.lua
```

### Minimal `main.lua`

```lua
runtime.init = function()
    window.set_title("Welcome to Newt!")
end

runtime.draw = function()
    graphics.clear(rgba(20, 30, 20))
    graphics.draw_text("Hello from Newt!", 16, 16, rgba("#00FF00"))
end
```

For the full API surface, see the [API Reference](api_ref.md).