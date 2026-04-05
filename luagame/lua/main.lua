local gfx = graphics
local bit = require("bit")

local function rgba(r, g, b, a) return bit.bor(bit.lshift(r, 24), bit.lshift(g, 16), bit.lshift(b, 8), a) end
local function clamp(val, min, max) return val < min and min or (val > max and max or val) end

-- Global Setup
local SW, SH = 1280, 720
local WORLD_SIZE = 2048

-- Hardware/Software Buffers
local world_canvas
local pmap_asteroids
local img_asteroids
local player_img

-- Camera/Drone State
local cam = { x = 1024, y = 1024, zoom = 0.8, angle = 0, speed = 800 }

-- Game State
local swarm = {}
local particles = {}
local laser = { active = false, target_x = 0, target_y = 0, hit = false }

function runtime.init()
    window.init(SW, SH, "Luagame - Deep Space Mining operations")
    
    world_canvas = gfx.new_canvas(WORLD_SIZE, WORLD_SIZE)
    player_img = gfx.load_image("player.png")

    -- 1. Generate Destructible Terrain (CPU Side)
    pmap_asteroids = gfx.new_pixelmap(WORLD_SIZE, WORLD_SIZE)
    gfx.blit_rect(pmap_asteroids, 0, 0, WORLD_SIZE, WORLD_SIZE, rgba(0, 0, 0, 0), "replace")
    
    math.randomseed(os.time())
    for i = 1, 300 do
        local ax, ay = math.random(WORLD_SIZE), math.random(WORLD_SIZE)
        local ar = math.random(20, 80)
        gfx.blit_circle(pmap_asteroids, ax, ay, ar, rgba(60, 60, 70, 255), "replace")
        -- Inner crater details
        gfx.blit_circle(pmap_asteroids, ax + math.random(-10, 10), ay + math.random(-10, 10), ar * 0.6, rgba(50, 50, 60, 255), "replace")
    end
    
    -- 2. Push initial state to GPU
    img_asteroids = gfx.new_image_from_pixelmap(pmap_asteroids)

    -- Spawn Swarm
    for i = 1, 50 do
        table.insert(swarm, {
            x = math.random(WORLD_SIZE), y = math.random(WORLD_SIZE),
            angle = math.random() * math.pi * 2, speed = math.random(100, 250)
        })
    end
end

function runtime.update(dt)
    -- =========================================================
    -- 1. CAMERA MOVEMENT (Absolute World Axis)
    -- =========================================================
    if input.down("w") then cam.y = cam.y - cam.speed * dt end
    if input.down("s") then cam.y = cam.y + cam.speed * dt end
    if input.down("a") then cam.x = cam.x - cam.speed * dt end
    if input.down("d") then cam.x = cam.x + cam.speed * dt end

    if input.down("q") then cam.zoom = cam.zoom * (1 - 2 * dt) end
    if input.down("e") then cam.zoom = cam.zoom * (1 + 2 * dt) end
    if input.down("r") then cam.angle = cam.angle - 1.5 * dt end
    if input.down("t") then cam.angle = cam.angle + 1.5 * dt end

    cam.zoom = clamp(cam.zoom, 0.1, 4.0)

    -- =========================================================
    -- 2. SCREEN-TO-WORLD MOUSE PROJECTION
    -- =========================================================
    local mx, my = input.get_mouse_position()
    
    -- Center offset
    local dx, dy = mx - (SW / 2), my - (SH / 2)
    -- Un-scale
    dx, dy = dx / cam.zoom, dy / cam.zoom
    -- Un-rotate (Inverse Rotation Matrix)
    local cos_a, sin_a = math.cos(-cam.angle), math.sin(-cam.angle)
    local wdx = dx * cos_a - dy * sin_a
    local wdy = dx * sin_a + dy * cos_a
    
    -- Final World Coordinate of the Mouse
    local world_mx = cam.x + wdx
    local world_my = cam.y + wdy

    -- =========================================================
    -- 3. MINING LASER RAYCAST
    -- =========================================================
    laser.active = input.down("mouse1")
    laser.hit = false
    laser.target_x, laser.target_y = world_mx, world_my

    if laser.active then
        -- Cast vector from Drone (cam.x, cam.y) to World Mouse
        local lx, ly = world_mx - cam.x, world_my - cam.y
        local len = math.sqrt(lx*lx + ly*ly)
        if len > 0 then lx, ly = lx/len, ly/len end
        
        local max_dist = 1000
        local far_x = cam.x + (lx * max_dist)
        local far_y = cam.y + (ly * max_dist)

        local hit, hx, hy = gfx.pixelmap_raycast(pmap_asteroids, math.floor(cam.x), math.floor(cam.y), math.floor(far_x), math.floor(far_y))
        
        if hit then
            laser.hit = true
            laser.target_x, laser.target_y = hx, hy
            
            -- CPU: Carve the asteroid
            local carve_radius = 12
            gfx.blit_circle(pmap_asteroids, hx, hy, carve_radius, rgba(0,0,0,0), "erase")
            
            -- GPU: Partial Sync (Only update the destroyed bounding box to VRAM)
            local rx = clamp(hx - carve_radius, 0, WORLD_SIZE - (carve_radius*2))
            local ry = clamp(hy - carve_radius, 0, WORLD_SIZE - (carve_radius*2))
            gfx.update_image_region_from_pixelmap(img_asteroids, pmap_asteroids, rx, ry, carve_radius*2, carve_radius*2, rx, ry)

            -- Spawn VFX
            table.insert(particles, { x = hx, y = hy, vx = (math.random()-0.5)*400, vy = (math.random()-0.5)*400, life = 1.0 })
        else
            laser.target_x, laser.target_y = far_x, far_y
        end
    end

    -- Update Swarm & Particles
    for _, ship in ipairs(swarm) do
        ship.x = ship.x + math.cos(ship.angle) * ship.speed * dt
        ship.y = ship.y + math.sin(ship.angle) * ship.speed * dt
        if ship.x < 0 then ship.x = WORLD_SIZE elseif ship.x > WORLD_SIZE then ship.x = 0 end
        if ship.y < 0 then ship.y = WORLD_SIZE elseif ship.y > WORLD_SIZE then ship.y = 0 end
    end
    
    for i = #particles, 1, -1 do
        local p = particles[i]
        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt
        p.life = p.life - dt * 2
        if p.life <= 0 then table.remove(particles, i) end
    end
end

function runtime.draw()
    -- =========================================================
    -- VRAM PASS 1: THE WORLD
    -- =========================================================
    gfx.set_canvas(world_canvas)
    gfx.clear(rgba(10, 12, 15, 255))
    
    -- Draw GPU Texture generated by CPU Pixelmap
    gfx.draw_image(img_asteroids, 0, 0)

    gfx.set_blend_mode("add")
    
    -- Draw Swarm
    for _, ship in ipairs(swarm) do
        gfx.begin_transform()
            gfx.set_translation(ship.x, ship.y)
            gfx.set_rotation(ship.angle)
            gfx.set_origin(16, 16)
            gfx.draw_image(player_img, 0, 0)
        gfx.end_transform()
    end

    -- Draw Particles (FIXED: Using VRAM draw_rect instead of CPU blit_rect)
    for _, p in ipairs(particles) do
        gfx.draw_rect(p.x, p.y, 4, 4, rgba(255, 100, 0, math.floor(p.life * 255))) 
        gfx.draw_rect(p.x + 1, p.y + 1, 2, 2, rgba(255, 150, 50, math.floor(p.life * 255)))
    end

    -- Draw Laser
    if laser.active then
        gfx.begin_transform()
            gfx.set_translation(cam.x, cam.y)
            local lx, ly = laser.target_x - cam.x, laser.target_y - cam.y
            local dist = math.sqrt(lx*lx + ly*ly)
            gfx.set_rotation(math.atan2(ly, lx))
            
            -- Draw a glowing laser beam
            gfx.draw_rect(0, -2, dist, 4, rgba(255, 50, 50, 255))
            gfx.draw_rect(0, -6, dist, 12, rgba(255, 0, 0, 100))
        gfx.end_transform()

        if laser.hit then
            gfx.draw_rect(laser.target_x - 10, laser.target_y - 10, 20, 20, rgba(255, 255, 255, 200))
        end
    end
    
    -- Drone Body (FIXED: VRAM doesn't have circle primitives, using a rect)
    gfx.draw_rect(cam.x - 10, cam.y - 10, 20, 20, rgba(0, 255, 255, 255))

    gfx.set_blend_mode("blend")
    gfx.set_canvas()

    -- =========================================================
    -- VRAM PASS 2: CAMERA RENDER
    -- =========================================================
    gfx.clear(rgba(5, 5, 5, 255))

    gfx.begin_transform()
        gfx.set_translation(SW / 2, SH / 2)
        gfx.set_scale(cam.zoom)
        gfx.set_rotation(cam.angle)
        gfx.set_origin(cam.x, cam.y)

        gfx.set_blend_mode("premultiplied")
        gfx.draw_image(world_canvas, 0, 0)
        gfx.set_blend_mode("blend")
        
        gfx.debug_rect(0, 0, WORLD_SIZE, WORLD_SIZE, rgba(255,255,255,50))
    gfx.end_transform()

    -- =========================================================
    -- PASS 3: SCREEN-SPACE UI
    -- =========================================================
    gfx.debug_text(20, 20, "ASTEROID MINING DRONE OVERRIDE")
    gfx.debug_text(20, 40, string.format("POS: %.0f, %.0f", cam.x, cam.y))
    gfx.debug_text(20, 60, "WASD: Pan (Absolute) | Q/E: Zoom | R/T: Rotate")
    gfx.debug_text(20, 80, "LMB: Fire Mining Laser")
    
    local mx, my = input.get_mouse_position()
    gfx.debug_line(mx - 10, my, mx + 10, my, rgba(0, 255, 255, 200))
    gfx.debug_line(mx, my - 10, mx, my + 10, rgba(0, 255, 255, 200))
end