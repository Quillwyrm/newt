local gfx = graphics

-- Global Color Palette (Prevents GC Thrashing)
local C = {
    BG          = {25, 25, 30, 255},
    WHITE       = {255, 255, 255, 255},
    RED         = {255, 0, 0, 255},
    YELLOW      = {255, 255, 0, 255},
    UI_TEXT     = {200, 200, 200, 255},
    FPS_GREEN   = {0, 255, 100, 255},
    BAR_BG      = {10, 10, 15, 200},
    -- Pre-calculated palettes for loops
    FLOOR       = {}, 
    TRAIL       = {}
}

-- Pre-generate loop colors once
for i = 0, 10 do
    C.FLOOR[i] = {40 + (i*10), 40, 60, 255}
end
for i = 1, 5 do
    C.TRAIL[i] = {255, 255, 0, 50 * i}
end

-- State
local player_img = nil
local player_atlas = nil -- New Atlas state
local px, py = 400, 300
local p_scale = 2.0
local timer = 0
local last_dt = 0

local snd_sfx = nil
local snd_music = nil

runtime.init = function()
    window.init(1280, 720, "Full API & Movement Test", {"resizable"})
    
    gfx.set_default_filter("linear")
    -- Load Image
    local img, err = gfx.load_image("player.png")
    if img then 
        player_img = img 
    else
        print("Error loading image:", err)
    end

    -- Load Atlas (615 / 5 = 123)
    local atlas, a_err = gfx.load_atlas("player.png", 123, 123)
    if atlas then
        player_atlas = atlas
    else
        print("Error loading atlas:", a_err)
    end
    

    
    -- Audio Test
    local sfx, sfx_err = audio.load_sound("test_sfx.wav", "static")
    if sfx then 
        snd_sfx = sfx 
        print("Static SFX Loaded to RAM")
    else 
        print("SFX Error:", sfx_err) 
    end

    local bgm, bgm_err = audio.load_sound("test_bgm.ogg", "stream")
    if bgm then 
        snd_music = bgm 
        print("Stream BGM Ready")
    else 
        print("BGM Error:", bgm_err) 
    end
    
    audio.play(bgm,1,.5,.8)
end

runtime.update = function(dt)
    timer = timer + dt
    last_dt = dt

    local speed = 300 * dt
    if input.down("w") or input.down("up")    then py = py - speed end
    if input.down("s") or input.down("down")  then py = py + speed end
    if input.down("a") or input.down("left")  then px = px - speed end
    if input.down("d") or input.down("right") then px = px + speed end

    if input.down("q") then p_scale = p_scale - dt end
    if input.down("e") then p_scale = p_scale + dt end
    if input.pressed("e") then audio.play(snd_sfx,2,.2,p_scale*2) end

    if input.pressed("escape") then window.close() end
    
    -- Test manual release vs GC sweep
    if input.pressed("backspace") then
        if snd_sfx then
            print("Manually releasing SFX...")
            release(snd_sfx)
            snd_sfx = nil -- Remove Lua's reference so GC ignores it later
        end
    end
    
end

runtime.draw = function()
    -- 1. Background
    gfx.clear(C.BG)
    
    -- 2. Floor Rects
    for i = 0, 10 do
        gfx.draw_rect(i * 120, 500, 100, 200, C.FLOOR[i])
    end

    -- 3. NEW: Atlas Sprite Demo
    -- Draw a row of different sprite indices with different tints
    if player_atlas then
        for i = 0, 4 do
            -- Subject-First: (atlas, idx, x, y, [color])
            gfx.draw_sprite(player_atlas, i+20, 500 + (i * 200), 100, {255, 255 - (i * 40), 255, 255})
        end

        -- Animate a sprite index over time (Cycles 0-24)
        local animated_idx = math.floor(timer * 10) % 25
        gfx.draw_debug_text(800, 200, "Animated Sprite Index: " .. animated_idx, C.WHITE)
        gfx.draw_sprite(player_atlas, animated_idx, 800, 220, C.WHITE)
    end

    -- 4. draw_image_region Trail
    for i = 1, 5 do
        gfx.set_draw_rotation(timer * 50 + (i * 20))
        gfx.draw_image_region(player_img, 0, 0, 400, 400, 100 + (i * 40), 100, C.TRAIL[i])
    end

    -- 5. Player & Grouped Hat
    local iw, ih = gfx.get_image_size(player_img)
    
    gfx.begin_transform_group()
        gfx.set_draw_origin(iw/2, ih/2)
        gfx.set_draw_rotation(math.sin(timer * 4) * 20)
        gfx.set_draw_scale(p_scale, p_scale)

        gfx.draw_image(player_img, px, py, C.WHITE)
        gfx.draw_rect(px - 10, py - 25, 20, 10, C.RED)
    gfx.end_transform_group()

    -- 6. Static UI Bar
    gfx.draw_rect(0, 680, 1280, 40, C.BAR_BG)
    
    local fps = last_dt > 0 and math.floor(1 / last_dt) or 0
    gfx.draw_debug_text(20, 20, "WASD to Move | Q/E to Scale", C.UI_TEXT)
    gfx.draw_debug_text(20, 40, string.format("Pos: %.1f, %.1f  Scale: %.2f", px, py, p_scale), C.WHITE)
    gfx.draw_debug_text(20, 690, "FPS: " .. fps, C.FPS_GREEN)

    -- Pivot Verification Pixel
    gfx.draw_rect(px - 1, py - 1, 2, 2, C.YELLOW)
end
