local ffi = require("ffi")
local gfx = graphics
local bit = require("bit")

local function rgba(r, g, b, a)
  return bit.bor(bit.lshift(r, 24), bit.lshift(g, 16), bit.lshift(b, 8), a)
end

-- 16:9 Low-Res Playfield
local W, H = 320, 180
local SCALE = 4

-- Engine State
local pmap_terrain, img_terrain
local pmap_vfx, img_vfx
local player_x, player_y = W / 2, H / 2
local player_speed = 60
local player_radius = 3

-- Colors
local C = {
  BG     = rgba(15, 15, 20, 255),
  DIRT   = rgba(100, 70, 50, 255),
  ROCK   = rgba(60, 60, 70, 255),
  LASER  = rgba(255, 50, 50, 255),
  HEAVY  = rgba(50, 200, 255, 255),
  CLEAR  = rgba(0, 0, 0, 0),
  BRUSH  = rgba(255, 255, 255, 255)
}

-- Collision Helper
local function is_solid(x, y)
  if x < 0 or x >= W or y < 0 or y >= H then return true end
  local color = gfx.pixelmap_get_pixel(pmap_terrain, math.floor(x), math.floor(y))
  local alpha = bit.band(color, 0xFF)
  return alpha > 0
end

local function can_move(x, y)
  local r = player_radius
  return not is_solid(x - r, y) and not is_solid(x + r, y) and
         not is_solid(x, y - r) and not is_solid(x, y + r)
end

runtime.init = function()
  window.init(W * SCALE, H * SCALE, "Toy: Mining Laser + Movement + FFI")
  gfx.set_default_filter("nearest")

  pmap_terrain = gfx.new_pixelmap(W, H)
  gfx.blit_rect(pmap_terrain, 0, 0, W, H, C.DIRT, "replace")
  
  math.randomseed(os.time())
  for i = 1, 40 do
    local rx, ry = math.random(10, W - 10), math.random(10, H - 10)
    gfx.blit_circle(pmap_terrain, rx, ry, math.random(5, 12), C.ROCK, "replace")
  end

  gfx.blit_circle(pmap_terrain, player_x, player_y, 25, C.BRUSH, "erase")
  img_terrain = gfx.new_image_from_pixelmap(pmap_terrain)

  pmap_vfx = gfx.new_pixelmap(W, H)
  img_vfx = gfx.new_image_from_pixelmap(pmap_vfx)
end

runtime.update = function(dt)
  if input.down("escape") then window.close() end

-- FFI RAW MEMORY TEST (Press Space to invert colors)
  if input.pressed("space") then
    local raw_ptr = gfx.get_pixelmap_cptr(pmap_terrain)
    if raw_ptr then
      -- Cast the untyped pointer to a C array of 32-bit integers
      local pixels = ffi.cast("uint32_t*", raw_ptr)
      local total_pixels = W * H
      
      for i = 0, total_pixels - 1 do
        local color = pixels[i]
        
        -- FIX: Check for non-zero instead of > 0 to bypass signedness
        if bit.band(color, 0xFF000000) ~= 0 then
          
          -- XOR the bottom 24 bits (RGB) to invert, leave top 8 (Alpha) alone
          pixels[i] = bit.bxor(color, 0x00FFFFFF)
        end
      end
      gfx.update_image_from_pixelmap(img_terrain, pmap_terrain)
    end
  end

  -- PLAYER MOVEMENT
  local dx, dy = 0, 0
  if input.down("w") or input.down("up")    then dy = -1 end
  if input.down("s") or input.down("down")  then dy = 1 end
  if input.down("a") or input.down("left")  then dx = -1 end
  if input.down("d") or input.down("right") then dx = 1 end

  if dx ~= 0 or dy ~= 0 then
    if dx ~= 0 and dy ~= 0 then dx, dy = dx * 0.7071, dy * 0.7071 end
    local nx, ny = player_x + (dx * player_speed * dt), player_y + (dy * player_speed * dt)
    if can_move(nx, player_y) then player_x = nx end
    if can_move(player_x, ny) then player_y = ny end
  end

  gfx.blit_rect(pmap_vfx, 0, 0, W, H, C.CLEAR, "replace")

  local mx, my = input.get_mouse_position()
  local target_x, target_y = math.floor(mx / SCALE), math.floor(my / SCALE)

  local lx, ly = target_x - player_x, target_y - player_y
  local len = math.sqrt(lx*lx + ly*ly)
  if len == 0 then len = 1 end
  local far_x, far_y = math.floor(player_x + (lx / len) * (W * 2)), math.floor(player_y + (ly / len) * (W * 2))

  local hit, hx, hy = gfx.pixelmap_raycast(pmap_terrain, math.floor(player_x), math.floor(player_y), far_x, far_y)

-- RIGHT CLICK: Heavy Capsule Laser
  if input.down("mouse2") then
    local end_x, end_y = far_x, far_y
    if hit then 
      end_x, end_y = hx, hy 
      
      -- Dynamic high-energy impact rings
      gfx.blit_circle_outline(pmap_vfx, end_x, end_y, math.random(10, 14), rgba(200, 255, 255, 255), "add")
      gfx.blit_circle_outline(pmap_vfx, end_x, end_y, math.random(16, 22), rgba(50, 200, 255, 150), "add")
    end

    -- Draw thick beam
    gfx.blit_capsule(pmap_vfx, player_x, player_y, end_x, end_y, 8, C.HEAVY, "replace")
    
    -- Erase terrain along the entire beam path using capsule
    gfx.blit_capsule(pmap_terrain, player_x, player_y, end_x, end_y, 8, C.BRUSH, "erase")
    gfx.update_image_from_pixelmap(img_terrain, pmap_terrain)
  
  -- LEFT CLICK / NORMAL RAYCAST
  elseif hit then
    gfx.blit_line(pmap_vfx, math.floor(player_x), math.floor(player_y), hx, hy, C.LASER, "replace")
    
    -- Core impact dot
    gfx.blit_circle(pmap_vfx, hx, hy, math.random(1, 3), rgba(255, 200, 0, 255), "add")
    -- Dynamic sparking outline
    gfx.blit_circle_outline(pmap_vfx, hx, hy, math.random(4, 8), rgba(255, 50, 50, 200), "add")

    if input.down("mouse1") then 
      gfx.blit_circle(pmap_terrain, hx, hy, 4, C.BRUSH, "erase")
      gfx.update_image_from_pixelmap(img_terrain, pmap_terrain)
    end
  else
    gfx.blit_line(pmap_vfx, math.floor(player_x), math.floor(player_y), far_x, far_y, rgba(255, 50, 50, 100), "blend")
  end

  -- Player Core
  gfx.blit_circle(pmap_vfx, math.floor(player_x), math.floor(player_y), player_radius, rgba(0, 255, 255, 255), "replace")
  -- Player Energy Shield
  gfx.blit_circle_outline(pmap_vfx, math.floor(player_x), math.floor(player_y), player_radius + math.random(2, 3), rgba(0, 150, 255, 150), "add")
  
  gfx.update_image_from_pixelmap(img_vfx, pmap_vfx)
end

runtime.draw = function()
  gfx.clear(C.BG)
  gfx.begin_transform_group()
  gfx.set_draw_origin(0, 0)
  gfx.set_draw_scale(SCALE, SCALE)
  gfx.draw_image(img_terrain, 0, 0)
  gfx.draw_image(img_vfx, 0, 0)
  gfx.end_transform_group()
  gfx.draw_debug_text(10, 10, "LMB: Mine | RMB: Heavy Laser | SPACE: FFI Invert", C.WHITE)
end
