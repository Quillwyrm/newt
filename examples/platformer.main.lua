-- Newt tile platformer example --

-- Configuration --

local SCREEN_WIDTH = 1280
local SCREEN_HEIGHT = 720
local TILE_SIZE = 40

local PLAYER_START_X = 100
local PLAYER_START_Y = 500
local PLAYER_WIDTH = 32
local PLAYER_HEIGHT = 32

local GRAVITY = 2200
local ACCELERATION = 3200
local FRICTION = 2800
local MAX_SPEED = 420
local JUMP_FORCE = -800
local JUMP_GRACE = 0.1

local COLORS = {
  background = rgba("#141A16"),
  tile = rgba("#3F4A3C"),
  player = rgba("#8FD7FF"),
  text = rgba("#EAF2E3"),
}

-- Level data --

local LEVEL_ROWS = {
  "11111111111111111111111111111111",
  "11111000000000000000000000000111",
  "11000000000000000000000000000011",
  "11111101000111110000000000000001",
  "10000000000000000000111100000001",
  "10000000000000000000000110000001",
  "10000000000000000000000000111001",
  "10011100000000000000001000000001",
  "10000000001111111100000000000011",
  "10000000000000000000000000000001",
  "10000000000001000000000011110001",
  "10000111100000000000000000000001",
  "10000000000000000000000000000001",
  "10000000000000000000000100000001",
  "11000000000000001000001100000001",
  "11100000000010011100001100000001",
  "11111111111111111111111111111111",
  "11111111111111111111111111111111",
}

local solid_tiles = {}

-- State --

local player = {
  x = PLAYER_START_X,
  y = PLAYER_START_Y,
  w = PLAYER_WIDTH,
  h = PLAYER_HEIGHT,
  vx = 0,
  vy = 0,
  grounded = false,
  jump_grace = 0,
}

-- Helpers --

local function rects_overlap(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and
    ax + aw > bx and
    ay < by + bh and
    ay + ah > by
end

local function reset_player()
  player.x = PLAYER_START_X
  player.y = PLAYER_START_Y
  player.vx = 0
  player.vy = 0
  player.grounded = false
  player.jump_grace = 0
end

local function build_solid_tiles()
  solid_tiles = {}

  for row = 1, #LEVEL_ROWS do
    local row_text = LEVEL_ROWS[row]

    for col = 1, #row_text do
      if row_text:sub(col, col) == "1" then
        solid_tiles[#solid_tiles + 1] = {
          x = (col - 1) * TILE_SIZE,
          y = (row - 1) * TILE_SIZE,
        }
      end
    end
  end
end

-- Runtime callbacks --

runtime.init = function()
  window.set_title("Newt Platformer Example")
  window.set_size(SCREEN_WIDTH, SCREEN_HEIGHT)

  build_solid_tiles()
  reset_player()
end

runtime.update = function(dt)

  -- Player Input --
  local move = 0
  if input.down("a") or input.down("left") then move = move - 1 end
  if input.down("d") or input.down("right") then move = move + 1 end

  local jump_pressed = input.pressed("space") or
    input.pressed("w") or
    input.pressed("up")

  if input.pressed("r") then
    reset_player()
  end

  -- Horizontal movement --
  if move ~= 0 then
    player.vx = player.vx + move * ACCELERATION * dt
  elseif player.vx > 0 then
    player.vx = math.max(player.vx - FRICTION * dt, 0)
  elseif player.vx < 0 then
    player.vx = math.min(player.vx + FRICTION * dt, 0)
  end

  player.vx = math.max(-MAX_SPEED, math.min(MAX_SPEED, player.vx))

  -- Jump grace --
  if player.grounded then
    player.jump_grace = JUMP_GRACE
  else
    player.jump_grace = math.max(player.jump_grace - dt, 0)
  end

  if jump_pressed and player.jump_grace > 0 then
    player.vy = JUMP_FORCE
    player.grounded = false
    player.jump_grace = 0
  end

  -- Horizontal collision --
  player.x = player.x + player.vx * dt

  for i = 1, #solid_tiles do
    local tile = solid_tiles[i]

    if rects_overlap(player.x, player.y, player.w, player.h, tile.x, tile.y, TILE_SIZE, TILE_SIZE) then
      if player.vx > 0 then
        player.x = tile.x - player.w
      elseif player.vx < 0 then
        player.x = tile.x + TILE_SIZE
      end

      player.vx = 0
    end
  end

  -- Vertical collision --
  player.vy = player.vy + GRAVITY * dt
  player.y = player.y + player.vy * dt
  player.grounded = false

  for i = 1, #solid_tiles do
    local tile = solid_tiles[i]

    if rects_overlap(player.x, player.y, player.w, player.h, tile.x, tile.y, TILE_SIZE, TILE_SIZE) then
      if player.vy > 0 then
        player.y = tile.y - player.h
        player.grounded = true
      elseif player.vy < 0 then
        player.y = tile.y + TILE_SIZE
      end

      player.vy = 0
    end
  end

  if player.y > SCREEN_HEIGHT + 200 then
    reset_player()
  end
end

runtime.draw = function()
  graphics.clear(COLORS.background)

  -- Draw level
  for i = 1, #solid_tiles do
    local tile = solid_tiles[i]
    graphics.draw_rect(tile.x, tile.y, TILE_SIZE, TILE_SIZE, COLORS.tile)
  end

  -- Draw Player
  graphics.draw_rect(player.x, player.y, player.w, player.h, COLORS.player)

  -- Draw UI
  graphics.draw_text("A/D or LEFT/RIGHT: move", 20, SCREEN_HEIGHT - 72, COLORS.text)
  graphics.draw_text("SPACE / W / UP: jump", 20, SCREEN_HEIGHT - 52, COLORS.text)
  graphics.draw_text("R: reset", 20, SCREEN_HEIGHT - 32, COLORS.text)
end