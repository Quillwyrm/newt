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
local player_speed = 60 -- pixels per second
local player_radius = 3

-- Colors
local C = {
  BG     = rgba(15, 15, 20, 255),
  DIRT   = rgba(100, 70, 50, 255),
  ROCK   = rgba(60, 60, 70, 255),
  LASER  = rgba(255, 50, 50, 255),
  CLEAR  = rgba(0, 0, 0, 0),
  BRUSH  = rgba(255, 255, 255, 255)
}

-- Collision Helper
local function is_solid(x, y)
  -- Screen bounds act as hard walls
  if x < 0 or x >= W or y < 0 or y >= H then return true end
  
  -- Query the physical memory of the terrain pixelmap
  local color = gfx.pixelmap_get_pixel(pmap_terrain, math.floor(x), math.floor(y))
  
  -- Your rgba() packs alpha into the lowest 8 bits. We isolate it.
  local alpha = bit.band(color, 0xFF)
  return alpha > 0
end

local function can_move(x, y)
  -- Check the 4 cardinal points around the player's radius
  local r = player_radius
  return not is_solid(x - r, y) and not is_solid(x + r, y) and
         not is_solid(x, y - r) and not is_solid(x, y + r)
end

runtime.init = function()
  window.init(W * SCALE, H * SCALE, "Toy: Mining Laser + Movement")
  gfx.set_default_filter("nearest")

  -- 1. Setup Terrain
  pmap_terrain = gfx.new_pixelmap(W, H)
  
  -- Fill with dirt
  gfx.blit_rect(pmap_terrain, 0, 0, W, H, C.DIRT, "replace")
  
  -- Add some hard rock deposits
  math.randomseed(os.time())
  for i = 1, 40 do
    local rx, ry = math.random(10, W - 10), math.random(10, H - 10)
    gfx.blit_circle(pmap_terrain, rx, ry, math.random(5, 12), C.ROCK, "replace")
  end

  -- Hollow out a starting cavern for the player
  gfx.blit_circle(pmap_terrain, player_x, player_y, 25, C.BRUSH, "erase")
  
  img_terrain = gfx.new_image_from_pixelmap(pmap_terrain)

  -- 2. Setup Volatile VFX Layer
  pmap_vfx = gfx.new_pixelmap(W, H)
  img_vfx = gfx.new_image_from_pixelmap(pmap_vfx)
end

runtime.update = function(dt)
  if input.down("escape") then window.close() end

  -- PLAYER MOVEMENT
  local dx, dy = 0, 0
  if input.down("w") or input.down("up")    then dy = -1 end
  if input.down("s") or input.down("down")  then dy = 1 end
  if input.down("a") or input.down("left")  then dx = -1 end
  if input.down("d") or input.down("right") then dx = 1 end

  if dx ~= 0 or dy ~= 0 then
    -- Normalize diagonal movement
    if dx ~= 0 and dy ~= 0 then
      dx = dx * 0.7071
      dy = dy * 0.7071
    end

    local nx = player_x + (dx * player_speed * dt)
    local ny = player_y + (dy * player_speed * dt)

    -- Separate axis collision tests (allows sliding against walls)
    if can_move(nx, player_y) then player_x = nx end
    if can_move(player_x, ny) then player_y = ny end
  end

  -- Clear the VFX layer entirely
  gfx.blit_rect(pmap_vfx, 0, 0, W, H, C.CLEAR, "replace")

  -- Get mouse target in pixelmap space
  local mx, my = input.get_mouse_position()
  local target_x = math.floor(mx / SCALE)
  local target_y = math.floor(my / SCALE)

  -- Project a point far off-screen in the direction of the mouse 
  local lx, ly = target_x - player_x, target_y - player_y
  local len = math.sqrt(lx*lx + ly*ly)
  if len == 0 then len = 1 end
  local far_x = math.floor(player_x + (lx / len) * (W * 2))
  local far_y = math.floor(player_y + (ly / len) * (W * 2))

  -- THE QUERY: Fire the raycast into the terrain
  local hit, hx, hy, hit_color = gfx.pixelmap_raycast(pmap_terrain, math.floor(player_x), math.floor(player_y), far_x, far_y)

  if hit then
    -- Draw laser stopping exactly at the wall
    gfx.blit_line(pmap_vfx, math.floor(player_x), math.floor(player_y), hx, hy, C.LASER, "replace")
    
    -- Draw an impact spark
    gfx.blit_circle(pmap_vfx, hx, hy, math.random(1, 3), rgba(255, 200, 0, 255), "add")

    -- MINING LOGIC
    if input.down("mouse1") then
      -- Dig into the terrain at the exact impact point
      local drill_size = 4
      gfx.blit_circle(pmap_terrain, hx, hy, drill_size, C.BRUSH, "erase")
      
      -- We mutated the terrain, so we must sync it across the bus
      gfx.update_image_from_pixelmap(img_terrain, pmap_terrain)
    end
  else
    -- Missed everything, draw laser flying off screen
    gfx.blit_line(pmap_vfx, math.floor(player_x), math.floor(player_y), far_x, far_y, rgba(255, 50, 50, 100), "blend")
  end

  -- Draw the player
  gfx.blit_circle(pmap_vfx, math.floor(player_x), math.floor(player_y), player_radius, rgba(0, 255, 255, 255), "replace")

  -- Always sync VFX because it changes every frame
  gfx.update_image_from_pixelmap(img_vfx, pmap_vfx)
end

runtime.draw = function()
  gfx.clear(C.BG)
  
  gfx.begin_transform_group()
  gfx.set_draw_origin(0, 0)
  gfx.set_draw_scale(SCALE, SCALE)
  
  -- Draw persistent terrain
  gfx.draw_image(img_terrain, 0, 0)
  
  -- Draw volatile VFX directly over it
  gfx.draw_image(img_vfx, 0, 0)
  
  gfx.end_transform_group()

  gfx.draw_debug_text(10, 10, "WASD: Move  |  LMB: Mine Terrain", C.WHITE)
end
