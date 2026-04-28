# random

The `random` module provides seeded random generators, scalar random values, list randomization, and deterministic noise fields.

Functions in this module error on missing required arguments and wrong argument types.

Sequential random calls use the active generator and are order-dependent. Noise calls are coordinate-based, explicitly seeded, and do not consume the active generator.

Generator `0` exists at startup and is active by default.

## Functions

**Generator Control**
* [`set_seed`](#set_seed)
* [`new_generator`](#new_generator)
* [`set_generator`](#set_generator)

**Scalar Random**
* [`float`](#float)
* [`int`](#int)

**List Random**
* [`pick`](#pick)
* [`shuffle`](#shuffle)

**Noise Fields**
* [`noise`](#noise)
* [`new_noise_pixelmap`](#new_noise_pixelmap)
* [`fill_noise_pixelmap`](#fill_noise_pixelmap)
* [`new_noise_datagrid`](#new_noise_datagrid)
* [`fill_noise_datagrid`](#fill_noise_datagrid)


## Generator Control

### set_seed

Reseeds the active generator.

This affects later sequential calls to `float`, `int`, `pick`, and `shuffle`.

```lua
random.set_seed(seed)
```

#### Error Cases

- `seed < 0`.

---

### new_generator

Creates a new seeded generator.

```lua
random.new_generator(seed) -> generator
```

#### Returns

A generator handle.

#### Error Cases

- `seed < 0`.
- Too many generators have been created.

---

### set_generator

Sets the active generator.

```lua
random.set_generator(generator)
```

#### Error Cases

- `generator` is not a valid generator handle.

## Scalar Random

### float

Returns the next random number from the active generator.

The value is in `0..1`, excluding `1`.

```lua
random.float() -> number
```

---

### int

Returns the next random integer from the active generator.

Both `min` and `max` are inclusive.

```lua
random.int(min, max) -> int
```

#### Error Cases

- `min > max`.
- `max` is too large.

## List Random

List randomization functions operate on array-style Lua lists using indices `1..#list`. Non-index table fields are ignored.

### pick

Picks one value from a list.

When `weights` is omitted, every item has equal chance. When `weights` is provided, each weight matches the item at the same list index. Zero weights are allowed and remove the matching item from selection.

```lua
random.pick(list, weights?) -> value
```

#### Error Cases

- `list` is empty.
- `weights` length does not match `list` length.
- `weights` contains a non-number.
- `weights` contains a negative number.
- Sum of weights is not greater than zero.

---

### shuffle

Shuffles a list in place using the active generator.

Empty and one-item lists are returned unchanged.

```lua
random.shuffle(list) -> list
```

#### Returns

The same list.

## Noise Fields

Noise fields are deterministic random values sampled by coordinate and seed.

The same coordinate, seed, and options return the same value regardless of call order. Noise does not read from or advance the active generator.

Noise options control scale and octave layering. Pixelmap and datagrid fills use the same noise options, plus mapping fields for their output.

```lua
{
    frequency = 1.0,
    octaves = 1,
    lacunarity = 2.0,
    gain = 0.5,
}
```

- `frequency` controls how quickly noise changes across coordinates.
- `octaves` controls how many noise layers are combined.
- `lacunarity` controls how much frequency increases per octave.
- `gain` controls how much each later octave contributes.

#### Noise Options Error Cases

- `seed < 0`.
- `frequency <= 0`.
- `octaves < 1`.
- `lacunarity <= 0`.
- `gain < 0`.

---

### noise

Returns deterministic 2D noise at a coordinate.

The returned value is normalized to `0..1`.

```lua
random.noise(x, y, seed, options?) -> number
```

---

### new_noise_pixelmap

Creates a new [`Pixelmap`](raster.md) filled with deterministic noise.

By default, this writes a black-to-white grayscale gradient. Set `low_color` and `high_color` in `options` to write a two-color gradient.

```lua
random.new_noise_pixelmap(width, height, seed, options?) -> pixelmap
```

#### Returns

- A new pixelmap.

#### Error Cases

- `width <= 0`.
- `height <= 0`.
- `seed < 0`.
- `low_color` is not a color integer.
- `high_color` is not a color integer.

---


### fill_noise_pixelmap

Fills a [`Pixelmap`](raster.md) with deterministic noise.

By default, this writes a black-to-white grayscale gradient. Set `low_color` and `high_color` in `options` to write a two-color gradient.

Pixelmaps can be displayed with [`graphics.new_image_from_pixelmap`](graphics.md#new_image_from_pixelmap) or [`graphics.update_image_from_pixelmap`](graphics.md#update_image_from_pixelmap).

```lua
random.fill_noise_pixelmap(pixelmap, seed, options?)

-- pixelmap mapping fields:
{
    low_color = rgba("#000000"),
    high_color = rgba("#FFFFFF"),
}
```

#### Error Cases

- Pixelmap has been freed.
- `low_color` is not a color integer.
- `high_color` is not a color integer.

---

### new_noise_datagrid

Creates a new [`Datagrid`](grid.md) filled with deterministic noise mapped to integer cell values.

By default, values are written in the inclusive range `0..1`. Set `min` and `max` in `options` to choose a different integer range.

```lua
random.new_noise_datagrid(width, height, seed, options?) -> datagrid
```

#### Returns

- A new datagrid.

#### Error Cases

- `width <= 0`.
- `height <= 0`.
- `seed < 0`.
- `min` does not fit in a datagrid cell.
- `max` does not fit in a datagrid cell.
- `min > max`.

---

### fill_noise_datagrid

Fills a [`Datagrid`](grid.md) with deterministic noise mapped to integer cell values.

By default, values are written in the inclusive range `0..1`. Set `min` and `max` in `options` to choose a different integer range.

The filled datagrid can be converted to a [`Pixelmap`](raster.md) with [`raster.new_pixelmap_from_datagrid`](raster.md#new_pixelmap_from_datagrid).

```lua
random.fill_noise_datagrid(datagrid, seed, options?)

-- datagrid mapping fields:
{
    min = 0,
    max = 1,
}
```

#### Error Cases

- Datagrid has been freed.
- `min` does not fit in a datagrid cell.
- `max` does not fit in a datagrid cell.
- `min > max`.