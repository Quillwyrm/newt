local C = {
    bg = rgba(18, 20, 24),
    text = rgba(235, 238, 245),
    dim = rgba(135, 145, 160),
    good = rgba(90, 240, 145),
    bad = rgba(255, 105, 105),
    warn = rgba(255, 215, 105),
    blue = rgba(120, 190, 255),
  }
  
  local LOG = {}
  local ACTIVE = 0
  local GEN_A, GEN_B = nil, nil
  local HIST = nil
  
  local function log(msg, color)
    table.insert(LOG, 1, { text = msg, color = color or C.text })
    while #LOG > 18 do table.remove(LOG) end
    print(msg)
  end
  
  local function same_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
      if a[i] ~= b[i] then return false end
    end
    return true
  end
  
  local function seq(handle, seed, count)
    random.set_generator(handle)
    random.set_seed(seed)
  
    local out = {}
    for i = 1, count do
      out[i] = random.int(1, 1000000)
    end
    return out
  end
  
  local function check(name, ok, detail)
    log((ok and "PASS " or "FAIL ") .. name .. (detail and (" - " .. detail) or ""), ok and C.good or C.bad)
  end
  
  local function expect_error(name, fn)
    local ok = pcall(fn)
    check(name, not ok, ok and "expected error" or nil)
  end
  
  local function run_tests()
    LOG = {}
  
    if random == nil then
      log("random module is nil. Wire register_random_api() in register_lua_api().", C.bad)
      return
    end
  
    local a = seq(0, 12345, 8)
    local b = seq(0, 12345, 8)
    check("same seed repeats same sequence", same_list(a, b))
  
    local c = seq(GEN_A, 777, 8)
    local d = seq(GEN_B, 777, 8)
    check("separate generators can produce same seeded sequence", same_list(c, d))
  
    random.set_generator(GEN_A)
    random.set_seed(10)
    local a1 = random.int(1, 1000000)
    random.set_generator(GEN_B)
    random.set_seed(20)
    for _ = 1, 20 do random.int(1, 1000000) end
    random.set_generator(GEN_A)
    local a2 = random.int(1, 1000000)
  
    random.set_generator(GEN_A)
    random.set_seed(10)
    local r1 = random.int(1, 1000000)
    local r2 = random.int(1, 1000000)
    check("generator streams are isolated", a1 == r1 and a2 == r2)
  
    random.set_generator(0)
    random.set_seed(99)
  
    local floats_ok = true
    for _ = 1, 500 do
      local v = random.float()
      if v < 0 or v >= 1 then floats_ok = false end
    end
    check("float returns [0, 1)", floats_ok)
  
    local ints_ok = true
    for _ = 1, 500 do
      local v = random.int(-3, 3)
      if v < -3 or v > 3 then ints_ok = false end
    end
    check("int returns inclusive bounds", ints_ok)
  
    local items = { "red", "green", "blue" }
    local pick_ok = true
    for _ = 1, 100 do
      local v = random.pick(items)
      if v ~= "red" and v ~= "green" and v ~= "blue" then pick_ok = false end
    end
    check("uniform pick returns list values", pick_ok)
  
    local weighted_ok = true
    for _ = 1, 100 do
      if random.pick({ "no", "yes" }, { 0, 1 }) ~= "yes" then weighted_ok = false end
    end
    check("zero weight is never picked", weighted_ok)
  
    expect_error("set_seed rejects negative seed", function() random.set_seed(-1) end)
    expect_error("set_generator rejects invalid handle", function() random.set_generator(999) end)
    expect_error("int rejects min > max", function() random.int(10, 1) end)
    expect_error("pick rejects empty list", function() random.pick({}) end)
    expect_error("pick rejects mismatched weights", function() random.pick({ "a" }, { 1, 2 }) end)
    expect_error("pick rejects negative weights", function() random.pick({ "a" }, { -1 }) end)
    expect_error("pick rejects zero weight sum", function() random.pick({ "a", "b" }, { 0, 0 }) end)
  
    random.set_generator(ACTIVE)
  end
  
  local function roll_once()
    if random == nil then return end
  
    local item = random.pick({ "sword", "potion", "coin" })
    local weighted = random.pick({ "common", "rare", "legendary" }, { 80, 18, 2 })
  
    log(string.format(
      "gen %d | float %.6f | int %d | pick %s | weighted %s",
      ACTIVE,
      random.float(),
      random.int(1, 6),
      item,
      weighted
    ), C.blue)
  end
  
  local function run_histogram()
    if random == nil then return end
  
    HIST = { common = 0, rare = 0, legendary = 0 }
    for _ = 1, 1000 do
      local v = random.pick({ "common", "rare", "legendary" }, { 80, 18, 2 })
      HIST[v] = HIST[v] + 1
    end
  
    log(string.format("hist 1000: common=%d rare=%d legendary=%d", HIST.common, HIST.rare, HIST.legendary), C.warn)
  end
  
  runtime.init = function()
    window.set_title("Newt Random Test")
    window.set_size(980, 620)
  
    if random == nil then
      log("random module is nil. Wire register_random_api() first.", C.bad)
      return
    end
  
    random.set_generator(0)
    random.set_seed(12345)
  
    GEN_A = random.new_generator(111)
    GEN_B = random.new_generator(222)
    ACTIVE = 0
  
    log("random test ready", C.good)
    run_tests()
  end
  
  runtime.update = function()
    if input.pressed("escape") then window.close() end
    if random == nil then return end
  
    if input.pressed("0") then ACTIVE = 0; random.set_generator(0); log("active generator -> 0", C.blue) end
    if input.pressed("1") then ACTIVE = GEN_A; random.set_generator(GEN_A); log("active generator -> " .. GEN_A, C.blue) end
    if input.pressed("2") then ACTIVE = GEN_B; random.set_generator(GEN_B); log("active generator -> " .. GEN_B, C.blue) end
  
    if input.pressed("r") then random.set_seed(12345); log("set_seed(12345) on gen " .. ACTIVE, C.warn) end
    if input.pressed("space") then roll_once() end
    if input.pressed("t") then run_tests() end
    if input.pressed("h") then run_histogram() end
  end
  
  runtime.draw = function()
    graphics.clear(C.bg)
  
    graphics.draw_text("Newt Random Test", 20, 18, C.text)
    graphics.draw_text("SPACE roll   R reseed active   0/1/2 switch generator   T tests   H histogram   ESC close", 20, 44, C.dim)
  
    if random == nil then
      graphics.draw_text("random module is nil. Add register_random_api() to register_lua_api().", 20, 90, C.bad)
      return
    end
  
    graphics.draw_text("active generator: " .. tostring(ACTIVE), 20, 78, C.warn)
    graphics.draw_text("handles: startup=0  A=" .. tostring(GEN_A) .. "  B=" .. tostring(GEN_B), 20, 102, C.dim)
  
    local y = 142
    for i = 1, #LOG do
      graphics.draw_text(LOG[i].text, 20, y, LOG[i].color)
      y = y + 24
    end
  end
  