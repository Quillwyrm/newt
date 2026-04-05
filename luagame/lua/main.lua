local gfx = graphics
local W, H = 640, 360 

local C = {
    BG    = rgba(15, 15, 20, 255),
    HOVER = rgba(255, 255, 0, 255),
}

local cam      = { x = 0, y = 0, scale = 1.5, lerp = 8 }
local entities = {}

-- POD factory with velocity and randomized color
local function new_entity(x, y, w, h)
    return {
        x = x, y = y, rot = 0, 
        sx = 1, sy = 1, 
        w = w, h = h,
        vx = math.random(-100, 100),
        vy = math.random(-100, 100),
        color = rgba(math.random(50, 255), math.random(50, 255), math.random(50, 255), 255),
        hovered = false
    }
end

-- Procedural Wrapper
-- Procedural Wrapper
local function draw_entity(e, mx, my)
    gfx.begin_transform()
        gfx.set_translation(e.x, e.y)
        gfx.set_rotation(e.rot)
        gfx.set_scale(e.sx, e.sy)
        gfx.set_origin(e.w/2, e.h/2) 

        local lx, ly = gfx.screen_to_local(mx, my)
        e.hovered = (lx >= 0 and lx <= e.w) and (ly >= 0 and ly <= e.h)

        gfx.draw_rect(0, 0, e.w, e.h, e.hovered and C.HOVER or e.color)

        -- TEST 1: Velocity Vector (Projected to Screen)
        -- debug_line ignores the matrix, so we map local center to absolute screen space.
        local cx, cy = gfx.local_to_screen(e.w/2, e.h/2)
        gfx.debug_line(cx, cy, cx + (e.vx * 0.5), cy + (e.vy * 0.5), rgba(0, 255, 255, 255))
        
    gfx.end_transform()
end

runtime.init = function()
    window.init(W*2, H*2, "Procedural Rect System - Moving & Colored")
    
    for i = 1, 50 do
        local rand_w = math.random(16, 64)
        local rand_h = math.random(16, 64)
        table.insert(entities, new_entity(math.random(-500, 500), math.random(-500, 500), rand_w, rand_h))
    end
end

runtime.update = function(dt)
    cam.x = cam.x + (0 - cam.x) * (cam.lerp * dt)
    cam.y = cam.y + (0 - cam.y) * (cam.lerp * dt)

    for _, e in ipairs(entities) do
        -- Spin
        e.rot = e.rot + dt
        
        -- Move
        e.x = e.x + (e.vx * dt)
        e.y = e.y + (e.vy * dt)

        -- Simple bounds bounce
        if e.x > 500 or e.x < -500 then e.vx = -e.vx end
        if e.y > 500 or e.y < -500 then e.vy = -e.vy end
    end
end

runtime.draw = function()
    gfx.clear(C.BG)
    local mx, my = input.get_mouse_position()

    gfx.begin_transform()
        gfx.set_translation(W, H)
        gfx.set_scale(cam.scale, cam.scale)
        gfx.set_translation(-cam.x, -cam.y)

        for i = #entities, 1, -1 do
            local e = entities[i]
            draw_entity(e, mx, my)
            
            if e.hovered and input.down("mouse1") then
                table.remove(entities, i)
            end
        end
    gfx.end_transform()

    -- TEST 2: Static Screen-Space HUD 
    -- These ignore the camera transforms entirely.
    
    -- "UI" Box
    gfx.debug_rect(10, 10, 200, 50, rgba(255, 0, 0, 255))
    
    -- Mouse Crosshair
    gfx.debug_line(mx - 10, my, mx + 10, my, rgba(0, 255, 0, 255))
    gfx.debug_line(mx, my - 10, mx, my + 10, rgba(0, 255, 0, 255))
end