-- =============================================================================
-- GRID PATHFINDING VISUAL TEST
-- =============================================================================
-- ASCII_MAP:
--   0 = blocked
--   1..9 = direct enter-cost
--
-- Controls:
--   Arrows  = move source (green)
--   Numpad  = move target (red)
--   LMB     = move A* goal (white), including onto blocked cells
--   1       = 4-way uniform
--   2       = 8-way uniform
--   3       = 8-way diagonal expensive
--   Z       = corner mode allow
--   X       = corner mode no_squeeze
--   C       = corner mode no_cut
--   TAB     = toggle terrain / distance view
--   R       = rebuild map + reset markers
-- =============================================================================

local ASCII_MAP = {
    "000000000000000000000000000000",
    "011111111111111111110111111110",
    "011111111111111111110111111110",
    "011111111111111111110011111110",
    "011111111001111111000111111110",
    "011000001001111111000100011110",
    "011111111001111101000111111110",
    "011111111101111110110111111110",
    "011111111011111011111111111110",
    "011111111001111111100111111110",
    "011111111001000001100111111110",
    "011111111001111111100111111110",
    "011444444444222222211555555110",
    "011444444444222222211555555110",
    "011444444444222222211555555110",
    "011111111111111111111111111110",
    "000000000000000000000000000000",
}

local GRID_H = #ASCII_MAP
local GRID_W = #ASCII_MAP[1]

local CELL = 24
local OFFSET_X = 20
local OFFSET_Y = 92

local source_x = 4
local source_y = 8

local target_x = 25
local target_y = 8

local agent_x = 6
local agent_y = 13
local agent_goal_x = 6
local agent_goal_y = 13

local source_move_timer = 0
local target_move_timer = 0
local agent_move_timer = 0

local move_repeat = 0.11
local agent_step_time = 0.09

local view_mode = "distance" -- "distance" | "terrain"
local rule_preset = 3        -- 1 = 4-way uniform, 2 = 8-way uniform, 3 = 8-way diag expensive
local corner_mode = "no_squeeze"

local cost = nil

local prev_down = {}
local just_pressed = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function inv_lerp(a, b, v)
    if a == b then return 0 end
    return clamp((v - a) / (b - a), 0, 1)
end

local function cell_to_screen(x, y)
    return OFFSET_X + x * CELL, OFFSET_Y + y * CELL
end

local function cell_center(x, y)
    local sx, sy = cell_to_screen(x, y)
    return sx + CELL * 0.5, sy + CELL * 0.5
end

local function screen_to_cell(mx, my)
    local x = math.floor((mx - OFFSET_X) / CELL)
    local y = math.floor((my - OFFSET_Y) / CELL)
    return x, y
end

local function validate_ascii_map()
    if #ASCII_MAP == 0 then
        error("ASCII_MAP must not be empty")
    end

    local w = #ASCII_MAP[1]

    for y = 1, #ASCII_MAP do
        local row = ASCII_MAP[y]

        if #row ~= w then
            error("ASCII_MAP rows must all have the same width")
        end

        for x = 1, #row do
            local ch = string.sub(row, x, x)
            local v = tonumber(ch)

            if v == nil or v < 0 or v > 9 then
                error("ASCII_MAP must contain only digits 0..9")
            end
        end
    end
end

local function update_key_edges()
    local keys = { "1", "2", "3", "z", "x", "c", "r", "tab" }

    for i = 1, #keys do
        local key = keys[i]
        local down = input.down(key)
        just_pressed[key] = down and not prev_down[key]
        prev_down[key] = down
    end
end

local function pressed(key)
    return just_pressed[key]
end

local function apply_rules()
    local neighbors = 8
    local diagonal_cost = 1

    if rule_preset == 1 then
        neighbors = 4
        diagonal_cost = 1
    elseif rule_preset == 2 then
        neighbors = 8
        diagonal_cost = 1
    else
        neighbors = 8
        diagonal_cost = 2
    end

    grid.set_movement_rules({
        neighbors = neighbors,
        cardinal_cost = 1,
        diagonal_cost = diagonal_cost,
        corner_mode = corner_mode,
        allow_blocked_goal = true,
    })
end

local function build_test_map()
    validate_ascii_map()

    cost = grid.new_datagrid(GRID_W, GRID_H)

    for y = 0, GRID_H - 1 do
        local row = ASCII_MAP[y + 1]

        for x = 0, GRID_W - 1 do
            local ch = string.sub(row, x + 1, x + 1)
            local v = tonumber(ch)
            grid.set_cell(cost, x, y, v)
        end
    end

    source_x = 4
    source_y = 8

    target_x = 25
    target_y = 8

    agent_x = 6
    agent_y = 13
    agent_goal_x = 6
    agent_goal_y = 13
end

local function can_step(x, y, nx, ny)
    if nx < 0 or nx >= GRID_W or ny < 0 or ny >= GRID_H then
        return false
    end

    local v = grid.get_cell(cost, nx, ny)
    if not v or v <= 0 then
        return false
    end

    local dx = nx - x
    local dy = ny - y
    local is_diagonal = dx ~= 0 and dy ~= 0

    if is_diagonal and rule_preset == 1 then
        return false
    end

    if not is_diagonal then
        return true
    end

    local va = grid.get_cell(cost, x + dx, y)
    local vb = grid.get_cell(cost, x, y + dy)
    local side_a_open = va and va > 0
    local side_b_open = vb and vb > 0

    if corner_mode == "allow" then
        return true
    elseif corner_mode == "no_squeeze" then
        return side_a_open or side_b_open
    else
        return side_a_open and side_b_open
    end
end

local function try_move_source(dx, dy)
    local nx = clamp(source_x + dx, 0, GRID_W - 1)
    local ny = clamp(source_y + dy, 0, GRID_H - 1)

    if can_step(source_x, source_y, nx, ny) then
        source_x = nx
        source_y = ny
    end
end

local function try_move_target(dx, dy)
    local nx = clamp(target_x + dx, 0, GRID_W - 1)
    local ny = clamp(target_y + dy, 0, GRID_H - 1)

    if can_step(target_x, target_y, nx, ny) then
        target_x = nx
        target_y = ny
    end
end

local function path_equal(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    if #a ~= #b then return false end

    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end

    return true
end

local function terrain_color(v)
    if v <= 0 then
        return rgba(8, 8, 10)
    end

    local t = clamp((v - 1) / 8, 0, 1)
    local r = math.floor(lerp(78, 250, t))
    local g = math.floor(lerp(82, 62, t))
    local b = math.floor(lerp(90, 52, t))
    return rgba(r, g, b)
end

local function distance_color(cost_v, dist_v, max_dist)
    if not dist_v or dist_v < 0 then
        if cost_v == 0 then
            return rgba(4, 4, 6)
        end
        return rgba(18, 18, 22)
    end

    local t = dist_v / max_dist

    if t < 0.20 then
        local u = inv_lerp(0.00, 0.20, t)
        local r = math.floor(lerp(20, 30, u))
        local g = math.floor(lerp(40, 255, u))
        local b = math.floor(lerp(110, 255, u))
        return rgba(r, g, b, 90)
    elseif t < 0.50 then
        local u = inv_lerp(0.20, 0.50, t)
        local r = math.floor(lerp(30, 255, u))
        local g = math.floor(lerp(255, 245, u))
        local b = math.floor(lerp(255, 60, u))
        return rgba(r, g, b, 90)
    else
        local u = inv_lerp(0.50, 1.00, t)
        local r = math.floor(lerp(255, 255, u))
        local g = math.floor(lerp(245, 40, u))
        local b = math.floor(lerp(60, 30, u))
        return rgba(r, g, b, 90)
    end
end

local function draw_grid(dist)
    local max_dist = 0

    if dist then
        for y = 0, GRID_H - 1 do
            for x = 0, GRID_W - 1 do
                local d = grid.get_cell(dist, x, y)
                if d and d > max_dist then
                    max_dist = d
                end
            end
        end
    end

    if max_dist <= 0 then
        max_dist = 1
    end

    for y = 0, GRID_H - 1 do
        for x = 0, GRID_W - 1 do
            local cost_v = grid.get_cell(cost, x, y) or 0
            local dist_v = dist and grid.get_cell(dist, x, y) or nil
            local sx, sy = cell_to_screen(x, y)

            local fill = nil
            if view_mode == "terrain" then
                fill = terrain_color(cost_v)
            else
                fill = distance_color(cost_v, dist_v, max_dist)
            end

            graphics.draw_rect(sx, sy, CELL - 1, CELL - 1, fill)
        end
    end
end

local function draw_path_lines(path, start_x, start_y, color)
    if not path or #path < 2 then
        return
    end

    local px = start_x
    local py = start_y

    for i = 1, #path, 2 do
        local nx = path[i]
        local ny = path[i + 1]

        local x1, y1 = cell_center(px, py)
        local x2, y2 = cell_center(nx, ny)
        graphics.debug_line(x1, y1, x2, y2, color)

        px = nx
        py = ny
    end
end

local function draw_markers()
    local size = CELL - 10

    do
        local sx, sy = cell_to_screen(source_x, source_y)
        graphics.draw_rect(sx + 5, sy + 5, size, size, rgba(50, 240, 70))
    end

    do
        local sx, sy = cell_to_screen(target_x, target_y)
        graphics.draw_rect(sx + 5, sy + 5, size, size, rgba(240, 50, 50))
    end

    do
        local sx, sy = cell_to_screen(agent_x, agent_y)
        graphics.draw_rect(sx + 8, sy + 8, CELL - 16, CELL - 16, rgba(255, 210, 70))
    end

    do
        local sx, sy = cell_to_screen(agent_goal_x, agent_goal_y)
        graphics.draw_rect(sx + 10, sy + 10, CELL - 20, CELL - 20, rgba(255, 255, 255))
    end
end

local function preset_name()
    if rule_preset == 1 then return "4-way uniform" end
    if rule_preset == 2 then return "8-way uniform" end
    return "8-way diagonal expensive"
end

runtime.init = function()
    window.set_title("Newt Grid Visual Test")
    build_test_map()
    apply_rules()
end

runtime.update = function(dt)
    update_key_edges()

    if pressed("1") then
        rule_preset = 1
        apply_rules()
    end

    if pressed("2") then
        rule_preset = 2
        apply_rules()
    end

    if pressed("3") then
        rule_preset = 3
        apply_rules()
    end

    if pressed("z") then
        corner_mode = "allow"
        apply_rules()
    end

    if pressed("x") then
        corner_mode = "no_squeeze"
        apply_rules()
    end

    if pressed("c") then
        corner_mode = "no_cut"
        apply_rules()
    end

    if pressed("tab") then
        if view_mode == "terrain" then
            view_mode = "distance"
        else
            view_mode = "terrain"
        end
    end

    if pressed("r") then
        build_test_map()
        apply_rules()
    end

    if input.pressed("mouse1") then
        local mx, my = input.get_mouse_position()
        local gx, gy = screen_to_cell(mx, my)

        if gx >= 0 and gx < GRID_W and gy >= 0 and gy < GRID_H then
            agent_goal_x = gx
            agent_goal_y = gy
        end
    end

    source_move_timer = source_move_timer - dt
    target_move_timer = target_move_timer - dt
    agent_move_timer = agent_move_timer - dt

    if source_move_timer <= 0 then
        if input.down("left") then
            try_move_source(-1, 0)
            source_move_timer = move_repeat
        elseif input.down("right") then
            try_move_source(1, 0)
            source_move_timer = move_repeat
        elseif input.down("up") then
            try_move_source(0, -1)
            source_move_timer = move_repeat
        elseif input.down("down") then
            try_move_source(0, 1)
            source_move_timer = move_repeat
        end
    end

    if target_move_timer <= 0 then
        if input.down("kp7") then
            try_move_target(-1, -1)
            target_move_timer = move_repeat
        elseif input.down("kp8") then
            try_move_target(0, -1)
            target_move_timer = move_repeat
        elseif input.down("kp9") then
            try_move_target(1, -1)
            target_move_timer = move_repeat
        elseif input.down("kp4") then
            try_move_target(-1, 0)
            target_move_timer = move_repeat
        elseif input.down("kp6") then
            try_move_target(1, 0)
            target_move_timer = move_repeat
        elseif input.down("kp1") then
            try_move_target(-1, 1)
            target_move_timer = move_repeat
        elseif input.down("kp2") then
            try_move_target(0, 1)
            target_move_timer = move_repeat
        elseif input.down("kp3") then
            try_move_target(1, 1)
            target_move_timer = move_repeat
        end
    end

    if agent_move_timer <= 0 then
        local path = grid.find_path(cost, agent_x, agent_y, agent_goal_x, agent_goal_y)
        if path and #path >= 2 then
            agent_x = path[1]
            agent_y = path[2]
            agent_move_timer = agent_step_time
        end
    end
end

runtime.draw = function()
    local dist = grid.compute_distance(cost, source_x, source_y)
    local exact_path = grid.extract_path(cost, dist, target_x, target_y)
    local downhill_path = grid.extract_downhill_path(dist, target_x, target_y)
    local astar_path = grid.find_path(cost, agent_x, agent_y, agent_goal_x, agent_goal_y)
    local same = path_equal(exact_path, downhill_path)

    graphics.clear(rgba(14, 12, 16))

    draw_grid(dist)
    draw_path_lines(exact_path, target_x, target_y, rgba(70, 235, 255))
    draw_path_lines(downhill_path, target_x, target_y, rgba(255, 70, 220))
    draw_path_lines(astar_path, agent_x, agent_y, rgba(255, 210, 70))
    draw_markers()

    graphics.debug_text(20, 16, "Arrows = move source", rgba("8eff8e"))
    graphics.debug_text(20, 34, "Numpad = move target (8-way)", rgba("ff7070"))
    graphics.debug_text(20, 52, "LMB = move A* goal", rgba("ffd95a"))
    graphics.debug_text(20, 70, "1/2/3 rules  Z/X/C corners  TAB terrain/distance  R rebuild", rgba("d0d8ff"))

    local dist_v = grid.get_cell(dist, target_x, target_y)
    local cost_v = grid.get_cell(cost, target_x, target_y)
    local bottom_y = OFFSET_Y + GRID_H * CELL + 10

    graphics.debug_text(20, bottom_y, "preset: " .. preset_name(), rgba("ffffff"))
    graphics.debug_text(220, bottom_y, "corner: " .. corner_mode, rgba("ffffff"))
    graphics.debug_text(410, bottom_y, "view: " .. view_mode, rgba("ffffff"))
    graphics.debug_text(540, bottom_y, "target cost=" .. tostring(cost_v) .. "  dist=" .. tostring(dist_v), rgba("ffffff"))

    if same then
        graphics.debug_text(20, bottom_y + 18, "exact path == downhill path", rgba(120, 255, 160))
    else
        graphics.debug_text(20, bottom_y + 18, "exact path != downhill path", rgba(255, 120, 180))
    end

    graphics.debug_text(270, bottom_y + 18, "cyan = exact path", rgba(70, 235, 255))
    graphics.debug_text(440, bottom_y + 18, "magenta = downhill path", rgba(255, 70, 220))
    graphics.debug_text(680, bottom_y + 18, "yellow = A* path", rgba(255, 210, 70))
end