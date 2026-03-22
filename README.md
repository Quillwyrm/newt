# LUAGAME

## API


**runtime (callbacks)**
* `init()`
* `update(dt)`
* `draw()`

**window**
* `window.init(width, height, title, flags?)`
* `window.close()`
* `window.should_close() -> bool`
* `window.get_size() -> (w, h)`
* `window.get_position() -> (x, y)`
* `window.set_title(title)`
* `window.set_size(width, height)`
* `window.set_position(x, y)`
* `window.maximize()`
* `window.minimize()`
* `window.set_cursor(name)`
* `window.cursor_show()`
* `window.cursor_hide()`
* `window.cursor_visible() -> bool`
* `window.get_clipboard() -> string`
* `window.set_clipboard(text)`

**graphics**
* `graphics.clear([color])`
* `graphics.draw_rect(x, y, w, h, [color])`
* `graphics.draw_debug_text(x, y, text, [color])`
* `graphics.draw_image(img, x, y, [color])`
* `graphics.draw_image_region(img, sx, sy, sw, sh, x, y, [color])`
* `graphics.draw_sprite(atlas, idx, x, y, [color])`
* `graphics.load_image(path) -> Image | nil, err`
* `graphics.load_atlas(path, cell_w, cell_h) -> Atlas | nil, err`
* `graphics.set_default_filter("nearest" | "linear")`
* `graphics.get_image_size(img) -> w, h`
* `graphics.set_draw_rotation(angle)`
* `graphics.set_draw_scale(sx, sy)`
* `graphics.set_draw_origin(ox, oy)`
* `graphics.begin_transform_group()`
* `graphics.end_transform_group()`

**input**
* `input.down(name: string) -> bool`
* `input.pressed(name: string) -> bool`
* `input.repeated(name: string) -> bool`
* `input.released(name: string) -> bool`
* `input.get_mouse_position() -> (col:int, row:int)`
* `input.get_mouse_wheel() -> (dx:number, dy:number)`
* `input.start_text() -> nil`
* `input.stop_text() -> nil`
* `input.get_text() -> string`

**filesystem**
* `filesystem.get_resource_dir() -> string | (nil, err)`
* `filesystem.get_working_dir() -> string | (nil, err)`
* `filesystem.set_working_dir(path:string) -> (ok:boolean, err?:string)`
* `filesystem.get_args() -> {string...}`
* `filesystem.list_dir(path:string) -> { {name:string, kind:string}... } | (nil, err)`
* `filesystem.info(path:string) -> {kind:string, size:number, modified_time:number} | (nil, err)`
* `filesystem.read_file(path:string) -> string | (nil, err)`
* `filesystem.write_file(path:string, data:string) -> (ok:boolean, err?:string)`
* `filesystem.mkdir(path:string) -> (ok:boolean, err?:string)`
* `filesystem.rename(old_path:string, new_path:string) -> (ok:boolean, err?:string)`
* `filesystem.remove(path:string) -> (ok:boolean, err?:string)`

**Global Namespace**
* `release(userdata)`


## Status

**Active Development.** The core API is stable but subject to change.

