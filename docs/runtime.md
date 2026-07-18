# runtime

The `runtime` module contains the main lifecycle callbacks for the application.
Define these callbacks to run code during startup and the per-frame update loop. Drawing is done from `runtime.update`.

## Callbacks

### init

Called once when the application starts.

```lua
runtime.init = function()
    -- startup code here
end
```

---

### update

Called once per frame.
`dt` is the elapsed time since the previous frame, in seconds.

```lua
runtime.update = function(dt)
    -- update and draw here
end
```

## Functions

### get_delta_time

Returns the elapsed time for the current frame, in seconds.

Inside `runtime.update(dt)`, this returns the same value as `dt`.

```lua
runtime.get_delta_time() -> dt
```
