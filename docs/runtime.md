# monotome.runtime
The lifecycle hooks for the application. The script must assign functions to these slots to handle initialization, logic updates, and rendering.

### Callback Functions
* [`init`](#monotomeruntimeinit)
* [`update`](#monotomeruntimeupdate)
* [`draw`](#monotomeruntimedraw)

---

## monotome.runtime.init
The entry point of the application. Called exactly once when the engine starts.
**Critical:** You must call `monotome.window.init()` inside this function. If the window is not created here, the engine will exit immediately.

### Usage
```lua
monotome.runtime.init = function()
```

### Arguments
None.

### Returns
None.

---

## monotome.runtime.update
The main game loop. Called once per frame to handle logic, input processing, and state changes.

### Usage
```lua
monotome.runtime.update = function(dt)
```

### Arguments
- `number: dt` - The time elapsed since the last frame in seconds (Delta Time).

### Returns
None.

---

## monotome.runtime.draw
The rendering loop. Called once per frame after `update`. All `monotome.draw` calls should happen inside this function.

### Usage
```lua
monotome.runtime.draw = function()
```

### Arguments
None.

### Returns
None.
