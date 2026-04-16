local gfx = graphics

-- =============================================================================
-- Engine Configuration (MUST BE BEFORE ENGINE INIT)
-- =============================================================================
audio.config_bus_delay_times({ 
    [3] = 0.1,  
    [4] = 0.5, 
    [5] = 0.8   
})

-- =============================================================================
-- Configuration & State
-- =============================================================================

local C = {
    BG          = rgba(25, 25, 30, 255),
    WHITE       = rgba(255, 255, 255, 255),
    RED         = rgba(255, 50, 50, 255),
    YELLOW      = rgba(255, 220, 50, 255),
    CYAN        = rgba(50, 255, 255, 255),
    MAGENTA     = rgba(255, 50, 200, 255),
    UI_TEXT     = rgba(100, 100, 100, 255), 
    BAR_BG      = rgba(15, 15, 20, 230),
}

local player_img = nil
local px, py = 640, 360
local pvx, pvy = 0, 0 
local timer = 0

-- Moving Doppler Drone
local drone = { x = 0, y = 0, vx = 0, vy = 0, handle = 0, active = false }

-- Static Ambient Source
local ambient = { x = 900, y = 200, handle = 0, active = false }

-- Audio State
local snd_sfx, snd_music = nil, nil
local bgm_handle = 0
local bgm_paused = false
local master_muted = false
local delay_active = false

-- Filter State (bus 2)
local current_filter = "NONE"
local current_lpf, target_lpf = 20000, 20000
local current_hpf, target_hpf = 10, 10

-- =============================================================================
-- Helpers
-- =============================================================================

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function apply_filter_preset(bus_id, label, lpf, hpf)
    current_filter = label
    if label ~= "UNDERWATER" then
        target_lpf = lpf
        target_hpf = hpf
    else
        target_hpf = hpf
    end
end

local Res_Dir 

runtime.init = function()
    window.set_size(1280, 720)
    Res_Dir = filesystem.get_resource_directory()
    gfx.set_default_filter("linear")
    player_img = gfx.load_image(Res_Dir .. "/player.png")

    snd_sfx = audio.load_sound(Res_Dir .. "/test_sfx.wav", "static")
    snd_music = audio.load_sound(Res_Dir .. "/test_bgm.ogg", "stream")


    bgm_handle = audio.play(snd_music, 2, 0.1, 1.0)
    audio.set_voice_looping(bgm_handle, true)


    audio.set_bus_delay_feedback(3, 0.5)
    audio.set_bus_delay_feedback(4, 0.5)
    audio.set_bus_delay_feedback(5, 0.5)
end

runtime.update = function(dt)
    timer = timer + dt

    -- 0. Process Filter Interpolation
    local slide_speed = 15.0 * dt 

    if current_filter == "UNDERWATER" then
        local sweep_osc = math.sin(timer * 2.0)
        local min_freq = 200
        local max_freq = 3000
        local normalized_sweep = (sweep_osc + 1.0) / 2.0
        current_lpf = min_freq * math.exp(normalized_sweep * math.log(max_freq / min_freq))
        
        current_hpf = lerp(current_hpf, target_hpf, slide_speed)
    else
        current_lpf = lerp(current_lpf, target_lpf, slide_speed)
        current_hpf = lerp(current_hpf, target_hpf, slide_speed)
    end

    audio.set_bus_lpf(2, current_lpf)
    audio.set_bus_hpf(2, current_hpf)

    -- 1. Player Movement & Velocity
    local speed = 400
    local old_x, old_y = px, py
    if input.down("w") or input.down("up")    then py = py - speed * dt end
    if input.down("s") or input.down("down")  then py = py + speed * dt end
    if input.down("a") or input.down("left")  then px = px - speed * dt end
    if input.down("d") or input.down("right") then px = px + speed * dt end
    pvx, pvy = (px - old_x) / dt, (py - old_y) / dt

    -- 2. Sync Listener
    audio.set_listener_position(px, py)
    audio.set_listener_velocity(pvx, pvy)

    -- 3. Drone Movement
    if drone.active then
        local radius = 250
        local old_dx, old_dy = drone.x, drone.y
        drone.x = 640 + math.cos(timer * 2.5) * radius
        drone.y = 360 + math.sin(timer * 2.5) * radius
        drone.vx, drone.vy = (drone.x - old_dx) / dt, (drone.y - old_dy) / dt
        audio.set_voice_position(drone.handle, drone.x, drone.y)
        audio.set_voice_velocity(drone.handle, drone.vx, drone.vy)
    else
        drone.x = 640 + math.cos(timer * 2.5) * 250
        drone.y = 360 + math.sin(timer * 2.5) * 250
    end

    -- 3.5. AMBIENT SURVIVAL GUARD
    if ambient.active then
        if not audio.is_voice_playing(ambient.handle) then
            ambient.handle = audio.play_at(snd_sfx, 1, ambient.x, ambient.y, 0.5)
            audio.set_voice_looping(ambient.handle, true)
        end
    else
        audio.stop_voice(ambient.handle)
    end

    -- 4. INPUT MAPPINGS
    if input.pressed("space") then
        local pan = (px / 1280) * 2 - 1 
        audio.play(snd_sfx, 1, 0.5, 1.0, pan)
    end

    if input.pressed("z") then
        audio.play_at(snd_sfx, 1, 400, 400, 0.8)
    end

    if input.pressed("x") then
        drone.active = not drone.active
        if drone.active then
            drone.handle = audio.play(snd_music, 1, 0.4)
            audio.set_voice_looping(drone.handle, true)
            audio.set_voice_falloff(drone.handle, 50, 500)
        else
            audio.stop_voice(drone.handle)
        end
    end

    if input.pressed("c") then
        ambient.active = not ambient.active
    end

    -- Test Multi-bus Delays
    if input.pressed("4") then audio.play(snd_sfx, 3, 0.8) end 
    if input.pressed("5") then audio.play(snd_sfx, 4, 0.8) end 
    if input.pressed("6") then audio.play(snd_sfx, 5, 0.8) end 

    -- Filter Presets
    if input.pressed("1") then apply_filter_preset(2, "NONE", 20000, 10) end
    if input.pressed("2") then apply_filter_preset(2, "UNDERWATER", 600, 10) end
    if input.pressed("3") then apply_filter_preset(2, "RADIO", 20000, 2000) end

    -- Toggle Delay
    if input.pressed("e") then
        delay_active = not delay_active
        local feedback = delay_active and 0.8 or 0.0
        audio.set_bus_delay_feedback(1, feedback)
    end

    -- Pause/Resume BGM
    if input.pressed("q") then
        if bgm_paused then audio.resume_voice(bgm_handle) else audio.pause_voice(bgm_handle) end
        bgm_paused = not bgm_paused
    end

    -- Master Fade
    if input.pressed("f") then
        master_muted = not master_muted
        audio.fade_bus(0, master_muted and 0 or 1, 0.5) 
    end

    -- Hold for Warble
    if input.down("r") then
        local warble = 1.0 + math.sin(timer * 12) * 0.15
        audio.set_voice_pitch(bgm_handle, warble)
    else
        audio.set_voice_pitch(bgm_handle, 1.0)
    end
    
    if input.pressed("t") then
        local time, duration = audio.get_voice_info(bgm_handle)
        print(string.format("Time: %f / %f", time, duration))
    end
    
    if input.pressed("y") then
        for i = 1, 70 do
            audio.play(snd_sfx, 1, 0.01)
        end
    end

    if input.pressed("escape") then window.close() end
end

runtime.draw = function()
    gfx.clear(C.BG)
    
    -- Red Box (Transform block handles the origin shift)
    gfx.begin_transform()
        gfx.set_translation(400, 400)
        gfx.set_origin(10, 10)
        gfx.draw_rect(0, 0, 20, 20, C.RED)
    gfx.end_transform()
    
    gfx.debug_text(340, 430, "Spatial Static SFX", C.RED)

    -- Drone (Absolute math is fine since no scaling/rotation is needed)
    if drone.active then
        gfx.draw_rect(drone.x-10, drone.y-10, 20, 20, C.CYAN)
        gfx.debug_text(drone.x-40, drone.y+20, "Drone (ON)", C.CYAN)
    else
        gfx.draw_rect(drone.x-10, drone.y-10, 20, 20, C.UI_TEXT)
        gfx.debug_text(drone.x-40, drone.y+20, "Drone (OFF)", C.UI_TEXT)
    end

    -- Ambient (Absolute math is fine since no scaling/rotation is needed)
    if ambient.active then
        gfx.draw_rect(ambient.x-10, ambient.y-10, 20, 20, C.MAGENTA)
        gfx.debug_text(ambient.x-40, ambient.y+20, "Static Ambient (ON)", C.MAGENTA)
    else
        gfx.draw_rect(ambient.x-10, ambient.y-10, 20, 20, C.UI_TEXT)
        gfx.debug_text(ambient.x-40, ambient.y+20, "Static Ambient (OFF)", C.UI_TEXT)
    end

    -- Player Image (TRS block handles movement, scale, and origin offset)
    if player_img then
        gfx.begin_transform()
            gfx.set_translation(px, py)
            gfx.set_scale(0.15)
            gfx.set_origin(128, 128)
            gfx.draw_image(player_img, 0, 0, C.WHITE)
        gfx.end_transform()
    end

    -- UI Bar (Automatically draws in absolute screen coordinates)
    gfx.draw_rect(0, 560, 1280, 160, C.BAR_BG)
    
    local col1 = 20
    local col2 = 450
    local col3 = 850

    gfx.debug_text(col1, 575, "-- TRIGGERS --", C.UI_TEXT)
    gfx.debug_text(col1, 595, "[SPACE] Fire 2D SFX", C.WHITE)
    gfx.debug_text(col1, 615, "[Z] Fire Spatial SFX (Red Box)", C.RED)
    gfx.debug_text(col1, 635, "[X] Toggle Drone (Cyan)", C.CYAN)
    gfx.debug_text(col1, 655, "[C] Toggle Ambient (Magenta)", C.MAGENTA)

    gfx.debug_text(col2, 575, "-- bus MODIFIERS --", C.UI_TEXT)
    gfx.debug_text(col2, 595, "[1/2/3] BGM Filter Presets: " .. current_filter, C.YELLOW)
    gfx.debug_text(col2, 615, string.format("[E] Toggle Trk1 SFX Delay: %s", delay_active and "ON" or "OFF"), C.YELLOW)
    gfx.debug_text(col2, 645, "-- MULTI-bus DELAY TEST --", C.UI_TEXT)
    gfx.debug_text(col2, 665, "[4] Slapback | [5] Echo | [6] Canyon", C.WHITE)

    gfx.debug_text(col3, 575, "-- GLOBALS & BGM --", C.UI_TEXT)
    gfx.debug_text(col3, 595, string.format("[Q] Play/Pause BGM: %s", bgm_paused and "PAUSED" or "PLAYING"), C.WHITE)
    gfx.debug_text(col3, 615, string.format("[F] Fade Master: %s", master_muted and "MUTED" or "LOUD"), C.WHITE)
    gfx.debug_text(col3, 635, "[R] Hold to Warble Pitch", C.WHITE)
    gfx.debug_text(col3, 655, "[T] Print Timestamp to Console", C.WHITE)
    
    if current_filter == "UNDERWATER" then
        gfx.debug_text(col2, 550, string.format("LPF SWEEP: %.0f Hz", current_lpf), C.CYAN)
    else
        gfx.debug_text(col2, 550, string.format("LPF: %.0f Hz", current_lpf), C.UI_TEXT)
    end
end