local gfx = graphics
local W, H, SCALE = 320, 180, 4
local pmap, img

-- State
local radius = 8
local thickness = 2.0
local C = {
  BG      = 0x0F0F14FF,
  SHAPE   = 0x32C8FFFF,
  CLEAR   = 0x00000000,
  TEXT    = 0xFFFFFFFF
}

runtime.init = function()
  window.init(W * SCALE, H * SCALE, "Test: Final Shape API")
  gfx.set_default_filter("nearest")

  pmap = gfx.new_pixelmap(W, H)
  img = gfx.new_image_from_pixelmap(pmap)
end

runtime.update = function(dt)
  if input.down("escape") then window.close() end

  -- Adjust Radius
  local scroll = input.get_mouse_wheel()
  if scroll ~= 0 then
    radius = math.max(1, math.min(40, radius + scroll))
  end
  
  if input.pressed("]") then radius = math.max(1, math.min(40, radius + 1)) end
  if input.pressed("[") then radius = math.max(1, math.min(40, radius - 1)) end

  -- Adjust Thickness
  if input.pressed("=") then thickness = math.min(radius, thickness + 0.5) end
  if input.pressed("-") then thickness = math.max(0.5, thickness - 0.5) end

  gfx.blit_rect(pmap, 0, 0, W, H, C.CLEAR, "replace")

  local cy = H / 2
  local step = W / 4
  
  local x1 = step * 0.5
  local x2 = step * 1.5
  local x3 = step * 2.5
  local x4 = step * 3.5

  -- 1. Capsule
  gfx.blit_capsule(pmap, math.floor(x1), math.floor(cy), math.floor(x1), math.floor(cy), math.floor(radius), C.SHAPE, "replace")
  
  -- 2. Circle (Solid)
  gfx.blit_circle(pmap, math.floor(x2), math.floor(cy), math.floor(radius), C.SHAPE, "replace")
  
  -- 3. Circle Outline (Donut, takes thickness)
  gfx.blit_circle_outline(pmap, math.floor(x3), math.floor(cy), math.floor(radius), thickness, C.SHAPE, "replace")
  
  -- 4. Pixel Outline (Bresenham 1px)
  gfx.blit_circle_pixel_outline(pmap, math.floor(x4), math.floor(cy), math.floor(radius), C.SHAPE, "replace")

  gfx.update_image_from_pixelmap(img, pmap)
end

runtime.draw = function()
  gfx.clear(C.BG)
  
  gfx.begin_transform_group()
    gfx.set_draw_scale(SCALE, SCALE)
    gfx.draw_image(img, 0, 0)
  gfx.end_transform_group()
  
  local info = string.format("Rad: %d | Thick: %.1f | [ ] Rad | - = Thick", radius, thickness)
  gfx.draw_debug_text(10, 10, info, C.TEXT)
  
  local label_y = (H / 2 + 45) * SCALE
  local step_px = (W / 4) * SCALE
  
  gfx.draw_debug_text(step_px * 0.5 - 30, label_y, "Capsule", C.TEXT)
  gfx.draw_debug_text(step_px * 1.5 - 25, label_y, "Circle", C.TEXT)
  gfx.draw_debug_text(step_px * 2.5 - 25, label_y, "Donut", C.TEXT)
  gfx.draw_debug_text(step_px * 3.5 - 40, label_y, "PxOutline", C.TEXT)
end
