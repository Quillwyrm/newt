local gfx = graphics

-- -- =============================================================================
-- -- API SPY (Prints every audio call to console)
-- -- =============================================================================
-- local _audio = audio
-- audio = {}
-- setmetatable(audio, {
--     __index = function(t, k)
--         local f = _audio[k]
--         if type(f) == "function" then
--             return function(...)
--                 local a1, a2 = ...
--                 print(string.format("[AUDIO TEST] %s(%s, %s, ...)", k, tostring(a1), tostring(a2)))
--                 return f(...)
--             end
--         end
--         return f
--     end
-- })

-- =============================================================================
-- Configuration & State
-- =============================================================================

local C = {
    BG          = {25, 25, 30, 255},
    WHITE       = {255, 255, 255, 255},
    RED         = {255, 0, 0, 255},
    YELLOW      = {255, 255, 0, 255},
    CYAN        = {0, 255, 255, 255},
    MAGENTA     = {255, 0, 255, 255},
    UI_TEXT     = {200, 200, 200, 255},
    FPS_GREEN   = {0, 255, 100, 255},
    BAR_BG      = {10, 10, 15, 200},
}

local player_img = nil
local px, py = 640, 360
local pvx, pvy = 0, 0 
local timer = 0
local last_dt = 0

-- Moving Doppler Drone
local drone = { x = 0, y = 0, vx = 0, vy = 0, handle = 0, active = false }

-- Static Ambient Source
local ambient = { x = 900, y = 200, handle = 0, active = false }

-- Audio State
local snd_sfx, snd_music = nil, nil
local bgm_handle = 0
local bgm_paused, bgm_looping = false, true
local master_muted = false
local current_filter = "NONE"
local delay_active = false -- Delay State

-- =============================================================================
-- Helpers
-- =============================================================================

-- Safely swaps track filters to prevent DSP "latching" or popping.
local function apply_filter_preset(track_id, label, lpf, hpf)
    current_filter = label
    
    -- 1. Quick dip in volume to hide the structural swap
    audio.fade_track(track_id, 0.0, 0.05)
    
    -- 2. Halt the DSP treadmill for this track
    audio.pause_track(track_id)
    
    -- 3. Perform the heavy coefficient re-initialization using the decoupled calls
    audio.set_track_lpf(track_id, lpf)
    audio.set_track_hpf(track_id, hpf)
    
    -- 4. Resume the treadmill with the new math and clean history buffers
    audio.resume_track(track_id)
    
    -- 5. Return to full volume
    audio.fade_track(track_id, 1.0, 0.05)
end

runtime.init = function()
    window.init(1280, 720, "Audio API Testbed", {"resizable"})
    gfx.set_default_filter("linear")
    player_img = gfx.load_image("player.png")

    snd_sfx = audio.load_sound("test_sfx.wav", "static")
    snd_music = audio.load_sound("test_bgm.ogg", "stream")

    if snd_music then
        bgm_handle = audio.play(snd_music, 2, 0.1, 1.0)
        audio.set_voice_looping(bgm_handle, true)
        
    end
end

runtime.update = function(dt)
    timer = timer + dt
    last_dt = dt

    -- 1. Player Movement & Velocity (Doppler)
    local speed = 400
    local old_x, old_y = px, py
    if input.down("w") then py = py - speed * dt end
    if input.down("s") then py = py + speed * dt end
    if input.down("a") then px = px - speed * dt end
    if input.down("d") then px = px + speed * dt end
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
    end

    -- 4. INPUT MAPPINGS
    
    -- [SPACE] Play 2D (Pan follows Screen X)
    if input.pressed("space") then
        local pan = (px / 1280) * 2 - 1 
        audio.play(snd_sfx, 1, 0.5, 1.0, pan)
    end

    -- [F] Play SPATIAL (Red Box)
    if input.pressed("f") then
        audio.play_at(snd_sfx, 1, 400, 400, 0.8)
    end

    -- [V] Toggle Drone (Cyan)
    if input.pressed("v") then
        drone.active = not drone.active
        if drone.active then
            drone.handle = audio.play(snd_music, 1, 0.4)
            audio.set_voice_looping(drone.handle, true)
            audio.set_voice_min_distance(drone.handle, 50)
            audio.set_voice_max_distance(drone.handle, 500)
        else
            audio.stop_voice(drone.handle)
        end
    end
    
    -- In runtime.update
if input.pressed("t") then
    local time, duration = audio.get_voice_info(bgm_handle)
  
        -- This will show 0.00 right at frame 1, 
        -- but will suddenly pop to the real duration after ~100ms.
        print(string.format("Time: %f / %f", time, duration))

end

    -- [B] Toggle Ambient (Magenta)
    if input.pressed("b") then
        ambient.active = not ambient.active
        if ambient.active then
            ambient.handle = audio.play_at(snd_sfx, 1, ambient.x, ambient.y, 0.5)
            audio.set_voice_looping(ambient.handle, true)
        else
            audio.stop_voice(ambient.handle)
        end
    end

    -- [P] Pause/Resume BGM
    if input.pressed("p") then
        if bgm_paused then audio.resume_voice(bgm_handle) else audio.pause_voice(bgm_handle) end
        bgm_paused = not bgm_paused
    end

    -- [L] Toggle Looping
    if input.pressed("l") then
        bgm_looping = not bgm_looping
        audio.set_voice_looping(bgm_handle, bgm_looping)
    end

    -- [M] Master Fade
    if input.pressed("m") then
        master_muted = not master_muted
        audio.fade_track(0, master_muted and 0 or 1, 0.5) 
    end

    -- [R] Hold for Warble
    if input.down("r") then
        local warble = 1.0 + math.sin(timer * 12) * 0.15
        audio.set_voice_pitch(bgm_handle, warble)
    else
        audio.set_voice_pitch(bgm_handle, 1.0)
    end

    -- [1, 2, 3] Filter Presets (Track 2 - Music)
    if input.pressed("1") then apply_filter_preset(2, "NONE", 20000, 10) end
    if input.pressed("2") then apply_filter_preset(2, "UNDERWATER", 600, 10) end
    if input.pressed("3") then apply_filter_preset(2, "RADIO", 20000, 2000) end

-- [E] Toggle Delay (Echo)
    if input.pressed("e") then
        delay_active = not delay_active
        -- 0.0 = Dry (Off), 0.6 = Noticeable Echo Tail
        local amount = delay_active and 0.15 or 0.0
        
        -- Changed from 2 (BGM) to 1 (SFX)
        audio.set_track_delay(1, amount) 
    end

    if input.pressed("escape") then window.close() end
end

runtime.draw = function()
    gfx.clear(C.BG)
    
    -- Draw Red Box (Spatial SFX Target)
    gfx.set_draw_origin(10, 10)
    gfx.draw_rect(400, 400, 20, 20, C.RED)
    gfx.set_draw_origin(0, 0)
    gfx.draw_debug_text(340, 430, "Spatial Static SFX", C.RED)

    -- Draw Doppler Drone (Cyan)
    if drone.active then
        gfx.draw_rect(drone.x-10, drone.y-10, 20, 20, C.CYAN)
    end

    -- Draw Static Ambient (Magenta)
    gfx.draw_rect(ambient.x-10, ambient.y-10, 20, 20, C.MAGENTA)
    gfx.draw_debug_text(ambient.x-40, ambient.y+20, "Static Ambient", C.MAGENTA)

    -- Draw Player
    if player_img then
        gfx.set_draw_origin(128, 128)
        gfx.set_draw_scale(0.15) 
        gfx.draw_image(player_img, px, py, C.WHITE)
    end

    -- UI
    gfx.set_draw_origin(0, 0); gfx.set_draw_scale(1.0)
    gfx.draw_rect(0, 580, 1280, 140, C.BAR_BG)
    
    local status = string.format("BGM: %s | Loop: %s | Filter: %s | Delay: %s", 
        bgm_paused and "PAUSED" or "PLAYING", bgm_looping and "ON" or "OFF", current_filter, delay_active and "ON" or "OFF")

    gfx.draw_debug_text(20, 595, "[SPACE] 2D SFX (Pan follows X) | [F] 3D SFX (Red Box)", C.UI_TEXT)
    gfx.draw_debug_text(20, 615, "[V] Toggle Drone (Doppler) | [B] Toggle Ambient (Static 3D)", C.CYAN)
    gfx.draw_debug_text(20, 635, "[P] Pause | [L] Loop | [M] Fade Master | [R] Hold Warble", C.YELLOW)
    gfx.draw_debug_text(20, 655, "[1/2/3] Track Filters | [E] Toggle Delay (BGM Track)", C.YELLOW)
    gfx.draw_debug_text(20, 685, status, C.WHITE)
end
