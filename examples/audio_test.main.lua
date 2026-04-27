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
    UI_TEXT     = rgba(140, 140, 150, 255),
    BAR_BG      = rgba(15, 15, 20, 230),
    GRID        = rgba(55, 55, 65, 255),
    GREEN       = rgba(80, 255, 140, 255),
}

local px, py = 640, 360
local pvx, pvy = 0, 0
local timer = 0

local drone = { x = 0, y = 0, vx = 0, vy = 0, handle = 0, active = false }
local ambient = { x = 900, y = 200, handle = 0, active = false }

local snd_sfx, snd_music = nil, nil
local bgm_handle = 0
local bgm_paused = false
local master_muted = false
local delay_active = false

local current_filter = "NONE"
local current_lpf, target_lpf = 20000, 20000
local current_hpf, target_hpf = 10, 10

local logs = {}

-- =============================================================================
-- Helpers
-- =============================================================================

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function log(msg)
    table.insert(logs, 1, msg)
    while #logs > 5 do
        table.remove(logs)
    end
    print(msg)
end

local function apply_filter_preset(bus_id, label, lpf, hpf)
    current_filter = label
    if label ~= "UNDERWATER" then
        target_lpf = lpf
        target_hpf = hpf
    else
        target_hpf = hpf
    end
    log("filter -> " .. label)
end

local Res_Dir

runtime.init = function()
    window.set_size(1280, 720)
    Res_Dir = filesystem.get_resource_directory()
    gfx.set_default_filter("linear")

    snd_sfx = audio.load_sound(Res_Dir .. "/test_sfx.wav", "static")
    snd_music = audio.load_sound(Res_Dir .. "/test_bgm.ogg", "stream")

    bgm_handle = audio.play(snd_music, 2, 0.1, 1.0)
    audio.set_voice_looping(bgm_handle, true)

    audio.set_bus_delay_feedback(3, 0.5)
    audio.set_bus_delay_feedback(4, 0.5)
    audio.set_bus_delay_feedback(5, 0.5)

    log("audio test ready")
end

runtime.update = function(dt)
    timer = timer + dt

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

    local speed = 400
    local old_x, old_y = px, py

    if input.down("w") or input.down("up")    then py = py - speed * dt end
    if input.down("s") or input.down("down")  then py = py + speed * dt end
    if input.down("a") or input.down("left")  then px = px - speed * dt end
    if input.down("d") or input.down("right") then px = px + speed * dt end

    pvx, pvy = (px - old_x) / dt, (py - old_y) / dt

    audio.set_listener_position(px, py)
    audio.set_listener_velocity(pvx, pvy)

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

    if ambient.active then
        if not audio.is_voice_playing(ambient.handle) then
            ambient.handle = audio.play_at(snd_sfx, 1, ambient.x, ambient.y, 0.5)
            audio.set_voice_looping(ambient.handle, true)
            log("ambient restarted")
        end
    else
        audio.stop_voice(ambient.handle)
    end

    if input.pressed("space") then
        local pan = (px / 1280) * 2 - 1
        audio.play(snd_sfx, 1, 0.5, 1.0, pan)
        log(string.format("2D sfx pan %.2f", pan))
    end

    if input.pressed("z") then
        audio.play_at(snd_sfx, 1, 400, 400, 0.8)
        log("spatial sfx at red box")
    end

    if input.pressed("x") then
        drone.active = not drone.active
        if drone.active then
            drone.handle = audio.play(snd_music, 1, 0.4)
            audio.set_voice_looping(drone.handle, true)
            audio.set_voice_falloff(drone.handle, 50, 500)
            log("drone on")
        else
            audio.stop_voice(drone.handle)
            log("drone off")
        end
    end

    if input.pressed("c") then
        ambient.active = not ambient.active
        log("ambient " .. (ambient.active and "on" or "off"))
    end

    if input.pressed("v") then
        audio.stop_bus(1)
        drone.active = false
        ambient.active = false
        local probe = audio.play(snd_sfx, 1, 0.7, 1.0, 0.0)
        log("stop_bus(1), probe " .. tostring(probe))
    end

    if input.pressed("4") then audio.play(snd_sfx, 3, 0.8); log("delay bus 3") end
    if input.pressed("5") then audio.play(snd_sfx, 4, 0.8); log("delay bus 4") end
    if input.pressed("6") then audio.play(snd_sfx, 5, 0.8); log("delay bus 5") end

    if input.pressed("1") then apply_filter_preset(2, "NONE", 20000, 10) end
    if input.pressed("2") then apply_filter_preset(2, "UNDERWATER", 600, 10) end
    if input.pressed("3") then apply_filter_preset(2, "RADIO", 20000, 2000) end

    if input.pressed("e") then
        delay_active = not delay_active
        local feedback = delay_active and 0.8 or 0.0
        audio.set_bus_delay_feedback(1, feedback)
        log("bus 1 delay " .. (delay_active and "on" or "off"))
    end

    if input.pressed("q") then
        if bgm_paused then
            audio.resume_voice(bgm_handle)
        else
            audio.pause_voice(bgm_handle)
        end
        bgm_paused = not bgm_paused
        log("bgm " .. (bgm_paused and "paused" or "playing"))
    end

    if input.pressed("f") then
        master_muted = not master_muted
        audio.fade_bus(0, master_muted and 0 or 1, 0.5)
        log("master " .. (master_muted and "muted" or "loud"))
    end

    if input.down("r") then
        local warble = 1.0 + math.sin(timer * 12) * 0.15
        audio.set_voice_pitch(bgm_handle, warble)
    else
        audio.set_voice_pitch(bgm_handle, 1.0)
    end

    if input.pressed("t") then
        local time, duration = audio.get_voice_info(bgm_handle)
        log(string.format("bgm %.2f / %.2f", time, duration))
    end

    if input.pressed("y") then
        for i = 1, 70 do
            audio.play(snd_sfx, 1, 0.01)
        end
        log("voice stealing burst")
    end

    if input.pressed("escape") then window.close() end
end

runtime.draw = function()
    gfx.clear(C.BG)

    gfx.draw_text("Newt Audio Test", 20, 18, C.WHITE)
    gfx.debug_text(230, 22, "Bus 1: SFX/spatial | Bus 2: BGM/filter | Buses 3-5: delay presets", C.UI_TEXT)

    gfx.debug_line(px - 22, py, px + 22, py, C.WHITE)
    gfx.debug_line(px, py - 22, px, py + 22, C.WHITE)
    gfx.draw_rect(px - 4, py - 4, 8, 8, C.WHITE)
    gfx.debug_text(px - 32, py + 28, "Listener", C.WHITE)

    gfx.begin_transform()
        gfx.set_translation(400, 400)
        gfx.set_origin(10, 10)
        gfx.draw_rect(0, 0, 20, 20, C.RED)
    gfx.end_transform()

    gfx.debug_text(340, 430, "Spatial Static SFX", C.RED)

    if drone.active then
        gfx.draw_rect(drone.x - 10, drone.y - 10, 20, 20, C.CYAN)
        gfx.debug_text(drone.x - 40, drone.y + 20, "Drone (ON)", C.CYAN)
    else
        gfx.draw_rect(drone.x - 10, drone.y - 10, 20, 20, C.UI_TEXT)
        gfx.debug_text(drone.x - 40, drone.y + 20, "Drone (OFF)", C.UI_TEXT)
    end

    if ambient.active then
        gfx.draw_rect(ambient.x - 10, ambient.y - 10, 20, 20, C.MAGENTA)
        gfx.debug_text(ambient.x - 52, ambient.y + 20, "Ambient (ON)", C.MAGENTA)
    else
        gfx.draw_rect(ambient.x - 10, ambient.y - 10, 20, 20, C.UI_TEXT)
        gfx.debug_text(ambient.x - 52, ambient.y + 20, "Ambient (OFF)", C.UI_TEXT)
    end

    gfx.draw_rect(0, 535, 1280, 185, C.BAR_BG)

    local col1 = 20
    local col2 = 450
    local col3 = 850
    local y = 552
    local row = 20

    gfx.draw_text("Triggers", col1, y, C.UI_TEXT)
    gfx.debug_text(col1, y + row,     "[SPACE] 2D SFX pan from listener X", C.WHITE)
    gfx.debug_text(col1, y + row * 2, "[Z] Spatial SFX at red box", C.RED)
    gfx.debug_text(col1, y + row * 3, "[X] Toggle moving drone", C.CYAN)
    gfx.debug_text(col1, y + row * 4, "[C] Toggle ambient guard", C.MAGENTA)
    gfx.debug_text(col1, y + row * 5, "[Y] Voice stealing burst", C.WHITE)

    gfx.draw_text("Bus / FX", col2, y, C.UI_TEXT)
    gfx.debug_text(col2, y + row,     "[1/2/3] BGM filter: " .. current_filter, C.YELLOW)
    gfx.debug_text(col2, y + row * 2, string.format("[E] Bus 1 delay: %s", delay_active and "ON" or "OFF"), C.YELLOW)
    gfx.debug_text(col2, y + row * 3, "[4] Slapback  [5] Echo  [6] Canyon", C.WHITE)
    gfx.debug_text(col2, y + row * 4, "[V] stop_bus(1) + immediate probe", C.WHITE)

    if current_filter == "UNDERWATER" then
        gfx.debug_text(col2, y + row * 5, string.format("LPF SWEEP: %.0f Hz", current_lpf), C.CYAN)
    else
        gfx.debug_text(col2, y + row * 5, string.format("LPF: %.0f Hz", current_lpf), C.UI_TEXT)
    end

    gfx.draw_text("Globals / Log", col3, y, C.UI_TEXT)
    gfx.debug_text(col3, y + row,     string.format("[Q] BGM: %s", bgm_paused and "PAUSED" or "PLAYING"), C.WHITE)
    gfx.debug_text(col3, y + row * 2, string.format("[F] Master: %s", master_muted and "MUTED" or "LOUD"), C.WHITE)
    gfx.debug_text(col3, y + row * 3, "[R] Hold pitch warble  [T] Log timestamp", C.WHITE)

    for i = 1, math.min(4, #logs) do
        gfx.debug_text(col3, y + row * (3 + i), logs[i], C.UI_TEXT)
    end
end
