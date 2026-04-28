-- Simple roguelike cave example --
-- Shows datagrid composition, region queries, FOV, explored memory, and movement.

-- Configuration --

local MAP_W = 80
local MAP_H = 43
local GLYPH_SIZE = 8
local SCALE = 2

local VIEW_W = MAP_W * GLYPH_SIZE
local VIEW_H = (MAP_H + 1) * GLYPH_SIZE
local SCREEN_W = VIEW_W * SCALE
local SCREEN_H = VIEW_H * SCALE

local FOV_RADIUS = 10

local NOISE_FREQUENCY = 0.075
local NOISE_OCTAVES = 4
local WALL_THRESHOLD = 4

local COLORS = {
  wall_visible = rgba("#9AC46E"),
  floor_visible = rgba("#4E8A3A"),
  player = rgba("#FFFFFF"),
  wall_memory = rgba("#1D3019"),
  floor_memory = rgba("#10200D"),
  hud = rgba("#72D05A"),
}

-- State --

local Map_Grid = nil
local Visibility_Grid = nil
local Memory_Grid = nil
local Canvas = nil
local Map_Seed = 420

local Player = {
  x = math.floor(MAP_W / 2),
  y = math.floor(MAP_H / 2),
}

-- Map Generation --

local function generate_map()
  local noise_grid = random.new_noise_datagrid(MAP_W, MAP_H, Map_Seed, {
    frequency = NOISE_FREQUENCY,
    octaves = NOISE_OCTAVES,
    min = 0,
    max = 9,
  })

  -- Map cells: 0 = wall/blocked/opaque, 1 = floor/passable/transparent.
  local cave_grid = grid.threshold(noise_grid, WALL_THRESHOLD, 0, 1)
  -- Stamp only the cave interior, leaving the outer border solid.
  local interior_grid = grid.crop(cave_grid, 1, 1, MAP_W - 2, MAP_H - 2)
  
  Map_Grid = grid.new_datagrid(MAP_W, MAP_H)
  Map_Grid = grid.add(Map_Grid, interior_grid, 1, 1)
end

local function place_player_in_largest_region()
  local region_map, region_count = grid.compute_regions(Map_Grid)

  if region_count == 0 then
    return false
  end

  local largest_region = 1
  local largest_size = grid.count_cells(region_map, largest_region)

  for region_id = 2, region_count do
    local size = grid.count_cells(region_map, region_id)

    if size > largest_size then
      largest_region = region_id
      largest_size = size
    end
  end

  local rx, ry, rw, rh = grid.get_region_bounds(region_map, largest_region)
  local center_x = rx + math.floor(rw / 2)
  local center_y = ry + math.floor(rh / 2)
  local px, py = grid.find_nearest_cell(region_map, center_x, center_y, largest_region)

  Player.x = px
  Player.y = py
  return true
end

-- Visibility --

local function update_fov()
  -- Visibility cells: 0 = hidden, 1 = visible.
  Visibility_Grid = grid.compute_fov(Map_Grid, Player.x, Player.y, FOV_RADIUS)
  -- Memory is 0/1 too, so max accumulates explored cells.
  Memory_Grid = grid.max(Memory_Grid, Visibility_Grid)
end

-- Movement --

local function move_key_pressed(name)
  return input.pressed(name) or input.repeated(name)
end

local function try_move(dx, dy)
  local nx = Player.x + dx
  local ny = Player.y + dy

  if grid.get_cell(Map_Grid, nx, ny) == 1 then
    Player.x = nx
    Player.y = ny
    update_fov()
  end
end

local function regenerate_map()
  Map_Seed = Map_Seed + 1
  Memory_Grid = grid.new_datagrid(MAP_W, MAP_H)

  while true do
    generate_map()

    if place_player_in_largest_region() then
      break
    end

    Map_Seed = Map_Seed + 1
  end

  update_fov()
end

-- Runtime Callbacks --

runtime.init = function()
  window.set_title("Newt Roguelike Cave Example")
  window.set_size(SCREEN_W, SCREEN_H)
  graphics.set_default_filter("nearest")
  Canvas = graphics.new_canvas(VIEW_W, VIEW_H)
  regenerate_map()
end

runtime.update = function()
  if input.pressed("escape") then window.close() end
  if input.pressed("r") then regenerate_map() end

  if move_key_pressed("q") or move_key_pressed("kp7") then try_move(-1, -1)
  elseif move_key_pressed("w") or move_key_pressed("kp8") then try_move(0, -1)
  elseif move_key_pressed("e") or move_key_pressed("kp9") then try_move(1, -1)
  elseif move_key_pressed("a") or move_key_pressed("kp4") then try_move(-1, 0)
  elseif move_key_pressed("d") or move_key_pressed("kp6") then try_move(1, 0)
  elseif move_key_pressed("z") or move_key_pressed("kp1") then try_move(-1, 1)
  elseif move_key_pressed("s") or move_key_pressed("kp2") then try_move(0, 1)
  elseif move_key_pressed("c") or move_key_pressed("kp3") then try_move(1, 1)
  end
end

runtime.draw = function()
  graphics.set_canvas(Canvas)
  graphics.clear()

  for y = 0, MAP_H - 1 do
    for x = 0, MAP_W - 1 do
      if grid.get_cell(Memory_Grid, x, y) == 1 then
        local is_wall = grid.get_cell(Map_Grid, x, y) == 0
        local is_visible = grid.get_cell(Visibility_Grid, x, y) == 1
        local glyph = is_wall and "#" or "."
        local color = nil

        if is_visible then color = is_wall and COLORS.wall_visible or COLORS.floor_visible
        else color = is_wall and COLORS.wall_memory or COLORS.floor_memory
        end

        graphics.debug_text(x * GLYPH_SIZE, y * GLYPH_SIZE, glyph, color)
      end
    end
  end

  graphics.debug_text(Player.x * GLYPH_SIZE, Player.y * GLYPH_SIZE, "@", COLORS.player)

  local hud_y = MAP_H * GLYPH_SIZE
  graphics.debug_text(0, hud_y, "WASD+QEZC OR KEYPAD TO MOVE   R REGENERATE   ESC QUIT", COLORS.hud)

  graphics.set_canvas(nil)

  graphics.begin_transform()
  graphics.set_scale(SCALE)
  graphics.draw_image(Canvas, 0, 0)
  graphics.end_transform()
end