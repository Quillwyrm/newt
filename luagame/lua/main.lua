local gfx = graphics
local W, H = 640, 360 

local C = {
  BG     = 0x0F0F14FF,
  PLAYER = 0xFFFFFFFF,
  ENEMY  = 0xFF0000FF,
  HOVER  = 0xFFFF00FF,
}

local player_img, hw, hh
local cam     = { x = 0, y = 0, scale = 1.5, lerp = 8 }
local entities = {}

-- POD factory
local function new_entity(x, y, sprite)
    return {
        x = x, y = y, rot = 0, 
        sx = 1, sy = 1, 
        sprite = sprite,
        hovered = false
    }
end

-- Procedural Wrapper
local function draw_entity(e, mx, my)
    local w, h = gfx.get_image_size(e.sprite)
    
    gfx.begin_transform()
        gfx.set_translation(e.x, e.y)
        gfx.set_rotation(e.rot)
        gfx.set_scale(e.sx, e.sy)
        gfx.set_origin(w/2, h/2) 

        -- Project mouse directly into entity space
        local lx, ly = gfx.screen_to_local(mx, my)
        
        -- Simple AABB hit test on the 'un-transformed' sprite dimensions
        e.hovered = (lx >= 0 and lx <= w) and (ly >= 0 and ly <= h)

        gfx.draw_image(e.sprite, 0, 0, e.hovered and C.HOVER or C.PLAYER)
    gfx.end_transform()
end

runtime.init = function()
    window.init(W*2, H*2, "Procedural Entity System")
    local tex = gfx.load_image("player.png")
    for i = 1, 50 do
        table.insert(entities, new_entity(math.random(-500, 500), math.random(-500, 500), tex))
    end
    -- Set image metrics once
    hw, hh = gfx.get_image_size(tex)
    hw, hh = hw/2, hh/2
end

runtime.update = function(dt)
    -- Camera Lag
    cam.x = cam.x + (0 - cam.x) * (cam.lerp * dt)
    cam.y = cam.y + (0 - cam.y) * (cam.lerp * dt)

    for _, e in ipairs(entities) do
        e.rot = e.rot + dt
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
end