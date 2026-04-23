-- =============================================================================
-- GRID FOV + MEMORY + GOBLIN TEST
-- =============================================================================
-- Controls:
--   LMB = click-to-move
--   T   = toggle walls_visible
--   G   = toggle diagonal_gaps
--   C   = toggle cone FOV
--   M   = toggle corner_mode (allow / no_squeeze)
--   Z   = radius down
--   X   = radius up
--   R   = rebuild
-- =============================================================================

local ASCII_MAP = {
    "000000000000000000000000000000000000000000000000",
    "011111111111111111111111111111111111111111111110",
    "011111111111111111111111111111111111111111111110",
    "011111111111111111111111111111111111111111111110",
    "011111110111111111011111111111011111111101111110",
    "011111110011111110111111111111001111111011111110",
    "011111111001111101111111111111100111110111111110",
    "011111111100111011111111111111110011101111111110",
    "011111111110010111111111011111111001011111111110",
    "011111111111001111111110001111111100111111111110",
    "010101110101100101110100100101110100110101110110",
    "011111111110110011111000000011111011001111111110",
    "011111111101111001110000100001110111100111111110",
    "011111111011111100100000100000101111110011111110",
    "011111111111111110000000100000011111111011111110",
    "011111111111111110001111111110001111111111111110",
    "011111111111111111000000100000011111111111111110",
    "011111111111111111100000100000111111111111111110",
    "011111011111110111110000100001111101111111011110",
    "011111101111111011111000000011111110111111101110",
    "011010101000101010101000100010101010100010101010",
    "011111111110111111111110001111111111111011111110",
    "011111111111111111111111011111111111111111111110",
    "011111111111111111111111111111111111111111111110",
    "011111111111111111111111111111111111111111111110",
    "011111111111111111111111111111111111111111111110",
    "011111111111111111111111111111111111111111111110",
    "000000000000000000000000000000000000000000000000",
}

local FLOOR_DIAGS = {
    { 11,  8,  1,  1,  7 },
    { 22, 18,  1, -1,  7 },
    { 36,  8, -1,  1,  8 },
    {  7, 20,  1,  1,  6 },
}

local WATER_RECTS = {
    { 14,  4,  7, 3 },
    { 24, 11, 11, 3 },
    { 34, 19,  9, 4 },
    {  8, 22, 13, 3 },
    { 30,  5,  5, 2 },
}

local WATER_DIAGS = {
    { 14,  5,  1,  1,  6 },
    { 19, 15,  1, -1,  6 },
    { 32, 12,  1,  1,  6 },
    { 39, 22, -1, -1,  7 },
}

local GOBLIN_SPAWNS = {
    { 10,  4 },
    { 18,  6 },
    { 34,  5 },
    { 39, 14 },
    {  8, 22 },
    { 23, 23 },
    { 30, 16 },
    { 42, 24 },
}

local GRID_H = #ASCII_MAP
local GRID_W = #ASCII_MAP[1]

local GLYPH_W = 8
local GLYPH_H = 8

local MAP_PIXEL_W = GRID_W * GLYPH_W
local MAP_PIXEL_H = GRID_H * GLYPH_H

local HUD_PAD_TOP = 8
local HUD_LINE_H = 10
local HUD_PAD_BOTTOM = 8
local HUD_ROWS = 5

local CANVAS_W = MAP_PIXEL_W
local CANVAS_H = MAP_PIXEL_H + HUD_PAD_TOP + HUD_ROWS * HUD_LINE_H + HUD_PAD_BOTTOM

local SCALE = 2

local DEFAULT_SIGHT_RADIUS = 10
local CONE_ANGLE = 200
local PLAYER_STEP_TIME = 0.025
local WATER_COST = 4

local COLORS = {
    clear_bg           = rgba(12, 10, 14),
    canvas_bg          = rgba(7, 7, 9),

    wall_visible       = rgba(170, 170, 182),
    floor_visible      = rgba(80, 80, 90),
    water_visible      = rgba("#0059b3"),

    wall_memory        = rgba(28, 30, 34),
    floor_memory       = rgba(20, 20, 30),
    water_memory       = rgba("#0d263f"),

    path_visible       = rgba(90, 220, 255),

    goal_visible       = rgba(255, 96, 96),
    goal_memory        = rgba(90, 36, 36),
    goal_hidden        = rgba(56, 20, 20),

    player             = rgba(100, 170, 255),

    goblin_idle        = rgba(56, 132, 68),
    goblin_tracking    = rgba(72, 182, 88),
    goblin_sees_player = rgba(100, 255, 120),

    hud_primary        = rgba(220, 220, 220),
    hud_toggle         = rgba(255, 230, 120),
    hud_goal           = rgba(255, 150, 150),
    hud_info           = rgba(160, 200, 255),
    hud_good           = rgba(100, 255, 120),
    hud_note           = rgba(160, 190, 160),
}

local map = nil
local visible = nil
local memory = nil
local current_path = nil
local canvas = nil
local goblins = {}

local player_x = 4
local player_y = 4
local goal_x = 4
local goal_y = 4
local goal_active = false

local sight_radius = DEFAULT_SIGHT_RADIUS
local use_cone = false
local facing_angle = 0
local walls_visible = true
local diagonal_gaps = false
local movement_corner_mode = "allow"

local player_move_timer = 0

local prev_down = {}
local just_pressed = {}

local function update_key_edges()
    local keys = { "t", "g", "c", "m", "r", "z", "x" }

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

local function screen_to_cell(mx, my)
    local x = math.floor(mx / (GLYPH_W * SCALE))
    local y = math.floor(my / (GLYPH_H * SCALE))
    return x, y
end

local function direction_to_angle(dx, dy)
    if dx == 0 and dy == 0 then return facing_angle end
    if dx > 0 and dy == 0 then return 0 end
    if dx > 0 and dy > 0 then return 45 end
    if dx == 0 and dy > 0 then return 90 end
    if dx < 0 and dy > 0 then return 135 end
    if dx < 0 and dy == 0 then return 180 end
    if dx < 0 and dy < 0 then return 225 end
    if dx == 0 and dy < 0 then return 270 end
    if dx > 0 and dy < 0 then return 315 end
    return facing_angle
end

local function set_facing_toward(nx, ny)
    facing_angle = direction_to_angle(nx - player_x, ny - player_y)
end

local function is_open(x, y)
    if x < 0 or x >= GRID_W or y < 0 or y >= GRID_H then
        return false
    end

    local v = grid.get_cell(map, x, y)
    return v and v > 0
end

local function is_visible(x, y)
    if not visible then
        return false
    end

    local v = grid.get_cell(visible, x, y)
    return v and v ~= 0
end

local function is_remembered(x, y)
    if not memory then
        return false
    end

    local v = grid.get_cell(memory, x, y)
    return v and v ~= 0
end

local function path_contains(x, y)
    if not current_path then
        return false
    end

    for i = 1, #current_path, 2 do
        if current_path[i] == x and current_path[i + 1] == y then
            return true
        end
    end

    return false
end

local function goblin_at(x, y, ignore_index)
    for i = 1, #goblins do
        if i ~= ignore_index then
            local g = goblins[i]
            if g.x == x and g.y == y then
                return true
            end
        end
    end

    return false
end

local function goblin_can_see_player(g)
    if not is_visible(g.x, g.y) then
        return false
    end

    return grid.has_line_of_sight(map, g.x, g.y, player_x, player_y)
end

local function paint_diag(x, y, dx, dy, len, value, only_on_open)
    for i = 0, len - 1 do
        local px = x + dx * i
        local py = y + dy * i

        if px >= 0 and px < GRID_W and py >= 0 and py < GRID_H then
            if (not only_on_open) or grid.get_cell(map, px, py) > 0 then
                grid.set_cell(map, px, py, value)
            end
        end
    end
end

local function paint_rect(x, y, w, h, value, only_on_open)
    for py = y, y + h - 1 do
        for px = x, x + w - 1 do
            if px >= 0 and px < GRID_W and py >= 0 and py < GRID_H then
                if (not only_on_open) or grid.get_cell(map, px, py) > 0 then
                    grid.set_cell(map, px, py, value)
                end
            end
        end
    end
end

local function stamp_memory()
    for y = 0, GRID_H - 1 do
        for x = 0, GRID_W - 1 do
            if is_visible(x, y) then
                grid.set_cell(memory, x, y, 1)
            end
        end
    end
end

local function apply_movement_rules()
    grid.set_movement_rules({
        neighbors = 8,
        cardinal_cost = 1,
        diagonal_cost = 1,
        corner_mode = movement_corner_mode,
        allow_blocked_goal = true,
    })
end

local function apply_vision_rules()
    grid.set_vision_rules({
        walls_visible = walls_visible,
        diagonal_gaps = diagonal_gaps,
    })
end

local function build_map()
    map = grid.new_datagrid(GRID_W, GRID_H)
    memory = grid.new_datagrid(GRID_W, GRID_H)

    for y = 0, GRID_H - 1 do
        local row = ASCII_MAP[y + 1]

        for x = 0, GRID_W - 1 do
            local ch = string.sub(row, x + 1, x + 1)
            grid.set_cell(map, x, y, tonumber(ch))
            grid.set_cell(memory, x, y, 0)
        end
    end

    for i = 1, #FLOOR_DIAGS do
        local d = FLOOR_DIAGS[i]
        paint_diag(d[1], d[2], d[3], d[4], d[5], 1, false)
    end

    for i = 1, #WATER_RECTS do
        local r = WATER_RECTS[i]
        paint_rect(r[1], r[2], r[3], r[4], WATER_COST, true)
    end

    for i = 1, #WATER_DIAGS do
        local d = WATER_DIAGS[i]
        paint_diag(d[1], d[2], d[3], d[4], d[5], WATER_COST, true)
    end

    player_x = 4
    player_y = 4
    goal_x = player_x
    goal_y = player_y
    goal_active = false
    facing_angle = 0
    current_path = nil
    player_move_timer = 0
    goblins = {}

    for i = 1, #GOBLIN_SPAWNS do
        local sx = GOBLIN_SPAWNS[i][1]
        local sy = GOBLIN_SPAWNS[i][2]

        if is_open(sx, sy) and not (sx == player_x and sy == player_y) then
            goblins[#goblins + 1] = {
                x = sx,
                y = sy,
                path = nil,
                last_known_x = nil,
                last_known_y = nil,
            }
        end
    end
end

local function recompute_player_path()
    if not goal_active then
        current_path = nil
        return
    end

    current_path = grid.find_path(map, player_x, player_y, goal_x, goal_y)

    if current_path and #current_path >= 2 then
        set_facing_toward(current_path[1], current_path[2])
    elseif current_path and #current_path == 0 then
        goal_active = false
        current_path = nil
    end
end

local function recompute_player_view()
    if use_cone then
        visible = grid.compute_fov_cone(map, player_x, player_y, sight_radius, facing_angle, CONE_ANGLE)
    else
        visible = grid.compute_fov(map, player_x, player_y, sight_radius)
    end

    stamp_memory()
end

local function recompute_all()
    recompute_player_path()
    recompute_player_view()
end

local function update_goblins_turn()
    for i = 1, #goblins do
        local g = goblins[i]
        local sees_player = goblin_can_see_player(g)

        if sees_player then
            g.last_known_x = player_x
            g.last_known_y = player_y
            g.path = grid.find_path(map, g.x, g.y, player_x, player_y)
        elseif g.last_known_x ~= nil then
            if g.x == g.last_known_x and g.y == g.last_known_y then
                g.last_known_x = nil
                g.last_known_y = nil
                g.path = nil
            else
                g.path = grid.find_path(map, g.x, g.y, g.last_known_x, g.last_known_y)
            end
        else
            g.path = nil
        end
    end

    for i = 1, #goblins do
        local g = goblins[i]

        if g.path and #g.path >= 2 then
            local nx = g.path[1]
            local ny = g.path[2]

            if not goblin_at(nx, ny, i) and not (nx == player_x and ny == player_y) then
                g.x = nx
                g.y = ny
            end
        end
    end
end

local function count_visible_goblins()
    local count = 0

    for i = 1, #goblins do
        local g = goblins[i]
        if is_visible(g.x, g.y) then
            count = count + 1
        end
    end

    return count
end

local function draw_hud()
    local base_y = MAP_PIXEL_H + HUD_PAD_TOP
    local walls_text = walls_visible and "ON" or "OFF"
    local gaps_text = diagonal_gaps and "allow" or "closed"
    local cone_text = use_cone and "ON" or "OFF"
    local goal_text = goal_active and (tostring(goal_x) .. "," .. tostring(goal_y)) or "none"

    graphics.debug_text(0, base_y + HUD_LINE_H * 0, "LMB move   T walls   G diag gaps   C cone", COLORS.hud_primary)
    graphics.debug_text(0, base_y + HUD_LINE_H * 1, "M corner mode   Z/X radius   R rebuild", COLORS.hud_primary)

    graphics.debug_text(0,   base_y + HUD_LINE_H * 2, "walls: " .. walls_text, COLORS.hud_toggle)
    graphics.debug_text(92,  base_y + HUD_LINE_H * 2, "diag gaps: " .. gaps_text, COLORS.hud_info)
    graphics.debug_text(232, base_y + HUD_LINE_H * 2, "cone: " .. cone_text, COLORS.hud_info)
    graphics.debug_text(304, base_y + HUD_LINE_H * 2, "radius: " .. tostring(sight_radius), COLORS.hud_good)

    graphics.debug_text(0,   base_y + HUD_LINE_H * 3, "corner_mode: " .. movement_corner_mode, COLORS.hud_toggle)
    graphics.debug_text(176, base_y + HUD_LINE_H * 3, "facing: " .. tostring(facing_angle), COLORS.hud_info)
    graphics.debug_text(272, base_y + HUD_LINE_H * 3, "water: " .. tostring(WATER_COST), COLORS.water_visible)

    graphics.debug_text(0,   base_y + HUD_LINE_H * 4, "goal: " .. goal_text, COLORS.hud_goal)
    graphics.debug_text(136, base_y + HUD_LINE_H * 4, "visible goblins: " .. tostring(count_visible_goblins()), COLORS.hud_good)
end

runtime.init = function()
    window.set_title("Newt grid FOV/LOS/Pathfinding Test")
    graphics.set_default_filter("nearest")
    canvas = graphics.new_canvas(CANVAS_W, CANVAS_H)

    build_map()
    apply_movement_rules()
    apply_vision_rules()
    recompute_all()
end

runtime.update = function(dt)
    update_key_edges()

    if pressed("t") then
        walls_visible = not walls_visible
        apply_vision_rules()
        recompute_player_view()
    end

    if pressed("g") then
        diagonal_gaps = not diagonal_gaps
        apply_vision_rules()
        recompute_player_view()
    end

    if pressed("c") then
        use_cone = not use_cone
        recompute_player_view()
    end

    if pressed("m") then
        if movement_corner_mode == "allow" then
            movement_corner_mode = "no_squeeze"
        else
            movement_corner_mode = "allow"
        end

        apply_movement_rules()
        recompute_all()
    end

    if pressed("z") then
        sight_radius = math.max(1, sight_radius - 1)
        recompute_player_view()
    end

    if pressed("x") then
        sight_radius = sight_radius + 1
        recompute_player_view()
    end

    if pressed("r") then
        build_map()
        apply_movement_rules()
        apply_vision_rules()
        recompute_all()
    end

    if input.pressed("mouse1") then
        local mx, my = input.get_mouse_position()
        local gx, gy = screen_to_cell(mx, my)

        if gx >= 0 and gx < GRID_W and gy >= 0 and gy < GRID_H then
            goal_x = gx
            goal_y = gy
            goal_active = true
            recompute_player_path()
            recompute_player_view()
        end
    end

    player_move_timer = player_move_timer - dt

    if player_move_timer <= 0 and current_path and #current_path >= 2 then
        local nx = current_path[1]
        local ny = current_path[2]

        set_facing_toward(nx, ny)

        player_x = nx
        player_y = ny
        player_move_timer = PLAYER_STEP_TIME

        recompute_player_path()
        recompute_player_view()
        update_goblins_turn()
    end
end

runtime.draw = function()
    graphics.set_canvas(canvas)
    graphics.clear(COLORS.canvas_bg)

    for y = 0, GRID_H - 1 do
        for x = 0, GRID_W - 1 do
            local tile = grid.get_cell(map, x, y) or 0
            local seen = is_visible(x, y)
            local remembered = is_remembered(x, y)
            local on_path = path_contains(x, y)

            local ch = " "
            local color = rgba(0, 0, 0)

            if seen then
                if tile == 0 then
                    if walls_visible then
                        ch = "#"
                        color = COLORS.wall_visible
                    end
                elseif tile == WATER_COST then
                    ch = "~"
                    color = COLORS.water_visible
                else
                    ch = "."
                    color = COLORS.floor_visible
                end
            elseif remembered then
                if tile == 0 then
                    ch = "#"
                    color = COLORS.wall_memory
                elseif tile == WATER_COST then
                    ch = "~"
                    color = COLORS.water_memory
                else
                    ch = "."
                    color = COLORS.floor_memory
                end
            end

            if on_path and seen then
                ch = "+"
                color = COLORS.path_visible
            end

            if goal_active and x == goal_x and y == goal_y then
                ch = "X"

                if seen then
                    color = COLORS.goal_visible
                elseif remembered then
                    color = COLORS.goal_memory
                else
                    color = COLORS.goal_hidden
                end
            end

            graphics.debug_text(x * GLYPH_W, y * GLYPH_H, ch, color)
        end
    end

    for i = 1, #goblins do
        local g = goblins[i]

        if is_visible(g.x, g.y) then
            local color = COLORS.goblin_idle

            if grid.has_line_of_sight(map, g.x, g.y, player_x, player_y) then
                color = COLORS.goblin_sees_player
            elseif g.last_known_x ~= nil then
                color = COLORS.goblin_tracking
            end

            graphics.debug_text(g.x * GLYPH_W, g.y * GLYPH_H, "g", color)
        end
    end

    graphics.debug_text(player_x * GLYPH_W, player_y * GLYPH_H, "@", COLORS.player)

    draw_hud()

    graphics.set_canvas()

    graphics.clear(COLORS.clear_bg)
    graphics.begin_transform()
    graphics.set_scale(SCALE)
    graphics.draw_image(canvas, 0, 0)
    graphics.end_transform()
end