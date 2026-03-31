local gfx = graphics
local W, H, SCALE = 320, 180, 4

-- Colors using your new u32rgba format
local C = {
  BG   = 0x0F0F14FF, 
  TEXT = 0xFFFFFFFF,
  ACCENT = 0x32C8FFFF
}

local frames = 0

runtime.init = function()
  window.init(W * SCALE, H * SCALE, "Test: Bare Metal Graphics")
end

runtime.update = function(dt)
  if input.down("escape") then window.close() end
  
  frames = frames + 1
end

runtime.draw = function()
  -- 1. Test Clear
  gfx.clear(C.BG)
  
  -- 2. Test Debug Text (Static)
  gfx.draw_debug_text(10, 10, "Luagame Graphics: Ground Zero", C.TEXT)
  
  -- 3. Test Debug Text (Dynamic/Updating)
  local info = string.format("Frames: %d | Resolution: %dx%d", frames, W * SCALE, H * SCALE)
  gfx.draw_debug_text(10, 30, info, C.TEXT)
  
  -- 4. Test Debug Text (Color Swap)
  local mx, my = input.get_mouse_position()
  local mouse_info = string.format("Mouse: X:%d Y:%d", mx, my)
  gfx.draw_debug_text(10, 50, mouse_info, C.ACCENT)
end