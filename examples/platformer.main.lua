-- =============================================================================
-- CONFIGURATION & COLORS
-- =============================================================================

local SCREEN_WIDTH = 1280
local SCREEN_HEIGHT = 720
local TILE_SIZE = 40

local GRAVITY = 2200
local RUN_ACCELERATION = 3200
local RUN_FRICTION = 2800
local MAX_RUN_SPEED = 420
local JUMP_VELOCITY = -800
local COYOTE_TIME_LIMIT = 0.15 

local COLOR_BACKGROUND = rgba(16, 14, 28, 255)
local COLOR_TILE       = rgba(70, 70, 85, 255)
local COLOR_PLAYER     = rgba(90, 235, 255, 255)
local COLOR_TEXT       = rgba(255, 255, 255, 255)

-- =============================================================================
-- MATH & COLLISION HELPERS
-- =============================================================================

-- Standard Axis-Aligned Bounding Box (AABB) intersection test
local function is_overlapping(x1, y1, w1, h1, x2, y2, w2, h2)
    return x1 < x2 + w2 and x1 + w1 > x2 and y1 < y2 + h2 and y1 + h1 > y2
end

-- =============================================================================
-- LEVEL DATA (TILEMAP)
-- =============================================================================
-- 1 = Solid Wall/Floor, 0 = Empty Space
-- 32 columns x 18 rows (1280x720 at 40px tiles)

local ASCII_MAP = {
    "11111111111111111111111111111111",
    "11111000000000000000000000000111",
    "11000000000000000000000000000011",
    "11111101000111110000000000000001",
    "10000000000000000000111100000001",
    "10000000000000000000000110000001",
    "10000000000000000000000000111001",
    "10011100000000000000000000000001",
    "10000000001111111100000000000011",
    "10000000000000000000000000000001",
    "10000000000001000000000111110001",
    "10000111100000000000000000000001",
    "10000000000000000000000000000001",
    "10000000000000010000000100000001",
    "11000000000000010000001100000001",
    "11100000000010000000001100000001",
    "11111111111111111111111111111111",
    "11111111111111111111111111111111"
}

local solid_tiles = {}

-- =============================================================================
-- PLAYER STATE & LOGIC
-- =============================================================================

local player = {
    x = 100, y = 500,
    width = 32, height = 32, -- slightly smaller than tiles to fit through gaps
    velocity_x = 0,
    velocity_y = 0,
    is_grounded = false,
    coyote_timer = 0
}

local function reset_player()
    player.x = 100
    player.y = 500
    player.velocity_x = 0
    player.velocity_y = 0
    player.is_grounded = false
    player.coyote_timer = 0
end

local function update_player_input(dt)
    -- 1. Gather Intent
    local move_direction = 0
    if input.down("a") or input.down("left") then move_direction = move_direction - 1 end
    if input.down("d") or input.down("right") then move_direction = move_direction + 1 end
    local jump_pressed = input.pressed("space") or input.pressed("w") or input.pressed("up")

    -- 2. Process Horizontal Acceleration & Friction
    if move_direction ~= 0 then
        player.velocity_x = player.velocity_x + move_direction * RUN_ACCELERATION * dt
    else
        if player.velocity_x > 0 then
            player.velocity_x = math.max(player.velocity_x - RUN_FRICTION * dt, 0)
        elseif player.velocity_x < 0 then
            player.velocity_x = math.min(player.velocity_x + RUN_FRICTION * dt, 0)
        end
    end
    player.velocity_x = math.max(-MAX_RUN_SPEED, math.min(MAX_RUN_SPEED, player.velocity_x))

    -- 3. Manage Coyote Time
    if player.is_grounded then
        player.coyote_timer = COYOTE_TIME_LIMIT
    else
        player.coyote_timer = math.max(player.coyote_timer - dt, 0)
    end

    -- 4. Execute Jump
    if jump_pressed and player.coyote_timer > 0 then
        player.velocity_y = JUMP_VELOCITY
        player.is_grounded = false
        player.coyote_timer = 0
    end
end

local function update_player_physics(dt)
    -- =========================================================================
    -- X-AXIS COLLISION
    -- Move horizontally, check for overlaps, push out if hitting a wall.
    -- =========================================================================
    player.x = player.x + player.velocity_x * dt

    for i = 1, #solid_tiles do
        local tile = solid_tiles[i]
        if is_overlapping(player.x, player.y, player.width, player.height, tile.x, tile.y, TILE_SIZE, TILE_SIZE) then
            if player.velocity_x > 0 then     -- Moving Right, hit left wall of tile
                player.x = tile.x - player.width
            elseif player.velocity_x < 0 then -- Moving Left, hit right wall of tile
                player.x = tile.x + TILE_SIZE
            end
            player.velocity_x = 0
        end
    end

    -- =========================================================================
    -- Y-AXIS COLLISION
    -- Move vertically, check overlaps, push out if hitting floor or ceiling.
    -- =========================================================================
    player.velocity_y = player.velocity_y + GRAVITY * dt
    player.y = player.y + player.velocity_y * dt
    player.is_grounded = false

    for i = 1, #solid_tiles do
        local tile = solid_tiles[i]
        if is_overlapping(player.x, player.y, player.width, player.height, tile.x, tile.y, TILE_SIZE, TILE_SIZE) then
            if player.velocity_y > 0 then     -- Falling down, hit floor of tile
                player.y = tile.y - player.height
                player.is_grounded = true
            elseif player.velocity_y < 0 then -- Jumping up, hit ceiling of tile
                player.y = tile.y + TILE_SIZE
            end
            player.velocity_y = 0
        end
    end
end

-- =============================================================================
-- ENGINE HOOKS
-- =============================================================================

function runtime.init()
    window.set_size(SCREEN_WIDTH, SCREEN_HEIGHT)
    
    -- Parse the ASCII map into physical rectangles
    for row_idx = 1, #ASCII_MAP do
        local row_string = ASCII_MAP[row_idx]
        for col_idx = 1, #row_string do
            local char = string.sub(row_string, col_idx, col_idx)
            if char == "1" then
                table.insert(solid_tiles, {
                    x = (col_idx - 1) * TILE_SIZE,
                    y = (row_idx - 1) * TILE_SIZE
                })
            end
        end
    end

    reset_player()
end

function runtime.update(dt)
    dt = math.min(dt, 0.05) -- Prevent physics tunneling on huge lag spikes

    if input.pressed("r") then
        reset_player()
    end

    update_player_input(dt)
    update_player_physics(dt)
end

function runtime.draw()
    graphics.clear(COLOR_BACKGROUND)

    -- Draw Map
    for i = 1, #solid_tiles do
        local tile = solid_tiles[i]
        graphics.draw_rect(tile.x, tile.y, TILE_SIZE, TILE_SIZE, COLOR_TILE)
    end

    -- Draw Player
    graphics.draw_rect(player.x, player.y, player.width, player.height, COLOR_PLAYER)

    -- UI Instructions
    graphics.draw_text("A/D or LEFT/RIGHT: move", 20, SCREEN_HEIGHT - 72, COLOR_TEXT)
    graphics.draw_text("SPACE / W / UP: jump", 20, SCREEN_HEIGHT - 52, COLOR_TEXT)
    graphics.draw_text("R: reset", 20, SCREEN_HEIGHT - 32, COLOR_TEXT)
end