-- =============================================================================
-- CONSTANTS & CONFIGURATION
-- =============================================================================

local SCREEN_WIDTH = 1280
local SCREEN_HEIGHT = 720
local FLOOR_Y = 650

local GRAVITY = 2200
local RUN_ACCELERATION = 3200
local RUN_FRICTION = 2800
local MAX_RUN_SPEED = 420
local JUMP_VELOCITY = -860
local COYOTE_TIME_LIMIT = 0.15 -- How long after leaving an edge you can still jump

-- =============================================================================
-- COLORS
-- =============================================================================

local COLOR_BACKGROUND = rgba(16, 14, 28, 255)
local COLOR_FLOOR      = rgba(40, 40, 50, 255)
local COLOR_PLATFORM   = rgba(70, 70, 85, 255)
local COLOR_PLAYER     = rgba(90, 235, 255, 255)
local COLOR_TEXT       = rgba(255, 255, 255, 180)

-- =============================================================================
-- GAME STATE
-- =============================================================================

local player = {
    x = 120,
    y = 240,
    width = 42,
    height = 56,
    velocity_x = 0,
    velocity_y = 0,
    is_grounded = false,
    coyote_timer = 0
}

local platforms = {
    { x = 180, y = 560, width = 220, height = 20 },
    { x = 470, y = 470, width = 190, height = 20 },
    { x = 760, y = 390, width = 170, height = 20 },
    { x = 980, y = 520, width = 180, height = 20 },
}

local function reset_player(e)
    e.x = 120
    e.y = 240
    e.velocity_x = 0
    e.velocity_y = 0
    e.is_grounded = false
    e.coyote_timer = 0
end

-- =============================================================================
-- PHYSICS SYSTEM
-- =============================================================================

-- A reusable physics step. Applies gravity and resolves one-way platform/floor 
-- collisions for any entity table containing x, y, width, height, and velocities.
local function apply_physics_and_collision(e, dt)
    local previous_bottom = e.y + e.height

    -- Apply gravity and update position based on velocity
    e.velocity_y = e.velocity_y + GRAVITY * dt
    e.x = e.x + e.velocity_x * dt
    e.y = e.y + e.velocity_y * dt

    -- Constrain horizontally to screen boundaries
    if e.x < 0 then
        e.x = 0
        e.velocity_x = 0
    end
    if e.x + e.width > SCREEN_WIDTH then
        e.x = SCREEN_WIDTH - e.width
        e.velocity_x = 0
    end

    -- Reset grounding state before checking for collisions
    e.is_grounded = false
    local new_bottom = e.y + e.height
    local landing_y = FLOOR_Y
    local found_landing = false

    -- Check collision with the main floor
    if previous_bottom <= FLOOR_Y and new_bottom >= FLOOR_Y and e.velocity_y >= 0 then
        found_landing = true
    end

    -- Check collision with the floating platforms (one-way dropping)
    for i = 1, #platforms do
        local platform = platforms[i]
        local is_overlapping_x = e.x + e.width > platform.x and e.x < platform.x + platform.width
        
        -- Only land if falling downward and crossing the platform's top edge
        if is_overlapping_x and previous_bottom <= platform.y and new_bottom >= platform.y and e.velocity_y >= 0 then
            if not found_landing or platform.y < landing_y then
                found_landing = true
                landing_y = platform.y
            end
        end
    end

    -- Resolve the vertical collision if we hit something
    if found_landing then
        e.y = landing_y - e.height
        e.velocity_y = 0
        e.is_grounded = true
    end
end

-- =============================================================================
-- ENGINE HOOKS
-- =============================================================================

runtime.init = function()
    window.init(SCREEN_WIDTH, SCREEN_HEIGHT, "Luagame - Clean Platformer Template")
    reset_player(player)
end

runtime.update = function(dt)
    if input.pressed("r") then
        reset_player(player)
    end

    -- 1. Gather Input
    local move_direction = 0
    if input.down("a") or input.down("left") then move_direction = move_direction - 1 end
    if input.down("d") or input.down("right") then move_direction = move_direction + 1 end

    local jump_pressed = input.pressed("space") or input.pressed("w") or input.pressed("up")

    -- 2. Process Horizontal Movement
    if move_direction ~= 0 then
        player.velocity_x = player.velocity_x + move_direction * RUN_ACCELERATION * dt
    else
        -- Apply friction to slide to a halt
        if player.velocity_x > 0 then
            player.velocity_x = math.max(player.velocity_x - RUN_FRICTION * dt, 0)
        elseif player.velocity_x < 0 then
            player.velocity_x = math.min(player.velocity_x + RUN_FRICTION * dt, 0)
        end
    end
    
    -- Clamp to maximum run speed
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

    -- 5. Apply Systems
    apply_physics_and_collision(player, dt)
end

runtime.draw = function()
    -- Background
    graphics.clear(COLOR_BACKGROUND)

    -- Floor
    graphics.draw_rect(0, FLOOR_Y, SCREEN_WIDTH, SCREEN_HEIGHT - FLOOR_Y, COLOR_FLOOR)

    -- Platforms
    for i = 1, #platforms do
        local platform = platforms[i]
        graphics.draw_rect(platform.x, platform.y, platform.width, platform.height, COLOR_PLATFORM)
    end

    -- Player
    graphics.draw_rect(player.x, player.y, player.width, player.height, COLOR_PLAYER)

    -- UI Instructions
    graphics.debug_text(20, SCREEN_HEIGHT - 72, "A/D or LEFT/RIGHT: move", COLOR_TEXT)
    graphics.debug_text(20, SCREEN_HEIGHT - 52, "SPACE / W / UP: jump", COLOR_TEXT)
    graphics.debug_text(20, SCREEN_HEIGHT - 32, "R: reset", COLOR_TEXT)
end