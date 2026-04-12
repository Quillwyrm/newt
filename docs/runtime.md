# runtime

The `runtime` module contains the main lifecycle callbacks for the application.  
Define these callbacks to run code during startup, per-frame updates, and drawing.

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

Called once per frame before `runtime.draw`.  
`dt` is the elapsed time since the previous frame, in seconds.

```lua
runtime.update = function(dt)
    -- runtime logic here
end
```

---

### draw

Called once per frame after `runtime.update`.

```lua
runtime.draw = function()
    -- draw calls here
end
```