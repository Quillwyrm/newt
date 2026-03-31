# runtime

The lifecycle hooks for the application. The Lua script must assign functions to these slots to handle initialization, logic updates, and rendering. All hooks are expected under the global `runtime` module.

## Callback Functions
* [`init`](#runtimeinit)
* [`update`](#runtimeupdate)
* [`draw`](#runtimedraw)

---

### runtime.init

The entry point of the application. Called exactly once when the engine starts.
**Critical:** You must call `window.init()` inside this function. If the window and graphics context are not created here, the engine will log an error and exit immediately.

#### Usage
```lua
runtime.init = function()
```

---

### runtime.update

The main game loop. Called once per frame to handle logic, input processing, and state changes.

#### Usage
```lua
runtime.update = function(dt)
```

#### Arguments
- `number: dt` - The time elapsed since the last frame in seconds (Delta Time).

---

### runtime.draw

The rendering loop. Called once per frame after `update`. All `graphics` drawing calls should happen inside this function.

#### Usage
```lua
runtime.draw = function()
```