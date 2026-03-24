local gfx = graphics

-- =============================================================================
-- API SPY (Prints every audio call to console)
-- =============================================================================
local _audio = audio
audio = {}
setmetatable(audio, {
    __index = function(t, k)
        local f = _audio[k]
        if type(f) == "function" then
            return function(...)
                -- Print the call and the first two args (usually Handle/Track and Value)
                local a1, a2 = ...
                print(string.format("[AUDIO TEST] %s(%s, %s, ...)", k, tostring(a1), tostring(a2)))
                return f(...)
            end
        end
        return f
    end
})

-- =============================================================================
-- Configuration & State
-- =============================================================================

local C = {
    BG          = {25, 25, 30, 255},
    WHITE       = {255, 255, 255, 255},
    RED         = {255, 0, 0, 255},
    YELLOW      = {255, 255, 0, 255},
    UI_TEXT     = {200, 200, 200, 255},
    FPS_GREEN   = {0, 255, 100, 255},
    BAR_BG      = {10, 10, 15, 200},
}

local player_img = nil
local px, py = 640, 360
local p_scale = 2.0
local timer = 0
local last_dt = 0

-- Audio Handles
local snd_sfx = nil
local snd_music = nil
local bgm_handle = 0
local bgm_looping = false
local bgm_paused = false
local master_muted = false

runtime.init = function()
    window.init(1280, 720, "Audio API Testbed", {"resizable"})
    
    gfx.set_default_filter("linear")
    player_img = gfx.load_image("player.png")

    -- 1. Load Audio Assets
    snd_sfx = audio.load_sound("test_sfx.wav", "static")
    snd_music = audio.load_sound("test_bgm.ogg", "stream")

    -- 2. Start BGM on Track 2 (Music)
    if snd_music then
        bgm_handle = audio.play(snd_music, 2, 0.05, 1.0)
        --bgm_handle = audio.play_at(snd_music, 2,     400, 400, 0.4, 1.0)
        audio.set_voice_looping(bgm_handle, true)
        bgm_looping = true
    end
end

runtime.update = function(dt)
    timer = timer + dt
    last_dt = dt

    -- 1. Movement
    local speed = 400 * dt
    if input.down("w") or input.down("up")  then py = py - speed end
    if input.down("s") or input.down("down") then py = py + speed end
    if input.down("a") or input.down("left") then px = px - speed end
    if input.down("d") or input.down("right") then px = px + speed end

    -- 2. Update Audio Listener (Follows Player)
    audio.set_listener_position(px, py)

    -- 3. Trigger SFX
    -- [SPACE] Play 2D (Panned by screen position)
    if input.pressed("space") then
        local pan = (px / 1280) * 2 - 1 -- Map screen X to -1.0 -> 1.0
        audio.play(snd_sfx, 1, 0.5, 1.0, pan)
    end

    -- [F] Play SPATIAL (Locked to world position 400, 400)
    -- You should hear it pan and get quieter as you move away from 400, 400
    if input.pressed("f") then
        audio.play_at(snd_sfx, 1, 400, 400, 0.8)
    end

    -- 4. BGM Controls
    -- [P] Pause/Resume
    if input.pressed("p") then
        if bgm_paused then
            audio.resume_voice(bgm_handle)
        else
            audio.pause_voice(bgm_handle)
        end
        bgm_paused = not bgm_paused
    end

    -- [L] Toggle Looping
    if input.pressed("l") then
        bgm_looping = not bgm_looping
        audio.set_voice_looping(bgm_handle, bgm_looping)
    end

    -- [M] Mute/Unmute Master (Testing Track Fades)
    if input.pressed("m") then
        master_muted = not master_muted
        local target = master_muted and 0 or 1
        audio.fade_track(0, target, 0.5) -- Fade Master over 0.5s
    end

    -- 5. Pitch Warp (Hold R to warble music)
    if input.down("r") then
        local p = 1.0 + math.sin(timer * 10) * 0.2
        audio.set_voice_pitch(bgm_handle, p)
    else
        audio.set_voice_pitch(bgm_handle, 1.0)
    end

    if input.pressed("escape") then window.close() end
end

runtime.draw = function()
    gfx.clear(C.BG)
    
    -- 1. Draw Spatial Source (Centered at 400, 400)
    -- Instead of drawing at 390, we draw at 400 and set the origin to 10 (half of 20)
    gfx.set_draw_origin(10, 10)
    gfx.draw_rect(400, 400, 20, 20, C.RED)
    
    gfx.set_draw_origin(0, 0) -- Reset origin for text
    gfx.draw_debug_text(400, 430, "Spatial Source (Center: 400, 400)", C.RED)

    -- 2. Draw Player (Centered at px, py)
    if player_img then
        local iw, ih = gfx.get_image_size(player_img)
        
        -- Set origin to the center of the image pixels
        gfx.set_draw_origin(iw / 2, ih / 2)
        
        -- Apply scale (The API will scale the origin/pivot automatically)
        gfx.set_draw_scale(0.15) 
        
        -- Draw at the exact logical coordinate
        gfx.draw_image(player_img, px, py, C.WHITE)
    end

    -- 3. UI Bar & Info
    gfx.draw_rect(0, 640, 1280, 80, C.BAR_BG)
    
    local status = string.format(
        "BGM: %s | Loop: %s | Mute: %s", 
        bgm_paused and "PAUSED" or "PLAYING",
        bgm_looping and "ON" or "OFF",
        master_muted and "YES" or "NO"
    )

    gfx.draw_debug_text(20, 655, "[SPACE] Play 2D SFX (Pan follows X)", C.UI_TEXT)
    gfx.draw_debug_text(20, 675, "[F] Play Spatial SFX at Red Box", C.UI_TEXT)
    gfx.draw_debug_text(20, 695, "[P] Pause | [L] Loop | [M] Fade Master | [R] Pitch Warp", C.UI_TEXT)
    
    gfx.draw_debug_text(800, 675, status, C.YELLOW)
    
    local fps = last_dt > 0 and math.floor(1 / last_dt) or 0
    gfx.draw_debug_text(1180, 690, "FPS: " .. fps, C.FPS_GREEN)
end
