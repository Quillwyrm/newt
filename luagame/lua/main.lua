local gfx = graphics
local bit = require("bit")

local function rgba(r, g, b, a)
    return bit.bor(bit.lshift(r, 24), bit.lshift(g, 16), bit.lshift(b, 8), a)
end

local function clamp(v, lo, hi)
    return v < lo and lo or (v > hi and hi or v)
end

local function approach(v, target, delta)
    if v < target then
        v = v + delta
        if v > target then v = target end
    elseif v > target then
        v = v - delta
        if v < target then v = target end
    end
    return v
end

local function overlaps(a_x, a_y, a_w, a_h, b_x, b_y, b_w, b_h)
    return a_x + a_w > b_x and a_x < b_x + b_w and a_y + a_h > b_y and a_y < b_y + b_h
end

local SW, SH = 1280, 720
local FLOOR_Y = 650

local GRAVITY = 2200
local RUN_ACCEL = 3200
local RUN_FRICTION = 2800
local MAX_RUN = 420
local JUMP_VELOCITY = -860
local COYOTE_TIME = 0.10

local t = 0
local shake = 0
local flash = 0

local player = {
    x = 120,
    y = 240,
    w = 42,
    h = 56,
    vx = 0,
    vy = 0,
    on_ground = false,
    coyote = 0,
    facing = 1,
    jump_fx = 0,
    land_fx = 0,
}

local particles = {}

local platforms = {
    { x = 180, y = 560, w = 220, h = 20 },
    { x = 470, y = 470, w = 190, h = 20 },
    { x = 760, y = 390, w = 170, h = 20 },
    { x = 980, y = 520, w = 180, h = 20 },
}

local rainbow = {
    {255,  90, 120},
    {255, 170,  60},
    {255, 235,  90},
    { 90, 255, 140},
    { 80, 200, 255},
    {170, 120, 255},
    {255, 120, 240},
}

local warm = {
    {255, 230, 120},
    {255, 180,  80},
    {255, 120,  60},
    {255, 255, 255},
}

local cool = {
    {120, 255, 255},
    {100, 180, 255},
    {160, 120, 255},
    {255, 255, 255},
}

local function pick(palette)
    return palette[math.random(#palette)]
end

local function spawn_particle(x, y, vx, vy, life, size, gravity, palette)
    local c = pick(palette)
    table.insert(particles, {
        x = x,
        y = y,
        vx = vx,
        vy = vy,
        life = life,
        max_life = life,
        size = size,
        gravity = gravity,
        r = c[1],
        g = c[2],
        b = c[3],
    })
end

local function spawn_jump_burst(x, y, facing)
    for i = 1, 16 do
        local vx = (math.random() - 0.5) * 260 + facing * 90
        local vy = -math.random(120, 420)
        local life = 0.25 + math.random() * 0.25
        local size = 4 + math.random() * 5
        spawn_particle(x, y, vx, vy, life, size, 900, warm)
    end
end

local function spawn_land_burst(x, y, strength)
    local count = 18 + math.floor(strength * 14)
    for i = 1, count do
        local dir = math.random() < 0.5 and -1 or 1
        local vx = dir * (120 + math.random() * (260 + strength * 220))
        local vy = -math.random() * (140 + strength * 140)
        local life = 0.28 + math.random() * 0.30
        local size = 4 + math.random() * 8
        spawn_particle(x, y, vx, vy, life, size, 1000, warm)
    end
end

local function spawn_click_burst(x, y)
    for i = 1, 32 do
        local a = math.random() * math.pi * 2
        local s = 80 + math.random() * 420
        local vx = math.cos(a) * s
        local vy = math.sin(a) * s
        local life = 0.35 + math.random() * 0.35
        local size = 4 + math.random() * 8
        spawn_particle(x, y, vx, vy, life, size, 200, rainbow)
    end
    shake = math.max(shake, 0.18)
    flash = 0.18
end

local function reset_player()
    player.x = 120
    player.y = 240
    player.vx = 0
    player.vy = 0
    player.on_ground = false
    player.coyote = 0
    player.jump_fx = 0
    player.land_fx = 0
end

function runtime.init()
    window.init(SW, SH, "Luagame - Rectangle Freedom Test")
    math.randomseed(os.time())
    reset_player()
end

function runtime.update(dt)
    t = t + dt
    shake = math.max(shake - dt * 3.2, 0)
    flash = math.max(flash - dt * 1.8, 0)
    player.jump_fx = math.max(player.jump_fx - dt * 2.8, 0)
    player.land_fx = math.max(player.land_fx - dt * 2.6, 0)

    if input.pressed("r") then
        reset_player()
    end

    if input.pressed("mouse1") then
        local mx, my = input.get_mouse_position()
        spawn_click_burst(mx, my)
    end

    local move = 0
    if input.down("a") or input.down("left") then move = move - 1 end
    if input.down("d") or input.down("right") then move = move + 1 end

    if move ~= 0 then
        player.vx = player.vx + move * RUN_ACCEL * dt
        player.facing = move
    else
        player.vx = approach(player.vx, 0, RUN_FRICTION * dt)
    end

    player.vx = clamp(player.vx, -MAX_RUN, MAX_RUN)

    if player.on_ground then
        player.coyote = COYOTE_TIME
    else
        player.coyote = math.max(player.coyote - dt, 0)
    end

    local jump_pressed =
        input.pressed("space") or
        input.pressed("w") or
        input.pressed("up")

    if jump_pressed and player.coyote > 0 then
        player.vy = JUMP_VELOCITY
        player.on_ground = false
        player.coyote = 0
        player.jump_fx = 0.18
        player.land_fx = 0
        spawn_jump_burst(player.x + player.w * 0.5, player.y + player.h, player.facing)
        shake = math.max(shake, 0.08)
    end

    local was_grounded = player.on_ground
    local prev_x = player.x
    local prev_y = player.y
    local prev_bottom = prev_y + player.h

    player.vy = player.vy + GRAVITY * dt
    player.x = player.x + player.vx * dt
    player.y = player.y + player.vy * dt

    if player.x < 0 then
        player.x = 0
        player.vx = 0
    end
    if player.x + player.w > SW then
        player.x = SW - player.w
        player.vx = 0
    end

    player.on_ground = false

    local new_bottom = player.y + player.h
    local found_landing = false
    local landing_y = FLOOR_Y

    if prev_bottom <= FLOOR_Y and new_bottom >= FLOOR_Y and player.vy >= 0 then
        found_landing = true
        landing_y = FLOOR_Y
    end

    for i = 1, #platforms do
        local p = platforms[i]
        local overlap_x = player.x + player.w > p.x and player.x < p.x + p.w
        if overlap_x and prev_bottom <= p.y and new_bottom >= p.y and player.vy >= 0 then
            if not found_landing or p.y < landing_y then
                found_landing = true
                landing_y = p.y
            end
        end
    end

    if found_landing then
        local impact_vy = player.vy
        player.y = landing_y - player.h
        player.vy = 0
        player.on_ground = true

        if not was_grounded and impact_vy > 220 then
            local strength = clamp((impact_vy - 220) / 900, 0, 1)
            player.land_fx = 0.22
            player.jump_fx = 0
            spawn_land_burst(player.x + player.w * 0.5, player.y + player.h, strength)
            shake = math.max(shake, 0.10 + strength * 0.16)
        end
    end

    for i = #particles, 1, -1 do
        local p = particles[i]
        p.vy = p.vy + p.gravity * dt
        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt
        p.life = p.life - dt
        if p.life <= 0 then
            table.remove(particles, i)
        end
    end
end

function runtime.draw()
    local sx = (math.random() - 0.5) * 16 * shake
    local sy = (math.random() - 0.5) * 16 * shake

    gfx.clear(rgba(16, 14, 28, 255))

    -- background base bands
    for i = 0, 9 do
        local band_y = i * 80 + math.sin(t * 0.7 + i * 0.65) * 18
        local r = 30 + i * 10
        local g = 18 + i * 7
        local b = 60 + i * 14
        gfx.draw_rect(0, band_y, SW, 90, rgba(r, g, b, 255))
    end

    -- drifting color bars
    gfx.set_blend_mode("add")
    for i = 1, 20 do
        local c = rainbow[(i - 1) % #rainbow + 1]
        local x = ((i * 103) + t * (30 + i * 7)) % (SW + 300) - 150
        local y = ((i * 47) + math.sin(t * 1.5 + i) * 110) % SH
        local w = 60 + (i % 5) * 24
        local h = 16 + (i % 4) * 8
        gfx.draw_rect(x, y, w, h, rgba(c[1], c[2], c[3], 52))
    end

    -- sparkly confetti stars
    for i = 1, 60 do
        local c = rainbow[(i - 1) % #rainbow + 1]
        local x = ((i * 173) + t * (18 + i * 1.7)) % (SW + 40) - 20
        local y = ((i * 89) + math.sin(t * 1.9 + i * 0.4) * 80) % (SH - 120)
        local s = 3 + (i % 4)
        gfx.draw_rect(x, y, s, s, rgba(c[1], c[2], c[3], 110))
    end
    gfx.set_blend_mode("blend")

    -- moving freedom banner glow
    local tx = 170 + math.sin(t * 1.35) * 210
    local ty = 40 + math.cos(t * 2.1) * 18

    gfx.set_blend_mode("add")
    gfx.draw_rect(tx - 18, ty - 10, 430, 22, rgba(90, 200, 255, 60))
    gfx.draw_rect(tx - 28, ty - 16, 450, 34, rgba(255, 90, 220, 35))
    gfx.draw_rect(tx - 40, ty - 22, 475, 46, rgba(255, 220, 90, 20))
    gfx.set_blend_mode("blend")

    gfx.debug_text(tx, ty, "I DID IT CONNOR, WE'RE FREE")
    gfx.debug_line(tx - 6, ty + 18, tx + 330 + math.sin(t * 4.0) * 40, ty + 18, rgba(100, 220, 255, 220))
    gfx.debug_line(tx - 6, ty + 22, tx + 300 + math.cos(t * 3.2) * 55, ty + 22, rgba(255, 120, 200, 180))

    -- world
    gfx.begin_transform()
        gfx.set_translation(sx, sy)

        -- floor
        gfx.draw_rect(0, FLOOR_Y, SW, SH - FLOOR_Y, rgba(36, 28, 20, 255))
        gfx.draw_rect(0, FLOOR_Y, SW, 8, rgba(255, 210, 90, 255))

        gfx.set_blend_mode("add")
        gfx.draw_rect(0, FLOOR_Y - 8, SW, 24, rgba(255, 140, 60, 65))
        gfx.set_blend_mode("blend")

        -- platforms
        for i = 1, #platforms do
            local p = platforms[i]
            local c = rainbow[(i - 1) % #rainbow + 1]

            gfx.draw_rect(p.x, p.y, p.w, p.h, rgba(34, 36, 48, 255))
            gfx.draw_rect(p.x, p.y, p.w, 5, rgba(c[1], c[2], c[3], 255))
            gfx.draw_rect(p.x + 8, p.y + 7, p.w - 16, 5, rgba(255, 255, 255, 40))
        end

        -- player shadow
        local shadow_w = 26 + math.abs(player.vx) * 0.02
        gfx.draw_rect(
            player.x + player.w * 0.5 - shadow_w * 0.5,
            player.y + player.h + 6,
            shadow_w,
            8,
            rgba(0, 0, 0, 90)
        )

        -- particles
        gfx.set_blend_mode("add")
        for i = 1, #particles do
            local p = particles[i]
            local alpha = math.floor((p.life / p.max_life) * 255)
            local glow = p.size + 4
            gfx.draw_rect(
                p.x - glow * 0.5,
                p.y - glow * 0.5,
                glow,
                glow,
                rgba(p.r, p.g, p.b, math.floor(alpha * 0.25))
            )
        end
        gfx.set_blend_mode("blend")

        for i = 1, #particles do
            local p = particles[i]
            local alpha = math.floor((p.life / p.max_life) * 255)
            gfx.draw_rect(
                p.x - p.size * 0.5,
                p.y - p.size * 0.5,
                p.size,
                p.size,
                rgba(p.r, p.g, p.b, alpha)
            )
        end

        -- player body
        local run_tilt = clamp(player.vx / MAX_RUN, -1, 1) * 0.16
        local air_tilt = clamp(player.vy / 1200, -1, 1) * 0.05
        local body_rot = run_tilt + air_tilt

        local jump_stretch = player.jump_fx * 18
        local land_squash = player.land_fx * 16

        local body_w = clamp(player.w - jump_stretch * 0.35 + land_squash, 26, 70)
        local body_h = clamp(player.h + jump_stretch - land_squash * 0.45, 34, 86)

        local px = player.x + player.w * 0.5
        local py = player.y + player.h * 0.5

        gfx.set_blend_mode("add")
        gfx.begin_transform()
            gfx.set_translation(px, py)
            gfx.set_rotation(body_rot)
            gfx.set_origin(body_w * 0.5 + 6, body_h * 0.5 + 6)
            gfx.draw_rect(0, 0, body_w + 12, body_h + 12, rgba(90, 220, 255, 42))
        gfx.end_transform()
        gfx.set_blend_mode("blend")

        gfx.begin_transform()
            gfx.set_translation(px, py)
            gfx.set_rotation(body_rot)
            gfx.set_origin(body_w * 0.5, body_h * 0.5)

            -- main body
            gfx.draw_rect(0, 0, body_w, body_h, rgba(90, 235, 255, 255))

            -- face stripe
            gfx.draw_rect(6, 10, body_w - 12, 12, rgba(255, 120, 220, 230))

            -- eyes
            local eye_y = 12
            local eye_x1 = body_w * 0.28
            local eye_x2 = body_w * 0.62
            gfx.draw_rect(eye_x1, eye_y, 6, 6, rgba(12, 16, 30, 255))
            gfx.draw_rect(eye_x2, eye_y, 6, 6, rgba(12, 16, 30, 255))

            -- little legs
            gfx.draw_rect(8, body_h - 8, 8, 8, rgba(255, 230, 120, 255))
            gfx.draw_rect(body_w - 16, body_h - 8, 8, 8, rgba(255, 230, 120, 255))
        gfx.end_transform()

        -- celebratory trail while airborne
        if not player.on_ground then
            gfx.set_blend_mode("add")
            for i = 1, 4 do
                local trail_x = px - player.vx * 0.02 * i - i * 8 * player.facing
                local trail_y = py + i * 4
                local c = cool[(i - 1) % #cool + 1]
                gfx.draw_rect(trail_x, trail_y, 10 - i, 10 - i, rgba(c[1], c[2], c[3], 80 - i * 12))
            end
            gfx.set_blend_mode("blend")
        end
    gfx.end_transform()

    -- screen flash
    if flash > 0 then
        gfx.set_blend_mode("add")
        gfx.draw_rect(0, 0, SW, SH, rgba(255, 255, 255, math.floor(flash * 90)))
        gfx.set_blend_mode("blend")
    end

    -- UI
    gfx.debug_text(20, SH - 92, "A/D or LEFT/RIGHT: move")
    gfx.debug_text(20, SH - 72, "SPACE / W / UP: jump")
    gfx.debug_text(20, SH - 52, "LMB: rainbow explosion   |   R: reset")
    gfx.debug_text(20, SH - 32, string.format("x=%.0f  y=%.0f  vx=%.0f  vy=%.0f  grounded=%s",
        player.x, player.y, player.vx, player.vy, tostring(player.on_ground)))
end