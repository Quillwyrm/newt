local gfx = graphics

-- =============================================================================
-- Engine Configuration (MUST BE BEFORE ENGINE INIT)
-- =============================================================================
audio.config_track_delay_times({ 
    [1] = 0, 
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
    UI_TEXT     = rgba(180, 180, 180, 255),
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
local current_filter = "NONE"
local delay_active = false

-- Filter Sweep State (Track 2)
local current_lpf = 20000

-- =============================================================================
-- Helpers
-- =============================================================================

local function apply_filter_preset(track_id, label, lpf, hpf)
    current_filter = label
    
    -- If not underwater, snap the filters immediately
    if label ~= "UNDERWATER" then
        current_lpf = lpf
        audio.set_track_lpf(track_id, current_lpf)
        audio.set_track_hpf(track_id, hpf)
    else
        -- When entering underwater, just snap the HPF. 
        -- The LPF will be taken over by the sweep in the update loop.
        audio.set_track_hpf(track_id, hpf)
    end
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

    audio.set_track_delay_feedback(3, 0.5)
    audio.set_track_delay_feedback(4, 0.5)
    audio.set_track_delay_feedback(5, 0.5)
end

runtime.update = function(dt)
    timer = timer + dt

    -- 0. Process Filter Sweep (Continuous Wub Wub for UNDERWATER)
    if current_filter == "UNDERWATER" then
        -- Generate a sine wave that goes from -1 to 1 based on time
        local sweep_osc = math.sin(timer * 2.0)
        
        -- Map the oscillator (-1 to 1) to a frequency range (e.g., 200Hz to 3000Hz)
        -- We map it exponentially so the sweep sounds natural to human ears
        local min_freq = 200
        local max_freq = 3000
        
        -- Normalize sine to 0.0 - 1.0
        local normalized_sweep = (sweep_osc + 1.0) / 2.0
        
        -- Logarithmic mapping
        current_lpf = min_freq * math.exp(normalized_sweep * math.log(max_freq / min_freq))
        
        -- Apply it every frame
        audio.set_track_lpf(2, current_lpf)
    end

    -- 1. Player Movement & Velocity (WASD + Arrows)
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
    end

    -- 4. INPUT MAPPINGS
    
    -- [SPACE] Play 2D (Pan follows Screen X)
    if input.pressed("space") then
        local pan = (px / 1280) * 2 - 1 
        audio.play(snd_sfx, 1, 0.5, 1.0, pan)
    end

    -- [Z] Play SPATIAL (Red Box)
    if input.pressed("z") then
        audio.play_at(snd_sfx, 1, 400, 400, 0.8)
    end

    -- [X] Toggle Drone (Cyan)
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

    -- [C] Toggle Ambient (Magenta)
    if input.pressed("c") then
        ambient.active = not ambient.active
        if ambient.active then
            ambient.handle = audio.play_at(snd_sfx, 1, ambient.x, ambient.y, 0.5)
            audio.set_voice_looping(ambient.handle, true)
        else
            audio.stop_voice(ambient.handle)
        end
    end

    -- [4, 5, 6] Test Multi-Track Delays
    if input.pressed("4") then audio.play(snd_sfx, 3, 0.8) end 
    if input.pressed("5") then audio.play(snd_sfx, 4, 0.8) end 
    if input.pressed("6") then audio.play(snd_sfx, 5, 0.8) end 

    -- [1, 2, 3] Filter Presets (Track 2 - Music)
    if input.pressed("1") then apply_filter_preset(2, "NONE", 20000, 10) end
    if input.pressed("2") then apply_filter_preset(2, "UNDERWATER", 600, 10) end
    if input.pressed("3") then apply_filter_preset(2, "RADIO", 20000, 2000) end

    -- [E] Toggle Delay (Track 1 SFX)
    if input.pressed("e") then
        delay_active = not delay_active
        local mix = delay_active and 0.5 or 0.0
        local feedback = delay_active and 0.8 or 0.0
 
        audio.set_track_delay_feedback(1, feedback)
    end

    -- [Q] Pause/Resume BGM
    if input.pressed("q") then
        if bgm_paused then audio.resume_voice(bgm_handle) else audio.pause_voice(bgm_handle) end
        bgm_paused = not bgm_paused
    end

    -- [F] Master Fade
    if input.pressed("f") then
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
    
    if input.pressed("t") then
        local time, duration = audio.get_voice_info(bgm_handle)
        print(string.format("Time: %f / %f", time, duration))
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

    -- GUI Background
    gfx.set_draw_origin(0, 0); gfx.set_draw_scale(1.0)
    gfx.draw_rect(0, 560, 1280, 160, C.BAR_BG)
    
    local col1 = 20
    local col2 = 450
    local col3 = 850

    -- Column 1: Audio Triggers
    gfx.draw_debug_text(col1, 575, "-- TRIGGERS --", C.UI_TEXT)
    gfx.draw_debug_text(col1, 595, "[SPACE] Fire 2D SFX", C.WHITE)
    gfx.draw_debug_text(col1, 615, "[Z] Fire Spatial SFX (Red Box)", C.RED)
    gfx.draw_debug_text(col1, 635, "[X] Toggle Drone (Cyan)", C.CYAN)
    gfx.draw_debug_text(col1, 655, "[C] Toggle Ambient (Magenta)", C.MAGENTA)

    -- Column 2: Track Modifiers & Delays
    gfx.draw_debug_text(col2, 575, "-- TRACK MODIFIERS --", C.UI_TEXT)
    gfx.draw_debug_text(col2, 595, "[1/2/3] BGM Filter Presets: " .. current_filter, C.YELLOW)
    gfx.draw_debug_text(col2, 615, string.format("[E] Toggle Trk1 SFX Delay: %s", delay_active and "ON" or "OFF"), C.YELLOW)
    gfx.draw_debug_text(col2, 645, "-- MULTI-TRACK DELAY TEST --", C.UI_TEXT)
    gfx.draw_debug_text(col2, 665, "[4] Slapback | [5] Echo | [6] Canyon", C.WHITE)

    -- Column 3: Globals
    gfx.draw_debug_text(col3, 575, "-- GLOBALS & BGM --", C.UI_TEXT)
    gfx.draw_debug_text(col3, 595, string.format("[Q] Play/Pause BGM: %s", bgm_paused and "PAUSED" or "PLAYING"), C.WHITE)
    gfx.draw_debug_text(col3, 615, string.format("[F] Fade Master: %s", master_muted and "MUTED" or "LOUD"), C.WHITE)
    gfx.draw_debug_text(col3, 635, "[R] Hold to Warble Pitch", C.WHITE)
    gfx.draw_debug_text(col3, 655, "[T] Print Timestamp to Console", C.WHITE)
    
    -- Sweep Debug
    if current_filter == "UNDERWATER" then
        gfx.draw_debug_text(col2, 550, string.format("LPF SWEEP: %.0f Hz", current_lpf), C.CYAN)
    else
        gfx.draw_debug_text(col2, 550, string.format("LPF: %.0f Hz", current_lpf), C.UI_TEXT)
    end
end
