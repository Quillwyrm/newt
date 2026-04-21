package main

import "base:runtime"
import "core:c"
import lua "luajit"


// grid.compute_regions(cost) -> region_map, region_count
// -- dead source loud

// grid.find_nearest_cell(grid, x, y, value, radius?) -> nx, ny | nil
// -- dead grid nil, no match nil, bad setup loud

// grid.count_cells(grid, value) -> cell_count | nil
// -- dead grid nil, no matches 0

// grid.get_region_bounds(region_map, region_id) -> x, y, w, h | nil
// -- dead map nil, missing region nil, region_id <= 0 loud

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

        tmp := candidates^[i]
        candidates^[i] = candidates^[parent]
        candidates^[parent] = tmp
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

    _ = resize(candidates, last_idx)
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

        tmp := candidates^[i]
        candidates^[i] = candidates^[smallest]
        candidates^[smallest] = tmp
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

// push_dist_candidate inserts a candidate cell into the min-heap.
push_dist_candidate :: proc(candidates: ^[dynamic]DistanceCandidate, cell_idx: int, total_cost: i32) {
    append(candidates, DistanceCandidate{cell_idx = cell_idx, total_cost = total_cost})

    i := len(candidates^) - 1
    for i > 0 {
        parent := (i - 1) / 2
        if candidates^[parent].total_cost <= candidates^[i].total_cost {
            break
        }

        tmp := candidates^[i]
        candidates^[i] = candidates^[parent]
        candidates^[parent] = tmp
        i = parent
    }
}

// pop_dist_candidate removes and returns the cheapest candidate cell.
pop_dist_candidate :: proc(candidates: ^[dynamic]DistanceCandidate) -> (DistanceCandidate, bool) {
    if len(candidates^) == 0 {
        return DistanceCandidate{}, false
    }

    lowest := candidates^[0]
    last_idx := len(candidates^) - 1
    last := candidates^[last_idx]

    _ = resize(candidates, last_idx)
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

        tmp := candidates^[i]
        candidates^[i] = candidates^[smallest]
        candidates^[smallest] = tmp
        i = smallest
    }

    return lowest, true
}

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

    for i in 0..<len(src.cells) {
        dst.cells[i] = src.cells[i]
    }

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

// grid.new_datagrid(w, h) -> datagrid
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

// grid.get_cell(g, x, y) -> value | nil
// Returns nil if the datagrid has been freed.
// Returns nil for out-of-bounds reads.
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
// Dead datagrid writes are no-ops.
// Out-of-bounds writes are no-ops.
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
// Filling a freed datagrid is a no-op.
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
// Clearing a freed datagrid is a no-op.
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

// -- Pathfinding and Traversal --


// grid.set_movement_rules()
// grid.set_movement_rules(nil)
// grid.set_movement_rules(rules)
//
// Sets the active movement rules used by grid traversal/path solves.
//
// Accepted table fields:
// - neighbors           = 4 | 8
// - cardinal_cost       = integer > 0
// - diagonal_cost       = integer > 0
// - corner_mode         = "allow" | "no_squeeze" | "no_cut"
// - allow_blocked_goal  = boolean
//
// Behavior:
// - no args resets to defaults
// - nil resets to defaults
// - table input merges into the current active rules
// - unknown fields throw
// - wrong types or invalid values throw
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

// ----------------------------------------------------------------------------
// grid.get_movement_rules() -> rules
//
// Returns the current active module-wide movement rules as a Lua table.
//
// Returned fields:
// - neighbors
// - cardinal_cost
// - diagonal_cost
// - corner_mode
// - allow_blocked_goal
// ----------------------------------------------------------------------------
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

// ----------------------------------------------------------------------------
// grid.find_path(cost, sx, sy, gx, gy) -> path | nil
//
// Finds one exact shortest-cost path from start to goal under the current
// active movement rules.
//
// Cost grid semantics:
// - 0   = blocked
// - > 0 = cost to enter that cell
// - < 0 = invalid input
//
// Path semantics:
// - returns flat coordinates {x1, y1, x2, y2, ...}
// - excludes the start cell
// - includes the final reached cell
// - returns {} if the start already satisfies the goal
// - returns nil if no path exists
//
// Goal semantics:
// - if allow_blocked_goal is false, a blocked goal returns nil
// - if allow_blocked_goal is true, a blocked goal resolves to the cheapest
//   reachable adjacent approach cell under the current movement rules
// ----------------------------------------------------------------------------
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

        for dy := -1; dy <= 1; dy += 1 {
            for dx := -1; dx <= 1; dx += 1 {
                if dx == 0 && dy == 0 {
                    continue
                }

                nx := gx + dx
                ny := gy + dy

                if get_step_cost(cost, gx, gy, nx, ny) == 0 {
                    continue
                }

                neighbor_idx := cell_idx(cost, nx, ny)
                goal_idx[goal_count] = neighbor_idx
                goal_x[goal_count] = nx
                goal_y[goal_count] = ny
                goal_count += 1
            }
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

    _ = resize(&Path_Find_Buf.closed, cell_count)
    _ = resize(&Path_Find_Buf.g_costs, cell_count)
    _ = resize(&Path_Find_Buf.parents, cell_count)

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

    neighbor_dx := [8]int{0, 1, 0, -1, 1, 1, -1, -1}
    neighbor_dy := [8]int{-1, 0, 1, 0, -1, 1, 1, -1}
    neighbor_count := 4
    if rules.neighbors == 8 {
        neighbor_count = 8
    }

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

        is_goal := false
        for i in 0..<goal_count {
            if candidate.cell_idx == goal_idx[i] {
                is_goal = true
                break
            }
        }

        if is_goal {
            reached_goal_idx = candidate.cell_idx
            break
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

// ----------------------------------------------------------------------------

// grid.compute_distance(cost, x, y, dist_cap?) -> dist
// grid.compute_distance(cost, {x1, y1, x2, y2, ...}, dist_cap?) -> dist
// grid.compute_distance(cost, source_grid, dist_cap?) -> dist
//
// Computes a shortest-cost distance field from one or more source cells.
//
// Uses the current active movement rules.
//
// Cost grid semantics:
// - 0   = blocked
// - > 0 = cost to enter that cell
// - < 0 = invalid input
//
// Distance grid semantics:
// - source cells = 0
// - reachable    = accumulated total cost
// - no path      = -1
//
// Source forms:
// - x, y
// - flat coordinate list table {x1, y1, x2, y2, ...}
// - source datagrid where every nonzero cell is a source
//
// Notes:
// - blocked cells, unreachable open cells, and over-cap cells all appear as -1
// ----------------------------------------------------------------------------
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

    _ = resize(&Dist_Compute_Buf.visited, cell_count)
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
        dist.cells[source_idx] = 0
        push_dist_candidate(candidates, source_idx, 0)

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

// ----------------------------------------------------------------------------
// grid.extract_path(cost, dist, x, y) -> path | nil
//
// Extracts an exact path from a solved weighted distance field back to a
// zero-cost source cell.
//
// Uses the current active movement rules.
//
// Cost grid semantics:
// - 0   = blocked
// - > 0 = cost to enter that cell
//
// Distance grid semantics:
// - 0   = source cell
// - > 0 = accumulated total cost
// - -1  = no path
//
// Path semantics:
// - returns flat coordinates {x1, y1, x2, y2, ...}
// - excludes the start cell
// - includes the terminal source cell
// - returns {} if the start cell already has distance 0
// - returns nil if the start cell has no path or no exact predecessor exists
// ----------------------------------------------------------------------------
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

// ----------------------------------------------------------------------------
// grid.extract_downhill_path(dist, x, y) -> path | nil
//
// Extracts a downhill path from a solved distance field back to a zero-cost
// source cell.
//
// Uses the current active movement rules for neighbor topology only.
//
// Distance grid semantics:
// - 0   = source cell
// - > 0 = accumulated total cost
// - -1  = no path
//
// Path semantics:
// - returns flat coordinates {x1, y1, x2, y2, ...}
// - excludes the start cell
// - includes the terminal source cell
// - returns {} if the start cell already has distance 0
// - returns nil if the start cell has no path or no downhill step exists
// ----------------------------------------------------------------------------
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

// ----------------------------------------------------------------------------
// grid.compute_regions(cost) -> region_map, region_count
//
// Computes connected passable regions from a cost datagrid.
//
// Uses the current active movement rules for connectivity.
//
// Cost grid semantics:
// - 0   = blocked / excluded
// - > 0 = passable / participates
// - < 0 = invalid input
//
// Region map semantics:
// - 0   = blocked / no region
// - > 0 = region id
//
// Notes:
// - region ids are assigned in scan order starting from 1
// - dead source datagrid is loud
// ----------------------------------------------------------------------------
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
            _ = resize(pending, last_idx)

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

    lua_bind_function(lua_grid_new_datagrid,          "new_datagrid")
    lua_bind_function(lua_grid_get_cell,              "get_cell")
    lua_bind_function(lua_grid_set_cell,              "set_cell")
    lua_bind_function(lua_grid_fill_datagrid,         "fill_datagrid")
    lua_bind_function(lua_grid_clear_datagrid,        "clear_datagrid")
    lua_bind_function(lua_grid_clone_datagrid,        "clone_datagrid")
    lua_bind_function(lua_grid_set_movement_rules,    "set_movement_rules")
    lua_bind_function(lua_grid_get_movement_rules,    "get_movement_rules")
    lua_bind_function(lua_grid_find_path,             "find_path")
    lua_bind_function(lua_grid_compute_distance,      "compute_distance")
    lua_bind_function(lua_grid_extract_path,          "extract_path")
    lua_bind_function(lua_grid_extract_downhill_path, "extract_downhill_path")
    lua_bind_function(lua_grid_compute_regions,       "compute_regions")

    lua.setglobal(Lua, "grid")
}