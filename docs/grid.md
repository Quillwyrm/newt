# grid

Functions in this module operate on the `Datagrid` type, a fixed-size 2D array of 32-bit integers. Datagrids can store map data, movement costs, region data, visibility results, influence fields, and other grid-based integer data.

The module provides pathfinding, distance fields, region queries, visibility functions, and datagrid math.

Functions in this module error on wrong arity, wrong argument types, and invalid string keys. On dead datagrids, queries return nil for each output, mutations no-op, and functions that construct or solve new datagrids will error.

Module-wide movement and vision rules affect pathfinding, region connectivity, and visibility.

## Datagrid Roles

Some functions use `Datagrids` with specific value meanings. These are shapes, not separate datagrid types, and not every wrong-shape input is detected explicitly.

### Cost

A cost grid is used by pathfinding and distance-field functions. `compute_regions` also uses the same shape, but only checks whether cells are blocked or passable.

- `0` = blocked
- `> 0` = cost to enter that cell
- `< 0` = invalid input

### Source

A source grid is used by `compute_distance` to mark one or more starting cells.

- `0` = not a source
- nonzero = source

### Distance

A distance grid is returned by `compute_distance` and used by `extract_path` and `extract_downhill_path`.

- `0` = source cell
- `> 0` = solved distance
- `-1` = no path

### Region

A region map is returned by `compute_regions` and used by region-query functions like `get_region_bounds`.

- `0` = no region
- `> 0` = region id

### Occlusion

An occlusion grid is used by `compute_fov`, `compute_fov_cone`, `has_line_of_sight`, and `get_sight_line` to describe which cells block sight.

- `0` = opaque
- nonzero = transparent

A **Region** map is also a good candidate for deriving an occlusion grid, because blocked cells are already `0` and region ids are already nonzero.

### Visibility

A visibility grid is returned by `compute_fov` and `compute_fov_cone` and marks which cells are visible under the current vision rules.

- `0` = not visible
- `1` = visible

## Functions

**Datagrids**
* [`new_datagrid`](#new_datagrid)
* [`new_datagrid_from_pixelmap`](#new_datagrid_from_pixelmap)
* [`get_cell`](#get_cell)
* [`set_cell`](#set_cell)
* [`get_datagrid_size`](#get_datagrid_size)
* [`fill_datagrid`](#fill_datagrid)
* [`clear_datagrid`](#clear_datagrid)
* [`clone_datagrid`](#clone_datagrid)


**Movement Rules**
* [`set_movement_rules`](#set_movement_rules)
* [`get_movement_rules`](#get_movement_rules)

**Traversal & Pathfinding**
* [`find_path`](#find_path)
* [`compute_distance`](#compute_distance)
* [`extract_path`](#extract_path)
* [`extract_downhill_path`](#extract_downhill_path)

**Region Queries**
* [`compute_regions`](#compute_regions)
* [`get_region_bounds`](#get_region_bounds)
* [`find_nearest_cell`](#find_nearest_cell)
* [`count_cells`](#count_cells)

**Vision Rules**
* [`set_vision_rules`](#set_vision_rules)
* [`get_vision_rules`](#get_vision_rules)

**Visibility**
* [`compute_fov`](#compute_fov)
* [`compute_fov_cone`](#compute_fov_cone)
* [`has_line_of_sight`](#has_line_of_sight)
* [`get_sight_line`](#get_sight_line)

**Datagrid Math**
* [`add`](#add)
* [`sub`](#sub)
* [`mul`](#mul)
* [`min`](#min)
* [`max`](#max)
* [`clamp`](#clamp)
* [`threshold`](#threshold)
* [`crop`](#crop)


## Datagrids

A `Datagrid` is a fixed-size 2D array of 32-bit integers. Coordinates are zero-based. New datagrids start with all cells set to `0`.

### new_datagrid

Creates a new integer datagrid with fixed dimensions.

```lua
grid.new_datagrid(width, height) -> datagrid
```

#### Returns

- A new datagrid.

#### Error Cases

- `width <= 0`.
- `height <= 0`.

---

### new_datagrid_from_pixelmap

Creates a new datagrid from a [`Pixelmap`](raster.md) by mapping exact pixel colors to integer cell values.

This is useful for loading masks, collision maps, terrain maps, region maps, and other palette-style image data into grid form. The returned datagrid has the same dimensions as the pixelmap, and pixel coordinates map directly to datagrid coordinates.

`color_map` is a table where keys are packed `0xRRGGBBAA` colors and values are integer cell values.

If `default_value` is provided, colors not found in `color_map` are written as `default_value`. If `default_value` is omitted, unknown colors error.

```lua
grid.new_datagrid_from_pixelmap(pixelmap, color_map, default_value?) -> datagrid

--usage example
terrain = grid.new_datagrid_from_pixelmap(pmap, {
    [rgba("#000000")] = 0,
    [rgba("#FFFFFF")] = 1,
    [rgba("#3366FF")] = 2,
}, 0)
```

#### Returns

- A new datagrid with the same width and height as `pixelmap`.

#### Error Cases

- Pixelmap has been freed.
- `color_map` keys must be color integers.
- `color_map` values must be integers.
- A pixel color is not present in `color_map` and `default_value` is omitted.
- `color_map` values must fit in a datagrid cell.
- `default_value` must fit in a datagrid cell.


---

### get_cell

Returns the value stored at one cell in a datagrid. Dead datagrids and out-of-bounds reads return `nil`.

```lua
grid.get_cell(g, x, y) -> value | nil
```

#### Returns

- The cell value.
- `nil` if the datagrid has been freed.
- `nil` if the coordinates are out of bounds.

---

### set_cell

Writes one value into a datagrid cell. Dead datagrid writes and out-of-bounds writes do nothing.

```lua
grid.set_cell(g, x, y, value)
```

#### Error Cases

- `value` must fit in a datagrid cell.

---

### fill_datagrid

Overwrites every cell in a datagrid with the same value. Dead datagrid writes do nothing.

```lua
grid.fill_datagrid(g, value)
```

#### Error Cases

- `value` must fit in a datagrid cell.

---

### clear_datagrid

Sets every cell in a datagrid to `0`. Dead datagrid writes do nothing.

```lua
grid.clear_datagrid(g)
```

---

### get_datagrid_size

Returns the dimensions of a datagrid. Dead datagrids return `nil, nil`.

```lua
grid.get_datagrid_size(g) -> width, height | nil, nil
```

#### Returns

- `width, height` if the datagrid is live.
- `nil, nil` if the datagrid has been freed.

---


### clone_datagrid

Creates a full copy of a datagrid and all of its cell values.

```lua
grid.clone_datagrid(g) -> datagrid
```

#### Returns

- A new datagrid with the same dimensions and cell contents as `g`.

#### Error Cases

- Source datagrid has been freed.

## Movement Rules

Movement rules are module-wide state used by pathfinding, distance fields, path extraction, and region connectivity.

Calling `grid.set_movement_rules()` or passing `nil` resets the rules to defaults. Passing a table merges the provided fields into the current rules. Rules tables only accept the documented fields below.

```lua
rules = {
    neighbors = 4 | 8,
    cardinal_cost = integer > 0,
    diagonal_cost = integer > 0,
    corner_mode = "allow" | "no_squeeze" | "no_cut",
    allow_blocked_goal = bool,
}
```

- `neighbors` controls whether movement is 4-way or 8-way.
- `cardinal_cost` and `diagonal_cost` control step costs.
- `corner_mode` controls diagonal corner movement.
- `allow_blocked_goal` lets `find_path` resolve a blocked goal to a reachable adjacent approach cell.

### set_movement_rules

Sets the active movement rules.

```lua
grid.set_movement_rules(rules?)
```

---

### get_movement_rules

Returns the current movement rules.

```lua
grid.get_movement_rules() -> rules
```

#### Returns

- The current movement rules table.

## Traversal & Pathfinding

These functions use the current movement rules and require live datagrids.

`find_path` and `compute_distance` use a **Cost** grid.

- `0` means blocked.
- Positive numbers are the cost to enter that cell.
- Negative numbers are invalid input.

`compute_distance` can also take a **Source** grid.

- `0` means not a source.
- Any nonzero value marks a source cell.

`compute_distance` returns a **Distance** grid, which is also used by `extract_path` and `extract_downhill_path`.

- `0` means source cell.
- Positive numbers are solved distances.
- `-1` means no path.

### find_path

Finds one exact shortest-cost path from start to goal. The returned path is a flat coordinate list that excludes the start cell and includes the final reached cell.

If `allow_blocked_goal` is `true`, a blocked goal resolves to the cheapest reachable adjacent approach cell under the current movement rules.

```lua
grid.find_path(cost, sx, sy, gx, gy) -> path | nil
```

#### Returns

- A flat coordinate list on success.
- `{}` if the start already satisfies the goal.
- `nil` if no path exists.
- `nil` if the start cell is blocked.
- `nil` if the goal is blocked and `allow_blocked_goal` is `false`.
- `nil` if the goal is blocked and no valid adjacent approach cell exists.

#### Error Cases

- Start is out of bounds.
- Goal is out of bounds.
- Cost datagrid contains a negative value.

---

### compute_distance

Computes a shortest-cost distance field from one or more source cells.

```lua
grid.compute_distance(cost, x, y, dist_cap?) -> dist
grid.compute_distance(cost, {x1, y1, x2, y2, ...}, dist_cap?) -> dist
grid.compute_distance(cost, source_grid, dist_cap?) -> dist
```

#### Returns

- A new **Distance** grid.

#### Error Cases

- Cost datagrid contains a negative value.
- `dist_cap < 0`.
- Source coordinates are out of bounds.
- Source coordinates are blocked.
- Source list is empty.
- Source list does not contain flat `x, y` pairs.
- Source datagrid dimensions do not match the cost datagrid.
- Source datagrid marks a blocked cell as a source.
- Source datagrid contains no nonzero source cells.

---

### extract_path

Extracts an exact path from a **Distance** grid back to a source cell. The returned path is a flat coordinate list that excludes the start cell and includes the terminal source cell.

This verifies exact predecessor steps against both the **Distance** grid and the **Cost** grid.

```lua
grid.extract_path(cost, dist, x, y) -> path | nil
```

#### Returns

- A flat coordinate list on success.
- `{}` if the start cell already has distance `0`.
- `nil` if the start cell has no path.
- `nil` if no exact predecessor chain exists.

#### Error Cases

- Cost and distance datagrid dimensions do not match.
- Start is out of bounds.

---

### extract_downhill_path

Extracts a downhill path from a **Distance** grid back to a source cell. The returned path is a flat coordinate list that excludes the start cell and includes the terminal source cell.

This uses the current movement rules for neighbor topology only.

```lua
grid.extract_downhill_path(dist, x, y) -> path | nil
```

#### Returns

- A flat coordinate list on success.
- `{}` if the start cell already has distance `0`.
- `nil` if the start cell has no path.
- `nil` if no downhill step exists.

#### Error Cases

- Start is out of bounds.

## Region Queries

These functions provide connected-region queries and simple datagrid scans.

`compute_regions` uses the current movement rules for connectivity and takes a **Cost** grid, but only uses whether cells are blocked or passable.

- `0` means blocked or excluded.
- Positive numbers are passable.
- Negative numbers are invalid input.

`compute_regions` returns a **Region** map.

- `0` means no region.
- Positive numbers are region ids.

Region ids start at `1`.

### compute_regions

Computes connected passable regions from a **Cost** grid.

```lua
grid.compute_regions(cost) -> region_map, region_count
```

#### Returns

- `region_map`, a new **Region** map.
- `region_count`, the number of connected passable regions found.

#### Error Cases

- Cost datagrid has been freed.
- Cost datagrid contains a negative value.

---

### get_region_bounds

Returns the bounding box of one region id inside a **Region** map.

```lua
grid.get_region_bounds(region_map, region_id) -> x, y, w, h | nil
```

#### Returns

- `x, y, w, h` if the region id exists.
- `nil, nil, nil, nil` if the region map has been freed.
- `nil, nil, nil, nil` if the region id is not present.

#### Error Cases

- `region_id <= 0`.

---

### find_nearest_cell

Finds the nearest cell equal to `value` using outward square-ring search.

Search order is deterministic:
- ring `0` checks `(x, y)`
- then each larger square ring scans top row, right column, bottom row, then left column

If `radius` is omitted, the search expands until the full grid is covered.

```lua
grid.find_nearest_cell(grid, x, y, value, radius?) -> nx, ny | nil
```

#### Returns

- `nx, ny` when a matching cell is found.
- `nil, nil` if the datagrid has been freed.
- `nil, nil` if no match is found.

#### Error Cases

- Start is out of bounds.
- `radius < 0`.
- `value` must fit in a datagrid cell.

---

### count_cells

Counts how many cells equal `value`.

```lua
grid.count_cells(grid, value) -> cell_count | nil
```

#### Returns

- The number of matching cells.
- `nil` if the datagrid has been freed.

#### Error Cases
- `value` must fit in a datagrid cell.

## Vision Rules

Vision rules are module-wide state used by the visibility functions below.

Calling `grid.set_vision_rules()` or passing `nil` resets the rules to defaults. Passing a table merges the provided fields into the current rules. Rules tables only accept the documented fields below.

```lua
rules = {
    walls_visible = bool,
    diagonal_gaps = bool,
}
```

- `walls_visible` controls whether wall cells are marked visible.
- `diagonal_gaps` controls whether sight may pass through touching diagonal corners.

### set_vision_rules

Sets the active vision rules.

```lua
grid.set_vision_rules(rules?)
```

---

### get_vision_rules

Returns the current vision rules.

```lua
grid.get_vision_rules() -> rules
```

#### Returns

- The current vision rules table.

## Visibility

These functions use the current vision rules and require a live **Occlusion** grid.

They take an **Occlusion** grid as input.

- `0` means opaque.
- Any nonzero value means transparent.

`compute_fov` and `compute_fov_cone` return a **Visibility** grid.

- `0` means not visible.
- `1` means visible.

The origin cell is always marked visible.

`has_line_of_sight` and `get_sight_line` use the same occlusion and diagonal-gap rules.

### compute_fov

Computes a visibility field from one origin using symmetric shadowcasting.

```lua
grid.compute_fov(transparent, ox, oy, radius) -> visible
```

#### Returns

- A new **Visibility** grid.

#### Error Cases

- Origin is out of bounds.
- `radius < 0`.

---

### compute_fov_cone

Computes a cone-limited visibility field from one origin.

`view_dir` is in degrees:
- `0` is east
- `90` is south
- `180` is west
- `270` is north

`view_angle` defaults to `90` when omitted.

```lua
grid.compute_fov_cone(transparent, ox, oy, radius, view_dir, view_angle?) -> visible
```

#### Returns

- A new **Visibility** grid.

#### Error Cases

- Origin is out of bounds.
- `radius < 0`.
- `view_angle <= 0`.
- `view_angle > 360`.

---

### has_line_of_sight

Returns whether one cell has line of sight to another under the current vision rules.

```lua
grid.has_line_of_sight(occlusion, ax, ay, bx, by) -> bool
```

#### Error Cases

- Start is out of bounds.
- Target is out of bounds.

---

### get_sight_line

Returns the stepped sight line from start to target under the current vision rules.

```lua
grid.get_sight_line(occlusion, ax, ay, bx, by) -> line | nil
```

#### Returns

- A flat coordinate list including the start cell and target cell if line of sight succeeds.
- `nil` if line of sight fails.

#### Error Cases

- Start is out of bounds.
- Target is out of bounds.

---

### add

Returns a new datagrid with addition applied.

With two datagrids of the same size, cells are added pairwise. With a scalar value, the value is added to every cell. With `x, y`, the second datagrid is placed over the first and only the covered cells are added.

```lua
grid.add(a, b) -> grid
grid.add(a, b, x, y) -> grid
grid.add(a, value) -> grid
```

#### Error Cases

- Input datagrid is dead.
- Other datagrid is dead.
- Datagrid dimensions do not match.
- Placed datagrid is out of bounds.
- `value` must fit in a datagrid cell.

---

### sub

Returns a new datagrid with subtraction applied.

With two datagrids of the same size, cells are subtracted pairwise. With a scalar value, the value is subtracted from every cell. With `x, y`, the second datagrid is placed over the first and only the covered cells are subtracted.

```lua
grid.sub(a, b) -> grid
grid.sub(a, b, x, y) -> grid
grid.sub(a, value) -> grid
```

#### Error Cases

- Input datagrid is dead.
- Other datagrid is dead.
- Datagrid dimensions do not match.
- Placed datagrid is out of bounds.
- `value` must fit in a datagrid cell.

---

### mul

Returns a new datagrid with multiplication applied.

With two datagrids of the same size, cells are multiplied pairwise. With a scalar value, every cell is multiplied by the value. With `x, y`, the second datagrid is placed over the first and only the covered cells are multiplied.

```lua
grid.mul(a, b) -> grid
grid.mul(a, b, x, y) -> grid
grid.mul(a, value) -> grid
```

#### Error Cases

- Input datagrid is dead.
- Other datagrid is dead.
- Datagrid dimensions do not match.
- Placed datagrid is out of bounds.
- `value` must fit in a datagrid cell.

---

### min

Returns a new datagrid with the minimum value applied.

With two datagrids of the same size, the output keeps the lower value from each pair of cells. With a scalar value, every cell is capped to that value. With `x, y`, the second datagrid is placed over the first and only the covered cells are compared.

```lua
grid.min(a, b) -> grid
grid.min(a, b, x, y) -> grid
grid.min(a, value) -> grid
```

#### Error Cases

- Input datagrid is dead.
- Other datagrid is dead.
- Datagrid dimensions do not match.
- Placed datagrid is out of bounds.
- `value` must fit in a datagrid cell.

---

### max

Returns a new datagrid with the maximum value applied.

With two datagrids of the same size, the output keeps the higher value from each pair of cells. With a scalar value, every cell is raised to at least that value. With `x, y`, the second datagrid is placed over the first and only the covered cells are compared.

```lua
grid.max(a, b) -> grid
grid.max(a, b, x, y) -> grid
grid.max(a, value) -> grid
```

#### Error Cases

- Input datagrid is dead.
- Other datagrid is dead.
- Datagrid dimensions do not match.
- Placed datagrid is out of bounds.
- `value` must fit in a datagrid cell.

---

### clamp

Returns a new datagrid with every cell clamped to the given range.

```lua
grid.clamp(g, min_value, max_value) -> grid
```

#### Error Cases

- Input datagrid is dead.
- `min_value` must fit in a datagrid cell.
- `max_value` must fit in a datagrid cell.
- `min_value > max_value`.

---

### threshold

Returns a new datagrid by comparing each cell against a threshold.

Cells less than or equal to `threshold` become `low_value`. Cells greater than `threshold` become `high_value`. When `low_value` and `high_value` are omitted, they default to `0` and `1`.

```lua
grid.threshold(g, threshold) -> grid
grid.threshold(g, threshold, low_value, high_value) -> grid
```

#### Error Cases

- Input datagrid is dead.
- `threshold` must fit in a datagrid cell.
- `low_value` must fit in a datagrid cell.
- `high_value` must fit in a datagrid cell.

---

### crop

Returns a rectangular copy of one part of a datagrid.

```lua
grid.crop(g, x, y, w, h) -> grid
```

#### Error Cases

- Input datagrid is dead.
- `w <= 0`.
- `h <= 0`.
- Crop rectangle is out of bounds.