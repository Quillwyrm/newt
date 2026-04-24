-- Newt gamepad module test harness
-- Tests:
--   get_count / is_connected / get_name / get_type
--   down / pressed / released for every curated button token
--   stick / trigger analog polling
--   trigger_down / trigger_pressed / trigger_released
--
-- Layout uses graphics font queries instead of guessed row heights.
-- Edge columns are display-latched for readability. The gamepad edge calls
-- are still queried directly every frame.

local MAX_PADS = 8
local SELECTED_PAD = 1
local TRIGGER_THRESHOLD = 0.50
local EDGE_FLASH_TIME = 0.25

local MIN_WIN_W = 1320
local MIN_WIN_H = 620
local AUTO_GROW_WINDOW = true

local BUTTONS = {
  "south", "east", "west", "north",
  "up", "down", "left", "right",
  "back", "guide", "start",
  "left_stick", "right_stick",
  "left_shoulder", "right_shoulder",
}

local SIDES = {"left", "right"}

local C = {
  bg       = rgba(20, 20, 24),
  panel    = rgba(30, 33, 40),
  panel2   = rgba(24, 27, 34),
  text     = rgba("#FFFFFF"),
  dim      = rgba("#8B96A8"),
  blue     = rgba("#B8E0FF"),
  green    = rgba("#80FFB0"),
  red      = rgba("#FF8080"),
  yellow   = rgba("#FFE680"),
  line     = rgba("#3A4150"),
  off      = rgba("#343946"),
}

local Snapshot = nil
local Edge_Pulse = {}
local Font = nil
local Layout = nil

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function fmt2(v)
  return string.format("%.2f", v)
end

local function measure_text_width(text)
  local w = graphics.measure_text(tostring(text))
  if w == nil then
    return string.len(tostring(text)) * 10
  end
  return w
end

local function max_text_width(list)
  local w = 0
  for _, text in ipairs(list) do
    w = math.max(w, measure_text_width(text))
  end
  return w
end

local function refresh_font_metrics()
  local h = graphics.get_font_height()
  local line = graphics.get_font_line_skip()

  h = h or 18
  line = line or h

  Font = {
    height = h,
    line = line,
    pad = math.max(4, math.floor(h * 0.25)),
    margin = math.max(12, math.floor(h * 0.90)),
    gap = math.max(18, math.floor(h * 1.20)),
    box = clamp(h - 2, 12, 22),
  }

  Font.row = Font.line + Font.pad
end

local function pulse(key, fired, dt)
  if fired then
    Edge_Pulse[key] = EDGE_FLASH_TIME
  else
    Edge_Pulse[key] = math.max((Edge_Pulse[key] or 0) - dt, 0)
  end

  return Edge_Pulse[key] > 0
end

local function update_keyboard_controls()
  if input.pressed("escape") then
    window.close()
  end

  for i = 1, MAX_PADS do
    if input.pressed(tostring(i)) then
      SELECTED_PAD = i
    end
  end

  if input.pressed("[") then
    TRIGGER_THRESHOLD = clamp(TRIGGER_THRESHOLD - 0.05, 0.05, 1.00)
  end
  if input.pressed("]") then
    TRIGGER_THRESHOLD = clamp(TRIGGER_THRESHOLD + 0.05, 0.05, 1.00)
  end
end

local function build_snapshot(dt)
  local snap = {
    count = gamepad.get_count(),
    default_connected = gamepad.is_connected(),
    default_name = gamepad.get_name(),
    default_type = gamepad.get_type(),
    pads = {},
    buttons = {},
    sticks = {},
    triggers = {},
  }

  for pad = 1, MAX_PADS do
    snap.pads[pad] = {
      connected = gamepad.is_connected(pad),
      name = gamepad.get_name(pad),
      type = gamepad.get_type(pad),
    }
  end

  for i, button in ipairs(BUTTONS) do
    local down = gamepad.down(button, SELECTED_PAD)
    local pressed = gamepad.pressed(button, SELECTED_PAD)
    local released = gamepad.released(button, SELECTED_PAD)

    local pressed_hit = pulse("button:" .. button .. ":pressed", pressed, dt)
    local released_hit = pulse("button:" .. button .. ":released", released, dt)

    snap.buttons[i] = {
      token = button,
      down = down,
      pressed_hit = pressed_hit,
      released_hit = released_hit,
    }
  end

  for _, side in ipairs(SIDES) do
    local x, y = gamepad.stick(side, SELECTED_PAD)
    snap.sticks[side] = {x = x, y = y}

    local value = gamepad.trigger(side, SELECTED_PAD)
    local down = gamepad.trigger_down(side, TRIGGER_THRESHOLD, SELECTED_PAD)
    local pressed = gamepad.trigger_pressed(side, TRIGGER_THRESHOLD, SELECTED_PAD)
    local released = gamepad.trigger_released(side, TRIGGER_THRESHOLD, SELECTED_PAD)

    local pressed_hit = pulse("trigger:" .. side .. ":pressed", pressed, dt)
    local released_hit = pulse("trigger:" .. side .. ":released", released, dt)

    snap.triggers[side] = {
      value = value,
      down = down,
      pressed_hit = pressed_hit,
      released_hit = released_hit,
    }
  end

  Snapshot = snap
end

local function build_layout()
  refresh_font_metrics()

  local m = Font.margin
  local gap = Font.gap
  local row = Font.row

  local bool_w = Font.box + Font.pad + math.max(measure_text_width("false"), measure_text_width("true"))
  local state_col_w = math.max(
    bool_w,
    measure_text_width("down"),
    measure_text_width("pressed hit"),
    measure_text_width("released hit")
  ) + Font.pad * 2

  local button_name_w = max_text_width(BUTTONS)
  local button_col_w = button_name_w + gap + state_col_w + gap + state_col_w + gap + state_col_w
  local buttons_w = button_col_w * 2 + gap

  local pad_name_w = measure_text_width("name")
  local pad_type_w = measure_text_width("type")
  if Snapshot ~= nil then
    for pad = 1, MAX_PADS do
      local p = Snapshot.pads[pad]
      pad_name_w = math.max(pad_name_w, measure_text_width(tostring(p.name)))
      pad_type_w = math.max(pad_type_w, measure_text_width(tostring(p.type)))
    end
  end

  local pad_col_w = measure_text_width("pad") + Font.pad * 2
  local connected_col_w = measure_text_width("connected") + Font.pad * 2
  local type_col_w = pad_type_w + Font.pad * 2
  local name_col_w = pad_name_w + Font.pad * 2

  local pad_w = pad_col_w + gap + connected_col_w + gap + type_col_w + gap + name_col_w
  pad_w = math.max(pad_w, 620)

  local axis_label_w = math.max(
    measure_text_width("right stick"),
    measure_text_width("released hit")
  ) + Font.pad * 2

  local trigger_value_w = math.max(measure_text_width("value"), measure_text_width("0.00")) + Font.pad * 2
  local stick_value_w = measure_text_width("x -1.00") + Font.pad * 2
  local stick_bar_w = 180
  local trigger_bar_w = 150

  local axis_w = axis_label_w + gap + stick_value_w + stick_bar_w + gap + stick_value_w + stick_bar_w
  local trigger_w = axis_label_w + gap + trigger_value_w + trigger_bar_w + gap + state_col_w + gap + state_col_w + gap + state_col_w
  local analog_w = math.max(axis_w, trigger_w, 660)

  local top_w = pad_w + gap + analog_w
  local content_w = math.max(top_w, buttons_w)
  local win_w = math.max(MIN_WIN_W, content_w + m * 2)

  local header_rows = 4
  local top_rows = math.max(2 + 1 + MAX_PADS, 2 + #SIDES + 2 + 1 + #SIDES)
  local button_rows = 2 + math.ceil(#BUTTONS / 2)

  local win_h = math.max(
    MIN_WIN_H,
    m + header_rows * row + gap + top_rows * row + gap + button_rows * row + m
  )

  local button_y = m + header_rows * row + gap + top_rows * row + gap

  Layout = {
    win_w = win_w,
    win_h = win_h,

    margin = m,
    gap = gap,
    row = row,

    header_x = m,
    header_y = m,

    pads_x = m,
    pads_y = m + header_rows * row + gap,
    pads_w = pad_w,

    analog_x = m + pad_w + gap,
    analog_y = m + header_rows * row + gap,
    analog_w = analog_w,

    buttons_x = m,
    buttons_y = button_y,
    button_col_w = button_col_w,
    button_name_w = button_name_w,
    state_col_w = state_col_w,

    pad_col_w = pad_col_w,
    connected_col_w = connected_col_w,
    type_col_w = type_col_w,
    name_col_w = name_col_w,

    axis_label_w = axis_label_w,
    stick_value_w = stick_value_w,
    stick_bar_w = stick_bar_w,
    trigger_value_w = trigger_value_w,
    trigger_bar_w = trigger_bar_w,
  }
end

local function grow_window_to_fit()
  if not AUTO_GROW_WINDOW or Layout == nil then
    return
  end

  local w, h = window.get_size()
  if w < Layout.win_w or h < Layout.win_h then
    window.set_size(math.max(w, Layout.win_w), math.max(h, Layout.win_h))
  end
end

local function draw_state_box(x, y, on, color)
  local s = Font.box
  local box_y = y + math.floor((Font.line - s) / 2)

  graphics.draw_rect(x, box_y, s, s, on and color or C.off)
  graphics.debug_rect(x, box_y, s, s, C.line)
  graphics.draw_text(tostring(on), x + s + Font.pad, y, on and C.text or C.dim)
end

local function draw_bar(x, y, w, h, value, lo, hi, color)
  local t = (value - lo) / (hi - lo)
  t = clamp(t, 0, 1)

  graphics.draw_rect(x, y, w, h, C.off)
  graphics.draw_rect(x, y, math.floor(w * t), h, color)
  graphics.debug_rect(x, y, w, h, C.line)
end

local function draw_center_bar(x, y, w, h, value, color)
  value = clamp(value, -1, 1)

  local cx = x + math.floor(w / 2)
  graphics.draw_rect(x, y, w, h, C.off)

  if value >= 0 then
    graphics.draw_rect(cx, y, math.floor((w / 2) * value), h, color)
  else
    local fw = math.floor((w / 2) * -value)
    graphics.draw_rect(cx - fw, y, fw, h, color)
  end

  graphics.draw_rect(cx, y, 1, h, C.text)
  graphics.debug_rect(x, y, w, h, C.line)
end

local function draw_header()
  local x = Layout.header_x
  local y = Layout.header_y
  local row = Layout.row

  graphics.draw_text("Newt Gamepad Test", x, y, C.text)
  y = y + row

  graphics.draw_text(
    "1-8 select pad   [ / ] threshold   ESC close   edge hits latch for " .. fmt2(EDGE_FLASH_TIME) .. "s",
    x, y, C.dim
  )
  y = y + row

  graphics.draw_text("selected pad: " .. SELECTED_PAD, x, y, C.yellow)
  graphics.draw_text("gamepad.get_count() -> " .. tostring(Snapshot.count), x + measure_text_width("selected pad: 8") + Layout.gap, y, C.blue)
  graphics.draw_text("trigger threshold: " .. fmt2(TRIGGER_THRESHOLD), x + measure_text_width("selected pad: 8") + measure_text_width("gamepad.get_count() -> 8") + Layout.gap * 2, y, C.blue)
  y = y + row

  graphics.draw_text(
    "default: connected=" .. tostring(Snapshot.default_connected) ..
    "  name=" .. tostring(Snapshot.default_name) ..
    "  type=" .. tostring(Snapshot.default_type),
    x, y, C.dim
  )
end

local function draw_pad_summary()
  local x = Layout.pads_x
  local y = Layout.pads_y
  local row = Layout.row
  local gap = Layout.gap

  local col_pad = x
  local col_connected = col_pad + Layout.pad_col_w + gap
  local col_type = col_connected + Layout.connected_col_w + gap
  local col_name = col_type + Layout.type_col_w + gap

  graphics.draw_text("Pads", x, y, C.text)
  y = y + row

  graphics.draw_text("pad", col_pad, y, C.dim)
  graphics.draw_text("connected", col_connected, y, C.dim)
  graphics.draw_text("type", col_type, y, C.dim)
  graphics.draw_text("name", col_name, y, C.dim)
  y = y + row

  for pad = 1, MAX_PADS do
    local p = Snapshot.pads[pad]
    local col = p.connected and C.green or C.dim

    if pad == SELECTED_PAD then
      graphics.draw_rect(x - Font.pad, y - 2, Layout.pads_w + Font.pad * 2, row - 1, C.panel)
    elseif pad % 2 == 0 then
      graphics.draw_rect(x - Font.pad, y - 2, Layout.pads_w + Font.pad * 2, row - 1, C.panel2)
    end

    graphics.draw_text(tostring(pad), col_pad, y, col)
    graphics.draw_text(tostring(p.connected), col_connected, y, col)
    graphics.draw_text(tostring(p.type), col_type, y, col)
    graphics.draw_text(tostring(p.name), col_name, y, col)

    y = y + row
  end
end

local function draw_axis_table()
  local x = Layout.analog_x
  local y = Layout.analog_y
  local row = Layout.row
  local gap = Layout.gap

  local label_w = Layout.axis_label_w
  local value_w = Layout.stick_value_w
  local bar_w = Layout.stick_bar_w
  local bar_h = Font.box

  local col_label = x
  local col_x_value = col_label + label_w + gap
  local col_x_bar = col_x_value + value_w
  local col_y_value = col_x_bar + bar_w + gap
  local col_y_bar = col_y_value + value_w

  graphics.draw_text("Sticks: gamepad.stick(side, pad)", x, y, C.text)
  y = y + row

  for _, side in ipairs(SIDES) do
    local s = Snapshot.sticks[side]

    graphics.draw_text(side .. " stick", col_label, y, C.blue)
    graphics.draw_text("x " .. fmt2(s.x), col_x_value, y, C.text)
    draw_center_bar(col_x_bar, y + math.floor((Font.line - bar_h) / 2), bar_w, bar_h, s.x, C.blue)
    graphics.draw_text("y " .. fmt2(s.y), col_y_value, y, C.text)
    draw_center_bar(col_y_bar, y + math.floor((Font.line - bar_h) / 2), bar_w, bar_h, s.y, C.blue)

    y = y + row
  end

  y = y + row
  graphics.draw_text("Triggers: trigger / trigger_down / trigger_pressed / trigger_released", x, y, C.text)
  y = y + row

  local state_col_w = Layout.state_col_w
  local trigger_bar_w = Layout.trigger_bar_w

  local t_label = x
  local t_value = t_label + label_w + gap
  local t_bar = t_value + Layout.trigger_value_w
  local t_down = t_bar + trigger_bar_w + gap
  local t_pressed = t_down + state_col_w + gap
  local t_released = t_pressed + state_col_w + gap

  graphics.draw_text("trigger", t_label, y, C.dim)
  graphics.draw_text("value", t_value, y, C.dim)
  graphics.draw_text("down", t_down, y, C.dim)
  graphics.draw_text("pressed hit", t_pressed, y, C.dim)
  graphics.draw_text("released hit", t_released, y, C.dim)
  y = y + row

  for _, side in ipairs(SIDES) do
    local t = Snapshot.triggers[side]

    graphics.draw_text(side, t_label, y, C.blue)
    graphics.draw_text(fmt2(t.value), t_value, y, C.text)
    draw_bar(t_bar, y + math.floor((Font.line - bar_h) / 2), trigger_bar_w, bar_h, t.value, 0, 1, C.green)
    draw_state_box(t_down, y, t.down, C.green)
    draw_state_box(t_pressed, y, t.pressed_hit, C.yellow)
    draw_state_box(t_released, y, t.released_hit, C.red)

    y = y + row
  end
end

local function draw_button_column(x, y, first_i, last_i)
  local row = Layout.row
  local gap = Layout.gap

  local name_w = Layout.button_name_w
  local state_col_w = Layout.state_col_w

  local col_button = x
  local col_down = col_button + name_w + gap
  local col_pressed = col_down + state_col_w + gap
  local col_released = col_pressed + state_col_w + gap

  graphics.draw_text("button", col_button, y, C.dim)
  graphics.draw_text("down", col_down, y, C.dim)
  graphics.draw_text("pressed hit", col_pressed, y, C.dim)
  graphics.draw_text("released hit", col_released, y, C.dim)
  y = y + row

  for i = first_i, last_i do
    local b = Snapshot.buttons[i]
    if b == nil then
      break
    end

    if i % 2 == 0 then
      graphics.draw_rect(x - Font.pad, y - 2, Layout.button_col_w + Font.pad * 2, row - 1, C.panel2)
    end

    graphics.draw_text(b.token, col_button, y, C.blue)
    draw_state_box(col_down, y, b.down, C.green)
    draw_state_box(col_pressed, y, b.pressed_hit, C.yellow)
    draw_state_box(col_released, y, b.released_hit, C.red)

    y = y + row
  end
end

local function draw_buttons_table()
  local x = Layout.buttons_x
  local y = Layout.buttons_y

  graphics.draw_text("Buttons: down is live, edge columns are latched display hits", x, y, C.text)
  y = y + Layout.row

  local split = math.ceil(#BUTTONS / 2)
  draw_button_column(x, y, 1, split)
  draw_button_column(x + Layout.button_col_w + Layout.gap, y, split + 1, #BUTTONS)
end

runtime.init = function()
  window.set_title("Newt Gamepad Test")
  refresh_font_metrics()
  window.set_size(MIN_WIN_W, MIN_WIN_H)
end

runtime.update = function(dt)
  update_keyboard_controls()
  build_snapshot(dt)
  build_layout()
  grow_window_to_fit()
end

runtime.draw = function()
  graphics.clear(C.bg)

  if Snapshot == nil then
    refresh_font_metrics()
    graphics.draw_text("Waiting for first update...", Font.margin, Font.margin, C.text)
    return
  end

  if Layout == nil then
    build_layout()
  end

  draw_header()
  draw_pad_summary()
  draw_axis_table()
  draw_buttons_table()
end