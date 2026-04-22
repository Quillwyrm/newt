-- =============================================================================
-- GRID FOV + MEMORY TEST
-- =============================================================================
-- Controls:
--   LMB = click-to-move
--   T   = toggle light_walls
--   R   = rebuild
-- =============================================================================
local ASCII_MAP = {
    "000000000000000000000000000000000000000000000000",
    "000000000000000000000000000000000000000000000000",
    "001111111110000111111111110000011111111111110000",
    "001111111110000111111111110000011110011111110000",
    "001110011111111111100111110000011110011111110000",
    "001110011110100111100111111111111111111111110000",
    "001111111110100111111111110010011111111111110000",
    "001111111110100111111111110010011111111111110000",
    "000000010000100111111111110010000000100010000000",
    "000000010000100000001000000010000000100010000000",
    "000000010000100000001000000011111111111111100000",
    "000011111111110000111111100011111111111111100000",
    "000011111111110000111111100011111100111111100000",
    "000011110011110000110111100011111100111111100000",
    "000011110011111111110111111111111111111111100000",
    "000011111111110000110111100001111111111111100000",
    "000011111111110000111111100001111111111111100000",
    "000000001000000000111111100001111111111111100000",
    "000000001000000000000100000000000000010000000000",
    "000000001111111111100100111111111111110000000000",
    "000000001000000111111111111000000000010000000000",
    "000111111110000111111111111000011111111111110000",
    "000111111110000111001111111000011111001111110000",
    "000111111111111111001111111111111111001111110000",
    "000111111110000111111111111000011111111111110000",
    "000111111110000111111111111000011111111111110000",
    "000000000000000000000000000000000000000000000000",
    "000000000000000000000000000000000000000000000000",
}


local GRID_W = 58
local GRID_H = 34

local GLYPH_W = 8
local GLYPH_H = 8

local HUD_LINES = 3
local CANVAS_W = GRID_W * GLYPH_W
local CANVAS_H = (GRID_H + HUD_LINES + 1) * GLYPH_H

local SCALE = 2

local sight_radius = 10
local step_time = 0.055

local map = nil
local visible = nil
local memory = nil
local current_path = nil
local canvas = nil

local player_x = 5
local player_y = 5
local goal_x = 5
local goal_y = 5

local auto_move_timer = 0
local light_walls = true

local prev_down = {}
local just_pressed = {}

local function update_key_edges()
    local keys = { "t", "r" }

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

local GRID_H = #ASCII_MAP
local GRID_W = #ASCII_MAP[1]

local function build_map()
    map = grid.new_datagrid(GRID_W, GRID_H)
    memory = grid.new_datagrid(GRID_W, GRID_H)

    for y = 0, GRID_H - 1 do
        local row = ASCII_MAP[y + 1]

        for x = 0, GRID_W - 1 do
            local ch = string.sub(row, x + 1, x + 1)
            local v = tonumber(ch)
            grid.set_cell(map, x, y, v)
            grid.set_cell(memory, x, y, 0)
        end
    end

    player_x = 4
    player_y = 4
    goal_x = player_x
    goal_y = player_y
    current_path = nil
end

local function apply_movement_rules()
    grid.set_movement_rules({
        neighbors = 8,
        cardinal_cost = 1,
        diagonal_cost = 1,
        corner_mode = "allow",
        allow_blocked_goal = true,
    })
end

local function apply_vision_rules()
    grid.set_vision_rules({
        light_walls = light_walls,
        diagonal_walls = false,
    })
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

local function stamp_memory()
    for y = 0, GRID_H - 1 do
        for x = 0, GRID_W - 1 do
            if is_visible(x, y) then
                grid.set_cell(memory, x, y, 1)
            end
        end
    end
end

local function recompute()
    visible = grid.compute_fov(map, player_x, player_y, sight_radius)
    stamp_memory()
    current_path = grid.find_path(map, player_x, player_y, goal_x, goal_y)
end

runtime.init = function()
    window.set_title("Newt Grid FOV Memory Test")

    graphics.set_default_filter("nearest")
    canvas = graphics.new_canvas(CANVAS_W, CANVAS_H)

    build_map()
    apply_movement_rules()
    apply_vision_rules()
    recompute()
end

runtime.update = function(dt)
    update_key_edges()

    if pressed("t") then
        light_walls = not light_walls
        apply_vision_rules()
        recompute()
    end

    if pressed("r") then
        build_map()
        apply_movement_rules()
        apply_vision_rules()
        recompute()
    end

    if input.pressed("mouse1") then
        local mx, my = input.get_mouse_position()
        local gx, gy = screen_to_cell(mx, my)

        if gx >= 0 and gx < GRID_W and gy >= 0 and gy < GRID_H then
            goal_x = gx
            goal_y = gy
            current_path = grid.find_path(map, player_x, player_y, goal_x, goal_y)
        end
    end

    auto_move_timer = auto_move_timer - dt

    if auto_move_timer <= 0 then
        if current_path and #current_path >= 2 then
            player_x = current_path[1]
            player_y = current_path[2]
            auto_move_timer = step_time
            recompute()
        end
    end
end

runtime.draw = function()
    graphics.set_canvas(canvas)
    graphics.clear(rgba(7, 7, 9))

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
                    if light_walls then
                        ch = "#"
                        color = rgba(176, 176, 190)
                    end
                else
                    ch = "."
                    color = rgba(96, 102, 118)
                end
            elseif remembered then
                if tile == 0 then
                    ch = "#"
                    color = rgba(58, 60, 68)
                else
                    ch = "."
                    color = rgba(44, 48, 56)
                end
            end

            if on_path then
                if seen then
                    ch = "+"
                    color = rgba(90, 220, 255)
                elseif remembered then
                    ch = "+"
                    color = rgba(52, 104, 120)
                end
            end

            if x == goal_x and y == goal_y then
                ch = "X"

                if seen then
                    color = rgba(255, 96, 96)
                elseif remembered then
                    color = rgba(118, 52, 52)
                else
                    color = rgba(70, 28, 28)
                end
            end

            if x == player_x and y == player_y then
                ch = "@"
                color = rgba(90, 255, 120)
            end

            graphics.debug_text(x * GLYPH_W, y * GLYPH_H, ch, color)
        end
    end

    local hud_y = GRID_H * GLYPH_H + 8
    local light_text = light_walls and "ON" or "OFF"
    local goal_is_wall = not is_open(goal_x, goal_y)
    local goal_mode = goal_is_wall and "blocked goal" or "open goal"

    graphics.debug_text(0,   hud_y + 0,  "LMB move   T light_walls   R rebuild", rgba(220, 220, 220))
    graphics.debug_text(0,   hud_y + 10, "light_walls: " .. light_text, rgba(255, 230, 120))
    graphics.debug_text(152, hud_y + 10, "goal: " .. tostring(goal_x) .. "," .. tostring(goal_y), rgba(255, 150, 150))
    graphics.debug_text(304, hud_y + 10, goal_mode, rgba(160, 200, 255))

    graphics.set_canvas()

    graphics.clear(rgba(12, 10, 14))
    graphics.begin_transform()
    graphics.set_scale(SCALE)
    graphics.draw_image(canvas, 0, 0)
    graphics.end_transform()
end