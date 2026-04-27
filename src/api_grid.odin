package main

import "base:runtime"
import "core:c"
import "core:math"
import lua "luajit"

// ============================================================================
// Grid State
// ============================================================================

// Datagrid is a dense 2D integer grid with fixed dimensions.
// Storage is flat row-major: len(cells) == width * height.
Datagrid :: struct {
    width:  int,
    height: int,
    cells:  []i32,
}

// -- Movement and Vision Rules --

GridCornerMode :: enum {
    Allow,
    No_Squeeze,
    No_Cut,
}

Active_Movement_Rules: struct {
    neighbors:          int,
    cardinal_cost:      i32,
    diagonal_cost:      i32,
    corner_mode:        GridCornerMode,
    allow_blocked_goal: bool,
} = {
    neighbors          = 8,
    cardinal_cost      = 1,
    diagonal_cost      = 1,
    corner_mode        = .No_Squeeze,
    allow_blocked_goal = false,
}

Active_Vision_Rules: struct {
    walls_visible:    bool,
    diagonal_gaps: bool, 
} = {
    walls_visible    = true,
    diagonal_gaps = true,
}

// -- Scratch Buffers --

DistanceCandidate :: struct {
    cell_idx:   int,
    total_cost: i32,
}

Dist_Compute_Buf: struct {
    visited:    [dynamic]bool,
    candidates: [dynamic]DistanceCandidate,
}

PathCandidate :: struct {
    cell_idx:      int,
    g_cost:        i32,
    h_cost:        i32,
    f_cost:        i32,
    insert_order:  int,
}

Path_Find_Buf: struct {
    closed:     [dynamic]bool,
    g_costs:    [dynamic]i32,
    parents:    [dynamic]int,
    candidates: [dynamic]PathCandidate,
}

Region_Pending_Buf: [dynamic]int

// -- FOV System Types --

FovSlope :: struct {
    num: int,
    den: int,
}

FovRow :: struct {
    origin_x:   int,
    origin_y:   int,
    quadrant:   int,
    depth:      int,
    slope_low:  FovSlope,
    slope_high: FovSlope,
}

// ============================================================================
// Traversal Helpers
// ============================================================================

// -- A* Helpers --


// push_path_candidate inserts a path candidate into the min-heap.
// Ordering is:
// 1. lowest f_cost
// 2. lowest h_cost
// 3. lowest insert_order
push_path_candidate :: proc(candidates: ^[dynamic]PathCandidate, cell_idx: int, g_cost, h_cost, f_cost: i32, insert_order: int) {
    append(candidates, PathCandidate{
        cell_idx      = cell_idx,
        g_cost        = g_cost,
        h_cost        = h_cost,
        f_cost        = f_cost,
        insert_order  = insert_order,
    })

    i := len(candidates^) - 1
    for i > 0 {
        parent := (i - 1) / 2

        parent_entry := candidates^[parent]
        child_entry := candidates^[i]

        parent_wins :=
            parent_entry.f_cost < child_entry.f_cost ||
            (parent_entry.f_cost == child_entry.f_cost && parent_entry.h_cost < child_entry.h_cost) ||
            (parent_entry.f_cost == child_entry.f_cost && parent_entry.h_cost == child_entry.h_cost && parent_entry.insert_order <= child_entry.insert_order)

        if parent_wins {
            break
        }

        candidates^[i], candidates^[parent] = candidates^[parent], candidates^[i]
        i = parent
    }
}

// pop_path_candidate removes and returns the cheapest path candidate.
pop_path_candidate :: proc(candidates: ^[dynamic]PathCandidate) -> (PathCandidate, bool) {
    if len(candidates^) == 0 {
        return PathCandidate{}, false
    }

    lowest := candidates^[0]
    last_idx := len(candidates^) - 1
    last := candidates^[last_idx]

    resize(candidates, last_idx)
    if len(candidates^) == 0 {
        return lowest, true
    }

    candidates^[0] = last

    i := 0
    for {
        left := i * 2 + 1
        if left >= len(candidates^) {
            break
        }

        smallest := left
        right := left + 1

        if right < len(candidates^) {
            left_entry := candidates^[left]
            right_entry := candidates^[right]

            right_wins :=
                right_entry.f_cost < left_entry.f_cost ||
                (right_entry.f_cost == left_entry.f_cost && right_entry.h_cost < left_entry.h_cost) ||
                (right_entry.f_cost == left_entry.f_cost && right_entry.h_cost == left_entry.h_cost && right_entry.insert_order < left_entry.insert_order)

            if right_wins {
                smallest = right
            }
        }

        current_entry := candidates^[i]
        smallest_entry := candidates^[smallest]

        current_wins :=
            current_entry.f_cost < smallest_entry.f_cost ||
            (current_entry.f_cost == smallest_entry.f_cost && current_entry.h_cost < smallest_entry.h_cost) ||
            (current_entry.f_cost == smallest_entry.f_cost && current_entry.h_cost == smallest_entry.h_cost && current_entry.insert_order <= smallest_entry.insert_order)

        if current_wins {
            break
        }

        candidates^[i], candidates^[smallest] = candidates^[smallest], candidates^[i]
        i = smallest
    }

    return lowest, true
}

// estimate_path_heuristic returns an admissible lower-bound heuristic from
// (x, y) to the nearest goal cell under the current movement rules.
estimate_path_heuristic :: proc(x, y: int, goal_x, goal_y: [8]int, goal_count: int, min_enter_cost: i32) -> i32 {
    rules := Active_Movement_Rules
    best: i32 = -1

    diagonal_unit := rules.diagonal_cost
    two_cardinals := rules.cardinal_cost * 2
    if diagonal_unit > two_cardinals {
        diagonal_unit = two_cardinals
    }

    for i in 0..<goal_count {
        dx := goal_x[i] - x
        if dx < 0 {
            dx = -dx
        }

        dy := goal_y[i] - y
        if dy < 0 {
            dy = -dy
        }

        h: i32 = 0

        if rules.neighbors == 4 {
            h = i32(dx + dy) * rules.cardinal_cost * min_enter_cost
        } else {
            diagonal_steps := dx
            if dy < diagonal_steps {
                diagonal_steps = dy
            }

            cardinal_steps := dx
            if dy > cardinal_steps {
                cardinal_steps = dy
            }
            cardinal_steps -= diagonal_steps

            h = i32(diagonal_steps) * diagonal_unit * min_enter_cost + i32(cardinal_steps) * rules.cardinal_cost * min_enter_cost
        }

        if best < 0 || h < best {
            best = h
        }
    }

    return best
}

// -- Distance Field Helpers --

// push_dist_candidate inserts a distance candidate into the min-heap.
// Lower total_cost wins.
push_dist_candidate :: proc(candidates: ^[dynamic]DistanceCandidate, cell_idx: int, total_cost: i32) {
    append(candidates, DistanceCandidate{cell_idx = cell_idx, total_cost = total_cost})

    i := len(candidates^) - 1
    for i > 0 {
        parent := (i - 1) / 2
        if candidates^[parent].total_cost <= candidates^[i].total_cost {
            break
        }

        candidates^[i], candidates^[parent] = candidates^[parent], candidates^[i]
        i = parent
    }
}

// pop_dist_candidate removes and returns the cheapest distance candidate.
pop_dist_candidate :: proc(candidates: ^[dynamic]DistanceCandidate) -> (DistanceCandidate, bool) {
    if len(candidates^) == 0 {
        return DistanceCandidate{}, false
    }

    lowest := candidates^[0]
    last_idx := len(candidates^) - 1
    last := candidates^[last_idx]

    resize(candidates, last_idx)
    if len(candidates^) == 0 {
        return lowest, true
    }

    candidates^[0] = last

    i := 0
    for {
        left := i * 2 + 1
        if left >= len(candidates^) {
            break
        }

        smallest := left
        right := left + 1
        if right < len(candidates^) && candidates^[right].total_cost < candidates^[left].total_cost {
            smallest = right
        }

        if candidates^[i].total_cost <= candidates^[smallest].total_cost {
            break
        }

        candidates^[i], candidates^[smallest] = candidates^[smallest], candidates^[i]
        i = smallest
    }

    return lowest, true
}

// -- Movement Rules Helper --

// get_step_cost returns the movement step cost from (x, y) to (nx, ny)
// under the current active movement rules.
//
// Returns 0 if the step is illegal.
//
// Notes:
// - only the destination cell must be passable
// - allow_blocked_goal is not used here
get_step_cost :: proc(cost: ^Datagrid, x, y, nx, ny: int) -> i32 {
    if !cell_in_bounds(cost, x, y) || !cell_in_bounds(cost, nx, ny) {
        return 0
    }

    dx := nx - x
    dy := ny - y

    if dx == 0 && dy == 0 {
        return 0
    }

    if dx < -1 || dx > 1 || dy < -1 || dy > 1 {
        return 0
    }

    rules := Active_Movement_Rules
    is_diagonal := dx != 0 && dy != 0

    if rules.neighbors == 4 && is_diagonal {
        return 0
    }

    if get_datagrid_cell(cost, nx, ny) <= 0 {
        return 0
    }

    if is_diagonal {
        side_ax := x + dx
        side_ay := y
        side_bx := x
        side_by := y + dy

        side_a_open := cell_in_bounds(cost, side_ax, side_ay) && get_datagrid_cell(cost, side_ax, side_ay) > 0
        side_b_open := cell_in_bounds(cost, side_bx, side_by) && get_datagrid_cell(cost, side_bx, side_by) > 0

        switch rules.corner_mode {
        case .Allow:
            // ok

        case .No_Squeeze:
            if !side_a_open && !side_b_open {
                return 0
            }

        case .No_Cut:
            if !side_a_open || !side_b_open {
                return 0
            }
        }

        return rules.diagonal_cost
    }

    return rules.cardinal_cost
}

// ============================================================================
// FOV Helpers
// ============================================================================

// scan_fov_row recursively scans one symmetric shadowcasting row for a quadrant.
// Uses the standard permissive diagonal-gap behavior.
scan_fov_row :: proc(transparent, visible: ^Datagrid, init_row: FovRow, max_depth: int) {
    row := init_row
    if row.depth > max_depth {
        return
    }

    n := 2 * row.depth * row.slope_low.num + row.slope_low.den
    d := 2 * row.slope_low.den
    column_min := n / d
    r := n % d
    if r != 0 && r < 0 {
        column_min -= 1
    }

    n = 2 * row.depth * row.slope_high.num - row.slope_high.den
    d = 2 * row.slope_high.den
    column_max := n / d
    r = n % d
    if r != 0 && r > 0 {
        column_max += 1
    }

    prev_tile_is_wall := false
    saw_any_in_bounds := false

    for column := column_min; column <= column_max; column += 1 {
        x, y: int
        switch row.quadrant {
        case 0: x, y = row.origin_x + column, row.origin_y - row.depth
        case 1: x, y = row.origin_x + row.depth, row.origin_y + column
        case 2: x, y = row.origin_x + column, row.origin_y + row.depth
        case 3: x, y = row.origin_x - row.depth, row.origin_y + column
        }

        if !cell_in_bounds(transparent, x, y) {
            continue
        }

        saw_any_in_bounds = true

        is_wall := get_datagrid_cell(transparent, x, y) == 0

        if is_wall {
            if Active_Vision_Rules.walls_visible {
                set_datagrid_cell(visible, x, y, 1)
            }
        } else if
            column * row.slope_low.den  >= row.depth * row.slope_low.num &&
            column * row.slope_high.den <= row.depth * row.slope_high.num {
            set_datagrid_cell(visible, x, y, 1)
        }

        if prev_tile_is_wall && !is_wall {
            row.slope_low = FovSlope{num = 2 * column - 1, den = 2 * row.depth}
        }

        if column != column_min && !prev_tile_is_wall && is_wall {
            next_row := row
            next_row.depth += 1
            next_row.slope_high = FovSlope{num = 2 * column - 1,den = 2 * row.depth}
            scan_fov_row(transparent, visible, next_row, max_depth)
        }

        prev_tile_is_wall = is_wall
    }

    if !saw_any_in_bounds {
        return
    }

    if !prev_tile_is_wall {
        row.depth += 1
        scan_fov_row(transparent, visible, row, max_depth)
    }
}

// scan_fov_row_diag_solid recursively scans one symmetric shadowcasting row for
// a quadrant, but treats touching diagonal corners as sight-blocking.
scan_fov_row_diag_solid :: proc(transparent, visible: ^Datagrid, init_row: FovRow, max_depth: int) {
    row := init_row
    if row.depth > max_depth {
        return
    }

    n := 2 * row.depth * row.slope_low.num + row.slope_low.den
    d := 2 * row.slope_low.den
    column_min := n / d
    r := n % d
    if r != 0 && r < 0 {
        column_min -= 1
    }

    n = 2 * row.depth * row.slope_high.num - row.slope_high.den
    d = 2 * row.slope_high.den
    column_max := n / d
    r = n % d
    if r != 0 && r > 0 {
        column_max += 1
    }

    prev_tile_blocks_visibility := false
    saw_any_in_bounds := false

    for column := column_min; column <= column_max; column += 1 {
        x, y: int
        switch row.quadrant {
        case 0: x, y = row.origin_x + column, row.origin_y - row.depth
        case 1: x, y = row.origin_x + row.depth, row.origin_y + column
        case 2: x, y = row.origin_x + column, row.origin_y + row.depth
        case 3: x, y = row.origin_x - row.depth, row.origin_y + column
        }

        if !cell_in_bounds(transparent, x, y) {
            continue
        }

        saw_any_in_bounds = true

        tile_is_wall := get_datagrid_cell(transparent, x, y) == 0
        tile_blocks_visibility := tile_is_wall

        if !tile_is_wall && column != 0 {
            sx := 1
            if column < 0 {
                sx = -1
            }

            flank_ax, flank_ay, flank_bx, flank_by: int
            switch row.quadrant {
            case 0:
                flank_ax, flank_ay = x, y + 1
                flank_bx, flank_by = x - sx, y
            case 1:
                flank_ax, flank_ay = x - 1, y
                flank_bx, flank_by = x, y - sx
            case 2:
                flank_ax, flank_ay = x, y - 1
                flank_bx, flank_by = x - sx, y
            case 3:
                flank_ax, flank_ay = x + 1, y
                flank_bx, flank_by = x, y - sx
            }

            if
                cell_in_bounds(transparent, flank_ax, flank_ay) &&
                get_datagrid_cell(transparent, flank_ax, flank_ay) == 0 &&
                cell_in_bounds(transparent, flank_bx, flank_by) &&
                get_datagrid_cell(transparent, flank_bx, flank_by) == 0 {
                tile_blocks_visibility = true
            }
        }

        if tile_is_wall {
            if Active_Vision_Rules.walls_visible {
                set_datagrid_cell(visible, x, y, 1)
            }
        } else if
            !tile_blocks_visibility &&
            column * row.slope_low.den  >= row.depth * row.slope_low.num &&
            column * row.slope_high.den <= row.depth * row.slope_high.num {
            set_datagrid_cell(visible, x, y, 1)
        }

        if prev_tile_blocks_visibility && !tile_blocks_visibility {
            row.slope_low = FovSlope{num = 2 * column - 1,den = 2 * row.depth}
        }

        if column != column_min && !prev_tile_blocks_visibility && tile_blocks_visibility {
            next_row := row
            next_row.depth += 1
            next_row.slope_high = FovSlope{num = 2 * column - 1,den = 2 * row.depth}
            scan_fov_row_diag_solid(transparent, visible, next_row, max_depth)
        }

        prev_tile_blocks_visibility = tile_blocks_visibility
    }

    if !saw_any_in_bounds {
        return
    }

    if !prev_tile_blocks_visibility {
        row.depth += 1
        scan_fov_row_diag_solid(transparent, visible, row, max_depth)
    }
}

// compute_fov_symmetric solves a visibility grid from one origin under the
// current vision rules. The origin cell is always visible.
compute_fov_symmetric :: proc(transparent: ^Datagrid, ox, oy, radius: int) -> Datagrid {
    visible := new_datagrid(transparent.width, transparent.height)
    set_datagrid_cell(&visible, ox, oy, 1)

    if radius == 0 {
        return visible
    }

    max_depth := transparent.width
    if transparent.height > max_depth {
        max_depth = transparent.height
    }
    if radius < max_depth {
        max_depth = radius
    }

    for quadrant := 0; quadrant < 4; quadrant += 1 {
        row := FovRow{
            origin_x   = ox,
            origin_y   = oy,
            quadrant   = quadrant,
            depth      = 1,
            slope_low  = FovSlope{num = -1, den = 1},
            slope_high = FovSlope{num = 1, den = 1},
        }

        if Active_Vision_Rules.diagonal_gaps {
            scan_fov_row(transparent, &visible, row, max_depth)
        } else {
            scan_fov_row_diag_solid(transparent, &visible, row, max_depth)
        }
    }

    radius_sq := radius * radius

    for y := 0; y < visible.height; y += 1 {
        for x := 0; x < visible.width; x += 1 {
            if x == ox && y == oy {
                continue
            }

            idx := cell_idx(&visible, x, y)
            if visible.cells[idx] == 0 {
                continue
            }

            dx := x - ox
            dy := y - oy
            if dx * dx + dy * dy > radius_sq {
                visible.cells[idx] = 0
            }
        }
    }

    return visible
}

// apply_fov_cone_mask masks a visibility grid to a directional cone in-place.
apply_fov_cone_mask :: proc(visible: ^Datagrid, ox, oy: int, view_dir, view_angle: f32) {
    if view_angle >= 360 {
        return
    }

    half_angle_radians := view_angle * 0.5 * f32(math.RAD_PER_DEG)
    half_angle_cos := f32(math.cos(f64(half_angle_radians)))
    
    dir_radians := view_dir * f32(math.RAD_PER_DEG)
    dir_x := f32(math.cos(f64(dir_radians)))
    dir_y := f32(math.sin(f64(dir_radians)))

    for y := 0; y < visible.height; y += 1 {
        for x := 0; x < visible.width; x += 1 {
            if x == ox && y == oy {
                continue
            }

            idx := cell_idx(visible, x, y)
            if visible.cells[idx] == 0 {
                continue
            }

            dx := f32(x - ox)
            dy := f32(y - oy)
            len_sq := dx * dx + dy * dy
            if len_sq <= 0 {
                continue
            }

            inv_len := 1.0 / f32(math.sqrt(f64(len_sq)))
            nx := dx * inv_len
            ny := dy * inv_len

            dot := nx * dir_x + ny * dir_y
            if dot < half_angle_cos {
                visible.cells[idx] = 0
            }
        }
    }
}

// ============================================================================
// Substrate Helpers
// ============================================================================

// new_datagrid allocates a zero-initialized datagrid of fixed size.
// Assumes width and height were already validated by the caller.
new_datagrid :: proc(width, height: int) -> Datagrid {
    return Datagrid{
        width  = width,
        height = height,
        cells  = make([]i32, width * height),
    }
}

// clone_datagrid duplicates a datagrid and all of its cell values.
clone_datagrid :: proc(src: ^Datagrid) -> Datagrid {
    dst := new_datagrid(src.width, src.height)
    copy(dst.cells, src.cells)
    return dst
}

// cell_in_bounds reports whether (x, y) is a valid cell coordinate.
cell_in_bounds :: proc(g: ^Datagrid, x, y: int) -> bool {
    return x >= 0 && x < g.width && y >= 0 && y < g.height
}

// cell_idx converts (x, y) cell coordinates into a flat row-major index.
// Assumes coordinates are already known-valid.
cell_idx :: proc(g: ^Datagrid, x, y: int) -> int {
    return y * g.width + x
}

// get_datagrid_cell returns the cell value at (x, y).
// Assumes coordinates are already known-valid.
get_datagrid_cell :: proc(g: ^Datagrid, x, y: int) -> i32 {
    return g.cells[cell_idx(g, x, y)]
}

// set_datagrid_cell writes value to the cell at (x, y).
// Assumes coordinates are already known-valid.
set_datagrid_cell :: proc(g: ^Datagrid, x, y: int, value: i32) {
    g.cells[cell_idx(g, x, y)] = value
}

// fill_datagrid overwrites every cell with the same value.
fill_datagrid :: proc(g: ^Datagrid, value: i32) {
    for i in 0..<len(g.cells) {
        g.cells[i] = value
    }
}

// ============================================================================
// Datagrid Lua Bindings
// ============================================================================

// -- Datagrid Basics --

// grid.new_datagrid(width, height) -> datagrid
lua_grid_new_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    width  := cast(int)lua.L_checkinteger(L, 1)
    height := cast(int)lua.L_checkinteger(L, 2)

    if width <= 0 || height <= 0 {
        lua.L_error(L, "grid.new_datagrid: width and height must be positive")
        return 0
    }

    g := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    g^ = new_datagrid(width, height)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    return 1
}

// grid.new_datagrid_from_pixelmap(pixelmap, color_map, default_value?) -> datagrid
lua_grid_new_datagrid_from_pixelmap :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    surf := (cast(^Pixelmap)lua.L_checkudata(L, 1, "Pixelmap"))^
    if surf == nil {
        lua.L_error(L, "grid.new_datagrid_from_pixelmap: pixelmap has been freed")
        return 0
    }

    lua.L_checktype(L, 2, lua.Type.TABLE)

    has_default := lua.type(L, 3) != lua.Type.NONE && lua.type(L, 3) != lua.Type.NIL
    default_value: i32
    if has_default {
        default_value = i32(lua.L_checkinteger(L, 3))
    }

    color_values := make(map[u32]i32)
    defer delete(color_values)

    lua.pushnil(L)
    for bool(lua.next(L, 2)) {
        if !bool(lua.isnumber(L, -2)) {
            lua.L_error(L, "grid.new_datagrid_from_pixelmap: color_map keys must be color integers")
            return 0
        }

        if !bool(lua.isnumber(L, -1)) {
            lua.L_error(L, "grid.new_datagrid_from_pixelmap: color_map values must be integers")
            return 0
        }

        color_key := i64(lua.tointeger(L, -2))
        if color_key < 0 || color_key > i64(max(u32)) {
            lua.L_error(L, "grid.new_datagrid_from_pixelmap: color_map keys must be color integers")
            return 0
        }

        color_values[u32(color_key)] = i32(lua.tointeger(L, -1))

        lua.pop(L, 1)
    }

    width := int(surf.w)
    height := int(surf.h)

    g := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    g^ = new_datagrid(width, height)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    pixels := cast([^]u32)surf.pixels
    stride := int(surf.pitch) / 4

    for y := 0; y < height; y += 1 {
        src_row := y * stride
        dst_row := y * width

        for x := 0; x < width; x += 1 {
            logical_color := u32_rgba_to_abgr(pixels[src_row + x])

            if value, ok := color_values[logical_color]; ok {
                g.cells[dst_row + x] = value
            } else if has_default {
                g.cells[dst_row + x] = default_value
            } else {
                lua.L_error(
                    L,
                    "grid.new_datagrid_from_pixelmap: pixel color 0x%08x has no mapped value",
                    logical_color,
                )
                return 0
            }
        }
    }

    return 1
}


// grid.get_cell(g, x, y) -> value | nil
lua_grid_get_cell :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        lua.pushnil(L)
        return 1
    }

    x := cast(int)lua.L_checkinteger(L, 2)
    y := cast(int)lua.L_checkinteger(L, 3)

    if !cell_in_bounds(g, x, y) {
        lua.pushnil(L)
        return 1
    }

    value := g.cells[cell_idx(g, x, y)]
    lua.pushinteger(L, cast(lua.Integer)value)
    return 1
}

// grid.set_cell(g, x, y, value)
lua_grid_set_cell :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        return 0
    }

    x := cast(int)lua.L_checkinteger(L, 2)
    y := cast(int)lua.L_checkinteger(L, 3)
    value := cast(i32)lua.L_checkinteger(L, 4)

    if !cell_in_bounds(g, x, y) {
        return 0
    }

    g.cells[cell_idx(g, x, y)] = value
    return 0
}

// grid.fill_datagrid(g, value)
lua_grid_fill_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        return 0
    }

    value := cast(i32)lua.L_checkinteger(L, 2)
    fill_datagrid(g, value)
    return 0
}

// grid.clear_datagrid(g)
lua_grid_clear_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        return 0
    }

    fill_datagrid(g, 0)
    return 0
}

// grid.clone_datagrid(g) -> datagrid
lua_grid_clone_datagrid :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    src := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if src == nil || src.cells == nil {
        lua.L_error(L, "grid.clone_datagrid: source datagrid has been freed")
        return 0
    }

    dst := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    dst^ = clone_datagrid(src)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    return 1
}

// -- Movement Rules --


// grid.set_movement_rules(rules?)
lua_grid_set_movement_rules :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    nargs := lua.gettop(L)
    if nargs > 1 {
        lua.L_error(L, "grid.set_movement_rules: expected 0 or 1 arguments")
        return 0
    }

    if nargs == 0 || lua.isnil(L, 1) {
        Active_Movement_Rules = {
            neighbors          = 8,
            cardinal_cost      = 1,
            diagonal_cost      = 1,
            corner_mode        = .No_Squeeze,
            allow_blocked_goal = false,
        }
        return 0
    }

    lua.L_checktype(L, 1, .TABLE)

    rules := Active_Movement_Rules

    lua.pushnil(L)
    for lua.next(L, 1) {
        if lua.type(L, -2) != .STRING {
            lua.L_error(L, "grid.set_movement_rules: table keys must be strings")
            return 0
        }

        key := lua.tostring(L, -2)

        switch string(key) {
        case "neighbors":
            value := cast(int)lua.L_checkinteger(L, -1)
            if value != 4 && value != 8 {
                lua.L_error(L, "grid.set_movement_rules: neighbors must be 4 or 8")
                return 0
            }
            rules.neighbors = value

        case "cardinal_cost":
            value := cast(i32)lua.L_checkinteger(L, -1)
            if value <= 0 {
                lua.L_error(L, "grid.set_movement_rules: cardinal_cost must be greater than 0")
                return 0
            }
            rules.cardinal_cost = value

        case "diagonal_cost":
            value := cast(i32)lua.L_checkinteger(L, -1)
            if value <= 0 {
                lua.L_error(L, "grid.set_movement_rules: diagonal_cost must be greater than 0")
                return 0
            }
            rules.diagonal_cost = value

        case "corner_mode":
            mode_name := lua.L_checkstring(L, -1)

            switch string(mode_name) {
            case "allow":
                rules.corner_mode = .Allow
            case "no_squeeze":
                rules.corner_mode = .No_Squeeze
            case "no_cut":
                rules.corner_mode = .No_Cut
            case:
                lua.L_error(
                    L,
                    "grid.set_movement_rules: corner_mode must be 'allow', 'no_squeeze', or 'no_cut'",
                )
                return 0
            }

        case "allow_blocked_goal":
            lua.L_checktype(L, -1, .BOOLEAN)
            rules.allow_blocked_goal = bool(lua.toboolean(L, -1))

        case:
            lua.L_error(L, "grid.set_movement_rules: unknown field '%s'", key)
            return 0
        }

        lua.pop(L, 1) // pop value, keep key for lua.next
    }

    Active_Movement_Rules = rules
    return 0
}

// grid.get_movement_rules() -> rules
lua_grid_get_movement_rules :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    lua.createtable(L, 0, 5)

    lua.pushinteger(L, cast(lua.Integer)Active_Movement_Rules.neighbors)
    lua.setfield(L, -2, "neighbors")

    lua.pushinteger(L, cast(lua.Integer)Active_Movement_Rules.cardinal_cost)
    lua.setfield(L, -2, "cardinal_cost")

    lua.pushinteger(L, cast(lua.Integer)Active_Movement_Rules.diagonal_cost)
    lua.setfield(L, -2, "diagonal_cost")

    switch Active_Movement_Rules.corner_mode {
    case .Allow:
        lua.pushstring(L, "allow")
    case .No_Squeeze:
        lua.pushstring(L, "no_squeeze")
    case .No_Cut:
        lua.pushstring(L, "no_cut")
    }
    lua.setfield(L, -2, "corner_mode")

    lua.pushboolean(L, b32(Active_Movement_Rules.allow_blocked_goal))
    lua.setfield(L, -2, "allow_blocked_goal")

    return 1
}

// -- Traversal and Pathfinding --


// grid.find_path(cost, sx, sy, gx, gy) -> path | nil
lua_grid_find_path :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    cost := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if cost == nil || cost.cells == nil {
        lua.L_error(L, "grid.find_path: cost datagrid has been freed")
        return 0
    }

    sx := cast(int)lua.L_checkinteger(L, 2)
    sy := cast(int)lua.L_checkinteger(L, 3)
    gx := cast(int)lua.L_checkinteger(L, 4)
    gy := cast(int)lua.L_checkinteger(L, 5)

    if !cell_in_bounds(cost, sx, sy) {
        lua.L_error(L, "grid.find_path: start (%d, %d) is out of bounds", sx, sy)
        return 0
    }

    if !cell_in_bounds(cost, gx, gy) {
        lua.L_error(L, "grid.find_path: goal (%d, %d) is out of bounds", gx, gy)
        return 0
    }

    min_enter_cost: i32 = 0
    for i in 0..<len(cost.cells) {
        value := cost.cells[i]

        if value < 0 {
            x := i % cost.width
            y := i / cost.width
            lua.L_error(L, "grid.find_path: cost datagrid contains negative value at (%d, %d)", x, y)
            return 0
        }

        if value > 0 && (min_enter_cost == 0 || value < min_enter_cost) {
            min_enter_cost = value
        }
    }

    start_idx := cell_idx(cost, sx, sy)
    if cost.cells[start_idx] <= 0 {
        lua.pushnil(L)
        return 1
    }

    
    rules := Active_Movement_Rules

    neighbor_dx := [8]int{0, 1, 0, -1, 1, 1, -1, -1}
    neighbor_dy := [8]int{-1, 0, 1, 0, -1, 1, 1, -1}
    neighbor_count := 4
    if rules.neighbors == 8 {
        neighbor_count = 8
    }

    goal_idx: [8]int
    goal_x: [8]int
    goal_y: [8]int
    goal_count := 0

    raw_goal_idx := cell_idx(cost, gx, gy)
    if cost.cells[raw_goal_idx] > 0 {
        goal_idx[goal_count] = raw_goal_idx
        goal_x[goal_count] = gx
        goal_y[goal_count] = gy
        goal_count += 1
    } else {
        if !Active_Movement_Rules.allow_blocked_goal {
            lua.pushnil(L)
            return 1
        }

        for i in 0..<neighbor_count {
            nx := gx + neighbor_dx[i]
            ny := gy + neighbor_dy[i]

            if !cell_in_bounds(cost, nx, ny) {
                continue
            }

            if get_step_cost(cost, gx, gy, nx, ny) == 0 {
                continue
            }

            neighbor_idx := cell_idx(cost, nx, ny)
            goal_idx[goal_count] = neighbor_idx
            goal_x[goal_count] = nx
            goal_y[goal_count] = ny
            goal_count += 1
        }

        if goal_count == 0 {
            lua.pushnil(L)
            return 1
        }
    }

    for i in 0..<goal_count {
        if start_idx == goal_idx[i] {
            lua.createtable(L, 0, 0)
            return 1
        }
    }

    cell_count := len(cost.cells)

    resize(&Path_Find_Buf.closed, cell_count)
    resize(&Path_Find_Buf.g_costs, cell_count)
    resize(&Path_Find_Buf.parents, cell_count)

    for i in 0..<cell_count {
        Path_Find_Buf.closed[i] = false
        Path_Find_Buf.g_costs[i] = -1
        Path_Find_Buf.parents[i] = -1
    }

    clear(&Path_Find_Buf.candidates)

    closed := Path_Find_Buf.closed
    g_costs := Path_Find_Buf.g_costs
    parents := Path_Find_Buf.parents
    candidates := &Path_Find_Buf.candidates

    start_h := estimate_path_heuristic(sx, sy, goal_x, goal_y, goal_count, min_enter_cost)
    g_costs[start_idx] = 0

    insert_order := 0
    push_path_candidate(candidates, start_idx, 0, start_h, start_h, insert_order)

    reached_goal_idx := -1

    for len(candidates^) > 0 {
        candidate, ok := pop_path_candidate(candidates)
        if !ok {
            break
        }

        if closed[candidate.cell_idx] {
            continue
        }

        if g_costs[candidate.cell_idx] != candidate.g_cost {
            continue
        }

        closed[candidate.cell_idx] = true

        for i in 0..<goal_count {
            if candidate.cell_idx == goal_idx[i] {
                reached_goal_idx = candidate.cell_idx
                break
            }
        }

        if reached_goal_idx >= 0 {
            break
        }

        x := candidate.cell_idx % cost.width
        y := candidate.cell_idx / cost.width

        for i in 0..<neighbor_count {
            nx := x + neighbor_dx[i]
            ny := y + neighbor_dy[i]

            step_cost := get_step_cost(cost, x, y, nx, ny)
            if step_cost == 0 {
                continue
            }

            neighbor_idx := cell_idx(cost, nx, ny)
            if closed[neighbor_idx] {
                continue
            }

            enter_cost := cost.cells[neighbor_idx]
            tentative_g := candidate.g_cost + step_cost * enter_cost
            if g_costs[neighbor_idx] >= 0 && tentative_g >= g_costs[neighbor_idx] {
                continue
            }

            g_costs[neighbor_idx] = tentative_g
            parents[neighbor_idx] = candidate.cell_idx

            h_cost := estimate_path_heuristic(nx, ny, goal_x, goal_y, goal_count, min_enter_cost)
            f_cost := tentative_g + h_cost

            insert_order += 1
            push_path_candidate(candidates, neighbor_idx, tentative_g, h_cost, f_cost, insert_order)
        }
    }

    if reached_goal_idx < 0 {
        lua.pushnil(L)
        return 1
    }

    path_len := 0
    trace_idx := reached_goal_idx
    for trace_idx != start_idx {
        path_len += 1
        trace_idx = parents[trace_idx]
        if trace_idx < 0 {
            lua.pushnil(L)
            return 1
        }
    }

    lua.createtable(L, i32(path_len) * 2, 0)

    write_i := path_len * 2
    trace_idx = reached_goal_idx

    for trace_idx != start_idx {
        x := trace_idx % cost.width
        y := trace_idx / cost.width

        lua.pushinteger(L, cast(lua.Integer)y)
        lua.rawseti(L, -2, i32(write_i))
        write_i -= 1

        lua.pushinteger(L, cast(lua.Integer)x)
        lua.rawseti(L, -2, i32(write_i))
        write_i -= 1

        trace_idx = parents[trace_idx]
        if trace_idx < 0 {
            lua.pop(L, 1)
            lua.pushnil(L)
            return 1
        }
    }

    return 1
}

// grid.compute_distance(cost, x, y, dist_cap?) -> dist
// grid.compute_distance(cost, {x1, y1, x2, y2, ...}, dist_cap?) -> dist
// grid.compute_distance(cost, source_grid, dist_cap?) -> dist
lua_grid_compute_distance :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    nargs := lua.gettop(L)
    if nargs < 2 || nargs > 4 {
        lua.L_error(L, "grid.compute_distance: expected (cost, x, y[, dist_cap]), (cost, {x1, y1, ...}[, dist_cap]), or (cost, source_grid[, dist_cap])")
        return 0
    }

    cost := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if cost == nil || cost.cells == nil {
        lua.L_error(L, "grid.compute_distance: cost datagrid has been freed")
        return 0
    }

    for i in 0..<len(cost.cells) {
        if cost.cells[i] < 0 {
            x := i % cost.width
            y := i / cost.width
            lua.L_error(L, "grid.compute_distance: cost datagrid contains negative value at (%d, %d)", x, y)
            return 0
        }
    }

    dist_cap_enabled := false
    dist_cap: i32 = 0

    if nargs == 4 {
        dist_cap = cast(i32)lua.L_checkinteger(L, 4)
        if dist_cap < 0 {
            lua.L_error(L, "grid.compute_distance: dist_cap must be greater than or equal to 0")
            return 0
        }
        dist_cap_enabled = true
    } else if nargs == 3 && lua.type(L, 2) != .NUMBER {
        dist_cap = cast(i32)lua.L_checkinteger(L, 3)
        if dist_cap < 0 {
            lua.L_error(L, "grid.compute_distance: dist_cap must be greater than or equal to 0")
            return 0
        }
        dist_cap_enabled = true
    }

    dist := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    dist^ = new_datagrid(cost.width, cost.height)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    fill_datagrid(dist, -1)

    cell_count := len(cost.cells)

    resize(&Dist_Compute_Buf.visited, cell_count)
    for i in 0..<cell_count {
        Dist_Compute_Buf.visited[i] = false
    }

    clear(&Dist_Compute_Buf.candidates)


    visited := Dist_Compute_Buf.visited
    candidates := &Dist_Compute_Buf.candidates

    if nargs >= 3 && lua.type(L, 2) == .NUMBER {
        sx := cast(int)lua.L_checkinteger(L, 2)
        sy := cast(int)lua.L_checkinteger(L, 3)

        if !cell_in_bounds(cost, sx, sy) {
            lua.L_error(L, "grid.compute_distance: source (%d, %d) is out of bounds", sx, sy)
            return 0
        }

        if get_datagrid_cell(cost, sx, sy) <= 0 {
            lua.L_error(L, "grid.compute_distance: source (%d, %d) is blocked", sx, sy)
            return 0
        }

        source_idx := cell_idx(cost, sx, sy)
        if dist.cells[source_idx] < 0 {
            dist.cells[source_idx] = 0
            push_dist_candidate(candidates, source_idx, 0)
        }

    } else if lua.istable(L, 2) {
        count := int(lua.objlen(L, 2))

        if count == 0 {
            lua.L_error(L, "grid.compute_distance: source list must not be empty")
            return 0
        }

        if count % 2 != 0 {
            lua.L_error(L, "grid.compute_distance: source list must contain flat x, y pairs")
            return 0
        }

        for i := 1; i <= count; i += 2 {
            lua.rawgeti(L, 2, lua.Integer(i))
            sx := cast(int)lua.L_checkinteger(L, -1)
            lua.pop(L, 1)

            lua.rawgeti(L, 2, lua.Integer(i + 1))
            sy := cast(int)lua.L_checkinteger(L, -1)
            lua.pop(L, 1)

            if !cell_in_bounds(cost, sx, sy) {
                lua.L_error(L, "grid.compute_distance: source (%d, %d) is out of bounds", sx, sy)
                return 0
            }

            if get_datagrid_cell(cost, sx, sy) <= 0 {
                lua.L_error(L, "grid.compute_distance: source (%d, %d) is blocked", sx, sy)
                return 0
            }

            source_idx := cell_idx(cost, sx, sy)
            dist.cells[source_idx] = 0
            push_dist_candidate(candidates, source_idx, 0)
        }

    } else {
        source_grid := cast(^Datagrid)lua.L_checkudata(L, 2, "Datagrid")
        if source_grid == nil || source_grid.cells == nil {
            lua.L_error(L, "grid.compute_distance: source datagrid has been freed")
            return 0
        }

        if source_grid.width != cost.width || source_grid.height != cost.height {
            lua.L_error(L, "grid.compute_distance: source datagrid dimensions must match cost datagrid")
            return 0
        }

        found_source := false

        for i in 0..<len(source_grid.cells) {
            if source_grid.cells[i] == 0 {
                continue
            }

            if cost.cells[i] <= 0 {
                x := i % cost.width
                y := i / cost.width
                lua.L_error(L, "grid.compute_distance: source datagrid marks blocked cell (%d, %d) as a source", x, y)
                return 0
            }

            dist.cells[i] = 0
            push_dist_candidate(candidates, i, 0)
            found_source = true
        }

        if !found_source {
            lua.L_error(L, "grid.compute_distance: source datagrid must contain at least one nonzero source cell")
            return 0
        }
    }

    for len(candidates^) > 0 {
        candidate, ok := pop_dist_candidate(candidates)
        if !ok {
            break
        }

        if visited[candidate.cell_idx] {
            continue
        }

        if dist.cells[candidate.cell_idx] != candidate.total_cost {
            continue
        }

        visited[candidate.cell_idx] = true

        if dist_cap_enabled && candidate.total_cost >= dist_cap {
            continue
        }

        x := candidate.cell_idx % cost.width
        y := candidate.cell_idx / cost.width

        for dy := -1; dy <= 1; dy += 1 {
            for dx := -1; dx <= 1; dx += 1 {
                if dx == 0 && dy == 0 {
                    continue
                }

                nx := x + dx
                ny := y + dy

                step_cost := get_step_cost(cost, x, y, nx, ny)
                if step_cost == 0 {
                    continue
                }

                neighbor_idx := cell_idx(cost, nx, ny)
                if visited[neighbor_idx] {
                    continue
                }

                enter_cost := cost.cells[neighbor_idx]
                next_cost := candidate.total_cost + step_cost * enter_cost

                if dist_cap_enabled && next_cost > dist_cap {
                    continue
                }

                if dist.cells[neighbor_idx] < 0 || next_cost < dist.cells[neighbor_idx] {
                    dist.cells[neighbor_idx] = next_cost
                    push_dist_candidate(candidates, neighbor_idx, next_cost)
                }
            }
        }
    }

    return 1
}

// grid.extract_path(cost, dist, x, y) -> path | nil
lua_grid_extract_path :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    cost := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if cost == nil || cost.cells == nil {
        lua.L_error(L, "grid.extract_path: cost datagrid has been freed")
        return 0
    }

    dist := cast(^Datagrid)lua.L_checkudata(L, 2, "Datagrid")
    if dist == nil || dist.cells == nil {
        lua.L_error(L, "grid.extract_path: distance datagrid has been freed")
        return 0
    }

    if cost.width != dist.width || cost.height != dist.height {
        lua.L_error(L, "grid.extract_path: cost and distance datagrid dimensions must match")
        return 0
    }

    x := cast(int)lua.L_checkinteger(L, 3)
    y := cast(int)lua.L_checkinteger(L, 4)

    if !cell_in_bounds(dist, x, y) {
        lua.L_error(L, "grid.extract_path: start (%d, %d) is out of bounds", x, y)
        return 0
    }

    start_idx := cell_idx(dist, x, y)
    start_dist := dist.cells[start_idx]

    if start_dist < 0 {
        lua.pushnil(L)
        return 1
    }

    lua.createtable(L, 0, 0)

    if start_dist == 0 {
        return 1
    }


    out_i := 1
    step_count := 0
    cell_count := len(dist.cells)

    for {
        current_idx := cell_idx(dist, x, y)
        current_dist := dist.cells[current_idx]

        if current_dist == 0 {
            break
        }

        current_enter_cost := cost.cells[current_idx]
        if current_enter_cost <= 0 {
            lua.pop(L, 1)
            lua.pushnil(L)
            return 1
        }

        best_idx := -1
        best_dist: i32 = 0
        best_is_diagonal := false

        for dy := -1; dy <= 1; dy += 1 {
            for dx := -1; dx <= 1; dx += 1 {
                if dx == 0 && dy == 0 {
                    continue
                }

                nx := x + dx
                ny := y + dy

                if !cell_in_bounds(dist, nx, ny) {
                    continue
                }

                neighbor_idx := cell_idx(dist, nx, ny)
                neighbor_dist := dist.cells[neighbor_idx]

                if neighbor_dist < 0 || neighbor_dist >= current_dist {
                    continue
                }

                step_cost := get_step_cost(cost, nx, ny, x, y)
                if step_cost == 0 {
                    continue
                }

                if neighbor_dist + step_cost * current_enter_cost != current_dist {
                    continue
                }

                is_diagonal := dx != 0 && dy != 0
                if best_idx == -1 || neighbor_dist < best_dist || (neighbor_dist == best_dist && best_is_diagonal && !is_diagonal) {
                    best_idx = neighbor_idx
                    best_dist = neighbor_dist
                    best_is_diagonal = is_diagonal
                }
            }
        }

        if best_idx == -1 {
            lua.pop(L, 1)
            lua.pushnil(L)
            return 1
        }

        x = best_idx % dist.width
        y = best_idx / dist.width

        lua.pushinteger(L, cast(lua.Integer)x)
        lua.rawseti(L, -2, i32(out_i))
        out_i += 1

        lua.pushinteger(L, cast(lua.Integer)y)
        lua.rawseti(L, -2, i32(out_i))
        out_i += 1

        step_count += 1
        if step_count > cell_count {
            lua.pop(L, 1)
            lua.pushnil(L)
            return 1
        }
    }

    return 1
}

// grid.extract_downhill_path(dist, x, y) -> path | nil
lua_grid_extract_downhill_path :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    dist := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if dist == nil || dist.cells == nil {
        lua.L_error(L, "grid.extract_downhill_path: distance datagrid has been freed")
        return 0
    }

    x := cast(int)lua.L_checkinteger(L, 2)
    y := cast(int)lua.L_checkinteger(L, 3)

    if !cell_in_bounds(dist, x, y) {
        lua.L_error(L, "grid.extract_downhill_path: start (%d, %d) is out of bounds", x, y)
        return 0
    }

    start_idx := cell_idx(dist, x, y)
    start_dist := dist.cells[start_idx]

    if start_dist < 0 {
        lua.pushnil(L)
        return 1
    }

    lua.createtable(L, 0, 0)

    if start_dist == 0 {
        return 1
    }

    rules := Active_Movement_Rules
    out_i := 1
    step_count := 0
    cell_count := len(dist.cells)

    for {
        current_idx := cell_idx(dist, x, y)
        current_dist := dist.cells[current_idx]

        if current_dist == 0 {
            break
        }

        best_idx := -1
        best_dist: i32 = 0
        best_is_diagonal := false

        for dy := -1; dy <= 1; dy += 1 {
            for dx := -1; dx <= 1; dx += 1 {
                if dx == 0 && dy == 0 {
                    continue
                }

                is_diagonal := dx != 0 && dy != 0
                if rules.neighbors == 4 && is_diagonal {
                    continue
                }

                nx := x + dx
                ny := y + dy

                if !cell_in_bounds(dist, nx, ny) {
                    continue
                }

                neighbor_idx := cell_idx(dist, nx, ny)
                neighbor_dist := dist.cells[neighbor_idx]

                if neighbor_dist < 0 || neighbor_dist >= current_dist {
                    continue
                }

                if best_idx == -1 || neighbor_dist < best_dist || (neighbor_dist == best_dist && best_is_diagonal && !is_diagonal) {
                    best_idx = neighbor_idx
                    best_dist = neighbor_dist
                    best_is_diagonal = is_diagonal
                }
            }
        }

        if best_idx == -1 {
            lua.pop(L, 1)
            lua.pushnil(L)
            return 1
        }

        x = best_idx % dist.width
        y = best_idx / dist.width

        lua.pushinteger(L, cast(lua.Integer)x)
        lua.rawseti(L, -2, i32(out_i))
        out_i += 1

        lua.pushinteger(L, cast(lua.Integer)y)
        lua.rawseti(L, -2, i32(out_i))
        out_i += 1

        step_count += 1
        if step_count > cell_count {
            lua.pop(L, 1)
            lua.pushnil(L)
            return 1
        }
    }

    return 1
}

// -- Query and Procgen --


// grid.compute_regions(cost) -> region_map, region_count
lua_grid_compute_regions :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    cost := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if cost == nil || cost.cells == nil {
        lua.L_error(L, "grid.compute_regions: cost datagrid has been freed")
        return 0
    }

    for i in 0..<len(cost.cells) {
        value := cost.cells[i]
        if value < 0 {
            x := i % cost.width
            y := i / cost.width
            lua.L_error(L, "grid.compute_regions: cost datagrid contains negative value at (%d, %d)", x, y)
            return 0
        }
    }

    region_map := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    region_map^ = new_datagrid(cost.width, cost.height)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    clear(&Region_Pending_Buf)
    pending := &Region_Pending_Buf

    region_count := 0
    cell_count := len(cost.cells)

    for start_idx in 0..<cell_count {
        if cost.cells[start_idx] <= 0 {
            continue
        }

        if region_map.cells[start_idx] != 0 {
            continue
        }

        region_count += 1
        region_id := i32(region_count)

        region_map.cells[start_idx] = region_id
        append(pending, start_idx)

        for len(pending^) > 0 {
            last_idx := len(pending^) - 1
            current_idx := pending^[last_idx]
            resize(pending, last_idx)

            x := current_idx % cost.width
            y := current_idx / cost.width

            for dy := -1; dy <= 1; dy += 1 {
                for dx := -1; dx <= 1; dx += 1 {
                    if dx == 0 && dy == 0 {
                        continue
                    }

                    nx := x + dx
                    ny := y + dy

                    if get_step_cost(cost, x, y, nx, ny) == 0 {
                        continue
                    }

                    neighbor_idx := cell_idx(cost, nx, ny)
                    if region_map.cells[neighbor_idx] != 0 {
                        continue
                    }

                    region_map.cells[neighbor_idx] = region_id
                    append(pending, neighbor_idx)
                }
            }
        }
    }

    lua.pushinteger(L, cast(lua.Integer)region_count)
    return 2
}

// grid.get_region_bounds(region_map, region_id) -> x, y, w, h | nil
lua_grid_get_region_bounds :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    region_map := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if region_map == nil || region_map.cells == nil {
        lua.pushnil(L)
        lua.pushnil(L)
        lua.pushnil(L)
        lua.pushnil(L)
        return 4
    }

    region_id := cast(i32)lua.L_checkinteger(L, 2)
    if region_id <= 0 {
        lua.L_error(L, "grid.get_region_bounds: region_id must be greater than 0")
        return 0
    }

    found := false
    min_x := 0
    min_y := 0
    max_x := 0
    max_y := 0

    for i in 0..<len(region_map.cells) {
        if region_map.cells[i] != region_id {
            continue
        }

        x := i % region_map.width
        y := i / region_map.width

        if !found {
            min_x = x
            min_y = y
            max_x = x
            max_y = y
            found = true
            continue
        }

        if x < min_x {
            min_x = x
        }
        if y < min_y {
            min_y = y
        }
        if x > max_x {
            max_x = x
        }
        if y > max_y {
            max_y = y
        }
    }

    if !found {
        lua.pushnil(L)
        lua.pushnil(L)
        lua.pushnil(L)
        lua.pushnil(L)
        return 4
    }

    lua.pushinteger(L, cast(lua.Integer)min_x)
    lua.pushinteger(L, cast(lua.Integer)min_y)
    lua.pushinteger(L, cast(lua.Integer)(max_x - min_x + 1))
    lua.pushinteger(L, cast(lua.Integer)(max_y - min_y + 1))
    return 4
}

// grid.find_nearest_cell(grid, x, y, value, radius?) -> nx, ny | nil
lua_grid_find_nearest_cell :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    nargs := lua.gettop(L)
    if nargs != 4 && nargs != 5 {
        lua.L_error(L, "grid.find_nearest_cell: expected (grid, x, y, value) or (grid, x, y, value, radius)")
        return 0
    }

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        lua.pushnil(L)
        lua.pushnil(L)
        return 2
    }

    x := cast(int)lua.L_checkinteger(L, 2)
    y := cast(int)lua.L_checkinteger(L, 3)
    value := cast(i32)lua.L_checkinteger(L, 4)

    if !cell_in_bounds(g, x, y) {
        lua.L_error(L, "grid.find_nearest_cell: start (%d, %d) is out of bounds", x, y)
        return 0
    }

    max_radius := 0

    if nargs == 5 {
        max_radius = cast(int)lua.L_checkinteger(L, 5)
        if max_radius < 0 {
            lua.L_error(L, "grid.find_nearest_cell: radius must be greater than or equal to 0")
            return 0
        }
    } else {
        max_radius = x
        if g.width - 1 - x > max_radius {
            max_radius = g.width - 1 - x
        }
        if y > max_radius {
            max_radius = y
        }
        if g.height - 1 - y > max_radius {
            max_radius = g.height - 1 - y
        }
    }

    if get_datagrid_cell(g, x, y) == value {
        lua.pushinteger(L, cast(lua.Integer)x)
        lua.pushinteger(L, cast(lua.Integer)y)
        return 2
    }

    for ring := 1; ring <= max_radius; ring += 1 {
        top := y - ring
        bottom := y + ring
        left := x - ring
        right := x + ring

        // top row
        for nx := left; nx <= right; nx += 1 {
            if cell_in_bounds(g, nx, top) && get_datagrid_cell(g, nx, top) == value {
                lua.pushinteger(L, cast(lua.Integer)nx)
                lua.pushinteger(L, cast(lua.Integer)top)
                return 2
            }
        }

        // right column
        for ny := top + 1; ny <= bottom - 1; ny += 1 {
            if cell_in_bounds(g, right, ny) && get_datagrid_cell(g, right, ny) == value {
                lua.pushinteger(L, cast(lua.Integer)right)
                lua.pushinteger(L, cast(lua.Integer)ny)
                return 2
            }
        }

        // bottom row
        if bottom != top {
            for nx := right; nx >= left; nx -= 1 {
                if cell_in_bounds(g, nx, bottom) && get_datagrid_cell(g, nx, bottom) == value {
                    lua.pushinteger(L, cast(lua.Integer)nx)
                    lua.pushinteger(L, cast(lua.Integer)bottom)
                    return 2
                }
            }
        }

        // left column
        if left != right {
            for ny := bottom - 1; ny >= top + 1; ny -= 1 {
                if cell_in_bounds(g, left, ny) && get_datagrid_cell(g, left, ny) == value {
                    lua.pushinteger(L, cast(lua.Integer)left)
                    lua.pushinteger(L, cast(lua.Integer)ny)
                    return 2
                }
            }
        }
    }

    lua.pushnil(L)
    lua.pushnil(L)
    return 2
}

// grid.count_cells(grid, value) -> cell_count | nil
lua_grid_count_cells :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        lua.pushnil(L)
        return 1
    }

    value := cast(i32)lua.L_checkinteger(L, 2)

    count := 0
    for i in 0..<len(g.cells) {
        if g.cells[i] == value {
            count += 1
        }
    }

    lua.pushinteger(L, cast(lua.Integer)count)
    return 1
}

// -- Vision Rules --


// grid.set_vision_rules(rules?)
lua_grid_set_vision_rules :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    nargs := lua.gettop(L)
    if nargs > 1 {
        lua.L_error(L, "grid.set_vision_rules: expected 0 or 1 arguments")
        return 0
    }

    if nargs == 0 || lua.isnil(L, 1) {
        Active_Vision_Rules = {
            walls_visible = true,
            diagonal_gaps = true,
        }
        return 0
    }

    lua.L_checktype(L, 1, .TABLE)

    rules := Active_Vision_Rules

    lua.pushnil(L)
    for lua.next(L, 1) {
        if lua.type(L, -2) != .STRING {
            lua.L_error(L, "grid.set_vision_rules: table keys must be strings")
            return 0
        }

        key := lua.tostring(L, -2)

        switch string(key) {
        case "walls_visible":
            lua.L_checktype(L, -1, .BOOLEAN)
            rules.walls_visible = bool(lua.toboolean(L, -1))

        case "diagonal_gaps":
            lua.L_checktype(L, -1, .BOOLEAN)
            rules.diagonal_gaps = bool(lua.toboolean(L, -1))

        case:
            lua.L_error(L, "grid.set_vision_rules: unknown field '%s'", key)
            return 0
        }

        lua.pop(L, 1)
    }

    Active_Vision_Rules = rules
    return 0
}

lua_grid_get_vision_rules :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    lua.createtable(L, 0, 2)

    lua.pushboolean(L, b32(Active_Vision_Rules.walls_visible))
    lua.setfield(L, -2, "walls_visible")

    lua.pushboolean(L, b32(Active_Vision_Rules.diagonal_gaps))
    lua.setfield(L, -2, "diagonal_gaps")

    return 1
}


// -- Vision --


// grid.compute_fov(transparent, ox, oy, radius) -> visible
lua_grid_compute_fov :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    transparent := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if transparent == nil || transparent.cells == nil {
        lua.L_error(L, "grid.compute_fov: Occlusion datagrid has been freed")
        return 0
    }

    ox := cast(int)lua.L_checkinteger(L, 2)
    oy := cast(int)lua.L_checkinteger(L, 3)
    radius := cast(int)lua.L_checkinteger(L, 4)

    if !cell_in_bounds(transparent, ox, oy) {
        lua.L_error(L, "grid.compute_fov: origin (%d, %d) is out of bounds", ox, oy)
        return 0
    }

    if radius < 0 {
        lua.L_error(L, "grid.compute_fov: radius must be greater than or equal to 0")
        return 0
    }

    visible := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    visible^ = compute_fov_symmetric(transparent, ox, oy, radius)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    return 1
}

// grid.compute_fov_cone(transparent, ox, oy, radius, view_dir, view_angle?) -> visible
lua_grid_compute_fov_cone :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    nargs := lua.gettop(L)
    if nargs != 5 && nargs != 6 {
        lua.L_error(L, "grid.compute_fov_cone: expected (transparent, ox, oy, radius, view_dir) or (transparent, ox, oy, radius, view_dir, view_angle)")
        return 0
    }

    transparent := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if transparent == nil || transparent.cells == nil {
        lua.L_error(L, "grid.compute_fov_cone: Occlusion datagrid has been freed")
        return 0
    }

    ox := cast(int)lua.L_checkinteger(L, 2)
    oy := cast(int)lua.L_checkinteger(L, 3)
    radius := cast(int)lua.L_checkinteger(L, 4)
    view_dir := f32(lua.L_checknumber(L, 5))

    view_angle := f32(90)
    if nargs == 6 {
        view_angle = f32(lua.L_checknumber(L, 6))
    }

    if !cell_in_bounds(transparent, ox, oy) {
        lua.L_error(L, "grid.compute_fov_cone: origin (%d, %d) is out of bounds", ox, oy)
        return 0
    }

    if radius < 0 {
        lua.L_error(L, "grid.compute_fov_cone: radius must be greater than or equal to 0")
        return 0
    }

    if view_angle <= 0 || view_angle > 360 {
        lua.L_error(L, "grid.compute_fov_cone: view_angle must be greater than 0 and less than or equal to 360")
        return 0
    }

    visible := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    visible^ = compute_fov_symmetric(transparent, ox, oy, radius)
    apply_fov_cone_mask(visible, ox, oy, view_dir, view_angle)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    return 1
}

// grid.has_line_of_sight(occlusion, ax, ay, bx, by) -> bool
lua_grid_has_line_of_sight :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    occlusion := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if occlusion == nil || occlusion.cells == nil {
        lua.L_error(L, "grid.has_line_of_sight: occlusion datagrid has been freed")
        return 0
    }

    ax := cast(int)lua.L_checkinteger(L, 2)
    ay := cast(int)lua.L_checkinteger(L, 3)
    bx := cast(int)lua.L_checkinteger(L, 4)
    by := cast(int)lua.L_checkinteger(L, 5)

    if !cell_in_bounds(occlusion, ax, ay) {
        lua.L_error(L, "grid.has_line_of_sight: start (%d, %d) is out of bounds", ax, ay)
        return 0
    }

    if !cell_in_bounds(occlusion, bx, by) {
        lua.L_error(L, "grid.has_line_of_sight: target (%d, %d) is out of bounds", bx, by)
        return 0
    }

    // same-cell LOS always succeeds
    if ax == bx && ay == by {
        lua.pushboolean(L, b32(true))
        return 1
    }

    x := ax
    y := ay

    dx := bx - ax
    sx := 1
    if dx < 0 {
        dx = -dx
        sx = -1
    }

    dy := by - ay
    sy := 1
    if dy < 0 {
        dy = -dy
        sy = -1
    }

    err := dx - dy

    for {
        prev_x := x
        prev_y := y

        e2 := err * 2
        stepped_x := false
        stepped_y := false

        if e2 > -dy {
            err -= dy
            x += sx
            stepped_x = true
        }

        if e2 < dx {
            err += dx
            y += sy
            stepped_y = true
        }

        // if diagonal gaps are closed, block sight through touching corners
        if !Active_Vision_Rules.diagonal_gaps && stepped_x && stepped_y {
            side_ax := prev_x + sx
            side_ay := prev_y
            side_bx := prev_x
            side_by := prev_y + sy

            side_a_blocked :=
                cell_in_bounds(occlusion, side_ax, side_ay) &&
                get_datagrid_cell(occlusion, side_ax, side_ay) == 0

            side_b_blocked :=
                cell_in_bounds(occlusion, side_bx, side_by) &&
                get_datagrid_cell(occlusion, side_bx, side_by) == 0

            if side_a_blocked && side_b_blocked {
                lua.pushboolean(L, b32(false))
                return 1
            }
        }

        // start cell does not block, but every stepped-into cell does, including target
        if get_datagrid_cell(occlusion, x, y) == 0 {
            lua.pushboolean(L, b32(false))
            return 1
        }

        if x == bx && y == by {
            lua.pushboolean(L, b32(true))
            return 1
        }
    }
}

// grid.get_sight_line(occlusion, ax, ay, bx, by) -> line | nil
lua_grid_get_sight_line :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    occlusion := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if occlusion == nil || occlusion.cells == nil {
        lua.L_error(L, "grid.get_sight_line: occlusion datagrid has been freed")
        return 0
    }

    ax := cast(int)lua.L_checkinteger(L, 2)
    ay := cast(int)lua.L_checkinteger(L, 3)
    bx := cast(int)lua.L_checkinteger(L, 4)
    by := cast(int)lua.L_checkinteger(L, 5)

    if !cell_in_bounds(occlusion, ax, ay) {
        lua.L_error(L, "grid.get_sight_line: start (%d, %d) is out of bounds", ax, ay)
        return 0
    }

    if !cell_in_bounds(occlusion, bx, by) {
        lua.L_error(L, "grid.get_sight_line: target (%d, %d) is out of bounds", bx, by)
        return 0
    }

    x := ax
    y := ay

    dx := bx - ax
    sx := 1
    if dx < 0 {
        dx = -dx
        sx = -1
    }

    dy := by - ay
    sy := 1
    if dy < 0 {
        dy = -dy
        sy = -1
    }

    steps := dx
    if dy > steps {
        steps = dy
    }

    lua.createtable(L, i32(steps + 1) * 2, 0)

    out_i := 1
    lua.pushinteger(L, cast(lua.Integer)x)
    lua.rawseti(L, -2, i32(out_i))
    out_i += 1

    lua.pushinteger(L, cast(lua.Integer)y)
    lua.rawseti(L, -2, i32(out_i))
    out_i += 1

    if x == bx && y == by {
        return 1
    }

    err := dx - dy

    for {
        prev_x := x
        prev_y := y

        e2 := err * 2
        stepped_x := false
        stepped_y := false

        if e2 > -dy {
            err -= dy
            x += sx
            stepped_x = true
        }

        if e2 < dx {
            err += dx
            y += sy
            stepped_y = true
        }

        if !Active_Vision_Rules.diagonal_gaps && stepped_x && stepped_y {
            side_ax := prev_x + sx
            side_ay := prev_y
            side_bx := prev_x
            side_by := prev_y + sy

            side_a_blocked :=
                cell_in_bounds(occlusion, side_ax, side_ay) &&
                get_datagrid_cell(occlusion, side_ax, side_ay) == 0

            side_b_blocked :=
                cell_in_bounds(occlusion, side_bx, side_by) &&
                get_datagrid_cell(occlusion, side_bx, side_by) == 0

            if side_a_blocked && side_b_blocked {
                lua.pop(L, 1)
                lua.pushnil(L)
                return 1
            }
        }

        if get_datagrid_cell(occlusion, x, y) == 0 {
            lua.pop(L, 1)
            lua.pushnil(L)
            return 1
        }

        lua.pushinteger(L, cast(lua.Integer)x)
        lua.rawseti(L, -2, i32(out_i))
        out_i += 1

        lua.pushinteger(L, cast(lua.Integer)y)
        lua.rawseti(L, -2, i32(out_i))
        out_i += 1

        if x == bx && y == by {
            return 1
        }
    }
}

// -- Datagrid Math Ops --

// grid.add(a, b) -> grid
// grid.add(a, value) -> grid
lua_grid_add :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    a := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if a == nil || a.cells == nil {
        lua.L_error(L, "grid.add: input datagrid has been freed")
        return 0
    }

    out := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    out^ = new_datagrid(a.width, a.height)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    if lua.type(L, 2) == .NUMBER {
        value := cast(i32)lua.L_checkinteger(L, 2)

        for i in 0..<len(a.cells) {
            out.cells[i] = a.cells[i] + value
        }

        return 1
    }

    b := cast(^Datagrid)lua.L_checkudata(L, 2, "Datagrid")
    if b == nil || b.cells == nil {
        lua.L_error(L, "grid.add: other datagrid has been freed")
        return 0
    }

    if b.width != a.width || b.height != a.height {
        lua.L_error(L, "grid.add: datagrid dimensions must match")
        return 0
    }

    for i in 0..<len(a.cells) {
        out.cells[i] = a.cells[i] + b.cells[i]
    }

    return 1
}

// grid.min(a, b) -> grid
// grid.min(a, value) -> grid
lua_grid_min :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    a := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if a == nil || a.cells == nil {
        lua.L_error(L, "grid.min: input datagrid has been freed")
        return 0
    }

    out := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    out^ = new_datagrid(a.width, a.height)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    if lua.type(L, 2) == .NUMBER {
        value := cast(i32)lua.L_checkinteger(L, 2)

        for i in 0..<len(a.cells) {
            cell := a.cells[i]
            if cell < value {
                out.cells[i] = cell
            } else {
                out.cells[i] = value
            }
        }

        return 1
    }

    b := cast(^Datagrid)lua.L_checkudata(L, 2, "Datagrid")
    if b == nil || b.cells == nil {
        lua.L_error(L, "grid.min: other datagrid has been freed")
        return 0
    }

    if b.width != a.width || b.height != a.height {
        lua.L_error(L, "grid.min: datagrid dimensions must match")
        return 0
    }

    for i in 0..<len(a.cells) {
        av := a.cells[i]
        bv := b.cells[i]

        if av < bv {
            out.cells[i] = av
        } else {
            out.cells[i] = bv
        }
    }

    return 1
}

// grid.max(a, b) -> grid
// grid.max(a, value) -> grid
lua_grid_max :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    a := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if a == nil || a.cells == nil {
        lua.L_error(L, "grid.max: input datagrid has been freed")
        return 0
    }

    out := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    out^ = new_datagrid(a.width, a.height)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    if lua.type(L, 2) == .NUMBER {
        value := cast(i32)lua.L_checkinteger(L, 2)

        for i in 0..<len(a.cells) {
            cell := a.cells[i]
            if cell > value {
                out.cells[i] = cell
            } else {
                out.cells[i] = value
            }
        }

        return 1
    }

    b := cast(^Datagrid)lua.L_checkudata(L, 2, "Datagrid")
    if b == nil || b.cells == nil {
        lua.L_error(L, "grid.max: other datagrid has been freed")
        return 0
    }

    if b.width != a.width || b.height != a.height {
        lua.L_error(L, "grid.max: datagrid dimensions must match")
        return 0
    }

    for i in 0..<len(a.cells) {
        av := a.cells[i]
        bv := b.cells[i]

        if av > bv {
            out.cells[i] = av
        } else {
            out.cells[i] = bv
        }
    }

    return 1
}

// grid.clamp(g, min_value, max_value) -> grid
lua_grid_clamp :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        lua.L_error(L, "grid.clamp: input datagrid has been freed")
        return 0
    }

    min_value := cast(i32)lua.L_checkinteger(L, 2)
    max_value := cast(i32)lua.L_checkinteger(L, 3)

    if min_value > max_value {
        lua.L_error(L, "grid.clamp: min_value must be less than or equal to max_value")
        return 0
    }

    out := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    out^ = new_datagrid(g.width, g.height)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    for i in 0..<len(g.cells) {
        value := g.cells[i]

        if value < min_value {
            out.cells[i] = min_value
        } else if value > max_value {
            out.cells[i] = max_value
        } else {
            out.cells[i] = value
        }
    }

    return 1
}

// grid.crop(g, x, y, w, h) -> grid
lua_grid_crop :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g == nil || g.cells == nil {
        lua.L_error(L, "grid.crop: input datagrid has been freed")
        return 0
    }

    x := cast(int)lua.L_checkinteger(L, 2)
    y := cast(int)lua.L_checkinteger(L, 3)
    w := cast(int)lua.L_checkinteger(L, 4)
    h := cast(int)lua.L_checkinteger(L, 5)

    if w <= 0 || h <= 0 {
        lua.L_error(L, "grid.crop: width and height must be positive")
        return 0
    }

    if x < 0 || y < 0 || x + w > g.width || y + h > g.height {
        lua.L_error(L, "grid.crop: crop rectangle is out of bounds")
        return 0
    }

    out := cast(^Datagrid)lua.newuserdata(L, size_of(Datagrid))
    out^ = new_datagrid(w, h)

    lua.L_getmetatable(L, "Datagrid")
    lua.setmetatable(L, -2)

    for py := 0; py < h; py += 1 {
        src_row := (y + py) * g.width + x
        dst_row := py * w
        copy(out.cells[dst_row:dst_row+w], g.cells[src_row:src_row+w])
    }

    return 1
}

// ============================================================================
// Datagrid Lua GC And Metatable
// ============================================================================

// lua_datagrid_gc releases a Datagrid's backing storage when Lua collects it.
lua_datagrid_gc :: proc "c" (L: ^lua.State) -> c.int {
    context = runtime.default_context()

    g := cast(^Datagrid)lua.L_checkudata(L, 1, "Datagrid")
    if g != nil && g.cells != nil {
        delete(g.cells)
        g.cells = nil
        g.width = 0
        g.height = 0
    }

    return 0
}

// setup_grid_metatables registers the Datagrid userdata metatable.
setup_grid_metatables :: proc() {
    lua.L_newmetatable(Lua, "Datagrid")
    lua.pushcfunction(Lua, lua_datagrid_gc)
    lua.setfield(Lua, -2, "__gc")
    lua.pop(Lua, 1)
}
// ============================================================================
// Lua Registration
// ============================================================================

register_grid_api :: proc() {
    setup_grid_metatables()

    lua.newtable(Lua) // [grid]

    // -- Datagrid Basics --
    lua_bind_function(lua_grid_new_datagrid,  "new_datagrid")
    lua_bind_function(lua_grid_new_datagrid_from_pixelmap, "new_datagrid_from_pixelmap")
    lua_bind_function(lua_grid_get_cell,      "get_cell")
    lua_bind_function(lua_grid_set_cell,      "set_cell")
    lua_bind_function(lua_grid_fill_datagrid, "fill_datagrid")
    lua_bind_function(lua_grid_clear_datagrid,"clear_datagrid")
    lua_bind_function(lua_grid_clone_datagrid,"clone_datagrid")

    // -- Movement Rules --
    lua_bind_function(lua_grid_set_movement_rules, "set_movement_rules")
    lua_bind_function(lua_grid_get_movement_rules, "get_movement_rules")

    // -- Traversal and Pathfinding --
    lua_bind_function(lua_grid_find_path,             "find_path")
    lua_bind_function(lua_grid_compute_distance,      "compute_distance")
    lua_bind_function(lua_grid_extract_path,          "extract_path")
    lua_bind_function(lua_grid_extract_downhill_path, "extract_downhill_path")

    // -- Query and Procgen --
    lua_bind_function(lua_grid_compute_regions,   "compute_regions")
    lua_bind_function(lua_grid_get_region_bounds, "get_region_bounds")
    lua_bind_function(lua_grid_find_nearest_cell, "find_nearest_cell")
    lua_bind_function(lua_grid_count_cells,       "count_cells")

    // -- Vision Rules --
    lua_bind_function(lua_grid_set_vision_rules, "set_vision_rules")
    lua_bind_function(lua_grid_get_vision_rules, "get_vision_rules")

    // -- Vision --
    lua_bind_function(lua_grid_compute_fov,      "compute_fov")
    lua_bind_function(lua_grid_compute_fov_cone, "compute_fov_cone")
    lua_bind_function(lua_grid_has_line_of_sight,"has_line_of_sight")
    lua_bind_function(lua_grid_get_sight_line, "get_sight_line")

    // -- Datagrid Math Ops --
    lua_bind_function(lua_grid_add,   "add")
    lua_bind_function(lua_grid_min,   "min")
    lua_bind_function(lua_grid_max,   "max")
    lua_bind_function(lua_grid_clamp, "clamp")
    lua_bind_function(lua_grid_crop,  "crop")

    lua.setglobal(Lua, "grid")
}






