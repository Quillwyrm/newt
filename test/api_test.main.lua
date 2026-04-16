-- Luagame public Lua API test suite.
--
-- Scope:
-- - Public Lua userland API only.
-- - Real assets, real backends, no mocks.
-- - Smoke + integration coverage for the host boundary.
--
-- Non-goals:
-- - Screenshot / golden rendering validation.
-- - Audio perceptual correctness.
-- - Exhaustive argument fuzzing.
--
-- Shape:
-- - Top-level tests cover pre-init contracts.
-- - runtime.init() covers most API contract tests.
-- - runtime.update() covers time-sensitive audio behavior.
-- - runtime.draw() covers draw-path smoke and graphics robustness.

local abs, floor, max = math.abs, math.floor, math.max

local function pack(...)
    return { n = select("#", ...), ... }
end

local function repr(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "nil" then return "nil" end
    return tostring(v)
end

local function clean_error(err)
    err = tostring(err or "unknown error")
    err = err:gsub("^[A-Za-z]:\\[^\n]-:%d+:%s*", "")
    err = err:gsub("^.-/[^/\n]-:%d+:%s*", "")
    err = err:gsub("^.-\\[^\\\n]-:%d+:%s*", "")
    err = err:gsub("\n+", " ")
    return err
end

local Runner = {
    total = 0,
    passed = 0,
    failed = 0,
    section = nil,
    failures = {},
}

local function section(name)
    -- Failed tests can exit before explicit frees. Collect between sections so
    -- dead resources do not accumulate across the suite.
    collectgarbage("collect")
    Runner.section = name
    print("")
    print(("== %s =="):format(name))
end

local function case_line(prefix, api, desc, detail)
    if detail and detail ~= "" then
        print(("  %s  %s : %s [%s]"):format(prefix, api, desc, detail))
    else
        print(("  %s  %s : %s"):format(prefix, api, desc))
    end
end

local function test(api, desc, fn)
    Runner.total = Runner.total + 1

    local ok_run, err = pcall(fn)
    if ok_run then
        Runner.passed = Runner.passed + 1
        case_line("PASS", api, desc)
        return
    end

    Runner.failed = Runner.failed + 1
    local detail = clean_error(err)
    Runner.failures[#Runner.failures + 1] = {
        api = api,
        desc = desc,
        detail = detail,
    }
    case_line("FAIL", api, desc, detail)
end

local function fail(msg)
    error(msg, 0)
end

local function ok(v, msg)
    if not v then fail(msg or "expected truthy value") end
end

local function eq(a, b, msg)
    if a ~= b then
        fail((msg or "values differ") .. ": got " .. repr(a) .. ", expected " .. repr(b))
    end
end

local function is_type(v, t, msg)
    if type(v) ~= t then
        fail((msg or "wrong type") .. ": got " .. type(v) .. ", expected " .. t)
    end
end

local function near(a, b, eps, msg)
    if abs(a - b) > (eps or 1e-4) then
        fail((msg or "values not near") .. ": got " .. tostring(a) .. ", expected " .. tostring(b))
    end
end

local function expect_throw(fn)
    local ok_run = pcall(fn)
    if ok_run then
        fail("expected throw")
    end
end

local function expect_nothrow(fn)
    local ok_run, err = pcall(fn)
    if not ok_run then
        fail("unexpected throw: " .. clean_error(err))
    end
end

local function expect_nil_err(a, b, msg)
    if a ~= nil or type(b) ~= "string" then
        fail((msg or "expected nil, err") .. ": got " .. repr(a) .. ", " .. repr(b))
    end
end

local function expect_false_err(a, b, msg)
    if a ~= false or type(b) ~= "string" then
        fail((msg or "expected false, err") .. ": got " .. repr(a) .. ", " .. repr(b))
    end
end

local function find_entry(list, name)
    for i = 1, #list do
        if list[i].name == name then
            return list[i]
        end
    end
    return nil
end

local resource_dir = filesystem.get_resource_directory()
if type(resource_dir) ~= "string" then
    resource_dir = "."
end

local original_cwd = filesystem.get_working_directory()
if type(original_cwd) ~= "string" then
    original_cwd = resource_dir
end

local path_sep = resource_dir:find("\\", 1, true) and "\\" or "/"

local function join_path(a, b)
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then
        return a .. b
    end
    return a .. path_sep .. b
end

local ASSET_SFX = join_path(resource_dir, "test_sfx.wav")
local ASSET_BGM = join_path(resource_dir, "test_bgm.ogg")
local ASSET_IMG = join_path(resource_dir, "test_img.png")
local ASSET_FONT = join_path(resource_dir, "test_font.ttf")

local RUN_ID = tostring(os.time()) .. "_" .. tostring(floor((os.clock() or 0) * 1000000))
local SUITE_ROOT = join_path(original_cwd, "__luagame_test_" .. RUN_ID)
local sandbox_counter = 0

local function rm_tree(path)
    local info = filesystem.get_path_info(path)
    if not info then
        return
    end

    if info.kind == "directory" then
        local entries = filesystem.list_directory(path)
        if type(entries) == "table" then
            for i = 1, #entries do
                rm_tree(join_path(path, entries[i].name))
            end
        end
    end

    filesystem.remove(path)
end

local function ensure_suite_root()
    local info = filesystem.get_path_info(SUITE_ROOT)
    if info then
        if info.kind == "directory" then
            return
        end
        fail("suite sandbox root exists but is not a directory")
    end

    local ok_mkdir, err = filesystem.make_directory(SUITE_ROOT)
    if not ok_mkdir then
        fail("suite sandbox root create failed: " .. tostring(err))
    end
end

local function new_sandbox(tag)
    ensure_suite_root()
    sandbox_counter = sandbox_counter + 1

    local dir = join_path(SUITE_ROOT, string.format("%02d_%s", sandbox_counter, tag))
    local ok_mkdir, err = filesystem.make_directory(dir)
    if not ok_mkdir then
        fail("sandbox create failed: " .. tostring(err))
    end
    return dir
end

local function unpack_rgba_u32(c)
    local r = floor(c / 16777216) % 256
    local g = floor(c / 65536) % 256
    local b = floor(c / 256) % 256
    local a = c % 256
    return r, g, b, a
end

local function pack_rgba_u32(r, g, b, a)
    return r * 16777216 + g * 65536 + b * 256 + a
end

local function blend_expected(dst, src, mode)
    local sr, sg, sb, sa = unpack_rgba_u32(src)
    local dr, dg, db, da = unpack_rgba_u32(dst)
    local nr, ng, nb, na

    if mode == "replace" then
        return src
    end

    if sa == 0 then
        return dst
    end

    if mode == "blend" then
        local inv = 255 - sa
        nr = floor((sr * sa + dr * inv) / 255)
        ng = floor((sg * sa + dg * inv) / 255)
        nb = floor((sb * sa + db * inv) / 255)
        na = sa + da - floor((sa * da) / 255)
    elseif mode == "add" then
        nr = math.min(255, dr + sr)
        ng = math.min(255, dg + sg)
        nb = math.min(255, db + sb)
        na = math.min(255, da + sa)
    elseif mode == "multiply" then
        nr = floor((dr * sr) / 255)
        ng = floor((dg * sg) / 255)
        nb = floor((db * sb) / 255)
        na = da
    elseif mode == "erase" then
        nr, ng, nb = dr, dg, db
        na = floor((da * (255 - sa)) / 255)
    elseif mode == "mask" then
        nr, ng, nb = dr, dg, db
        na = floor((da * sa) / 255)
    else
        fail("unknown expected blend mode: " .. tostring(mode))
    end

    return pack_rgba_u32(nr, ng, nb, na)
end

local function new_blank_pixelmap(w, h)
    local pmap, err = graphics.new_pixelmap(w, h)
    if not pmap then
        fail("graphics.new_pixelmap failed: " .. tostring(err))
    end
    return pmap
end

local function assert_pixel(pmap, x, y, color, msg)
    eq(graphics.pixelmap_get_pixel(pmap, x, y), color, msg)
end

local function new_canvas_or_fail(w, h)
    local canvas, err = graphics.new_canvas(w, h)
    if not canvas then
        fail("graphics.new_canvas failed: " .. tostring(err))
    end
    return canvas
end

local function new_font_or_fail(path, size)
    local font, err = graphics.load_font(path, size)
    if not font then
        fail("graphics.load_font failed: " .. tostring(err))
    end
    return font
end

local state = {
    assets = {},
    draw_done = false,
    update_phase = 0,
    update_timer = 0,
    finalized = false,
    audio_progress_handle = nil,
    audio_progress_t0 = nil,
}

section("load phase")

test("audio.config_bus_delay_times", "valid table works before init", function()
    expect_nothrow(function()
        audio.config_bus_delay_times({ [1] = 0.5, [4] = 2.0 })
    end)
end)

test("audio.config_bus_delay_times", "invalid entry throws before init", function()
    expect_throw(function()
        audio.config_bus_delay_times({ [1] = "bad" })
    end)
end)

test("audio.load_sound", "throws before audio init", function()
    expect_throw(function()
        audio.load_sound(ASSET_SFX)
    end)
end)

test("graphics.load_image", "throws before renderer init", function()
    expect_throw(function()
        graphics.load_image(ASSET_IMG)
    end)
end)

test("input.down", "throws before input init", function()
    expect_throw(function()
        input.down("a")
    end)
end)

test("window.get_size", "throws before window init", function()
    expect_throw(function()
        window.get_size()
    end)
end)

test("graphics.set_default_filter", "nearest works before init", function()
    expect_nothrow(function()
        graphics.set_default_filter("nearest")
    end)
end)

test("graphics.set_default_filter", "linear works before init", function()
    expect_nothrow(function()
        graphics.set_default_filter("linear")
    end)
end)

test("graphics.set_default_filter", "bad token throws before init", function()
    expect_throw(function()
        graphics.set_default_filter("bad")
    end)
end)

local function run_globals_tests()
    section("globals")

    -- The host should reject wrong userdata kinds cleanly at the Lua boundary.
    test("userdata boundary", "rejects mismatched userdata types cleanly", function()
        local pmap = new_blank_pixelmap(2, 2)
        local canvas = new_canvas_or_fail(2, 2)
        expect_throw(function() graphics.draw_image(pmap, 0, 0) end)
        expect_throw(function() audio.get_sound_info(canvas) end)
        free(pmap)
        free(canvas)
    end)

    test("rgba", "packed rgb defaults alpha", function()
        eq(rgba(0x112233), 0x112233FF)
    end)

    test("rgba", "packed rgba unchanged", function()
        eq(rgba(0x11223344), 0x11223344)
    end)

    test("rgba", "3 component form", function()
        eq(rgba(0x11, 0x22, 0x33), 0x112233FF)
    end)

    test("rgba", "4 component form", function()
        eq(rgba(0x11, 0x22, 0x33, 0x44), 0x11223344)
    end)

    test("rgba", "string forms parse hex and bad strings fall back to white", function()
        eq(rgba("#112233"), 0x112233FF)
        eq(rgba("#11223344"), 0x11223344)
        eq(rgba("112233"), 0x112233FF)
        eq(rgba(""), 0xFFFFFFFF)
        eq(rgba("#"), 0xFFFFFFFF)
        eq(rgba("zzzzzz"), 0xFFFFFFFF)
    end)

    test("rgba", "invalid type falls back to white", function()
        eq(rgba({}), 0xFFFFFFFF)
    end)

    test("free", "ignores non-userdata", function()
        expect_nothrow(function()
            free(123)
            free("x")
            free(nil)
        end)
    end)

    test("free/graphics.get_image_size", "freed image query returns nil,nil", function()
        local img, err = graphics.load_image(ASSET_IMG)
        ok(img, err)
        free(img)
        local w, h = graphics.get_image_size(img)
        eq(w, nil)
        eq(h, nil)
        expect_nothrow(function() free(img) end)
    end)

    test("free/graphics.get_pixelmap_size", "freed pixelmap query returns nil,nil", function()
        local pmap = new_blank_pixelmap(4, 4)
        free(pmap)
        local w, h = graphics.get_pixelmap_size(pmap)
        eq(w, nil)
        eq(h, nil)
        expect_nothrow(function() free(pmap) end)
    end)

    test("free/audio.get_sound_info", "freed sound query returns nil,nil,nil", function()
        local sound, err = audio.load_sound(ASSET_SFX)
        ok(sound, err)
        free(sound)
        local a, b, c = audio.get_sound_info(sound)
        eq(a, nil)
        eq(b, nil)
        eq(c, nil)
        expect_nothrow(function() free(sound) end)
    end)
end

local function run_filesystem_tests()
    section("filesystem")

    test("filesystem.*", "representative arity misuse throws", function()
        expect_throw(function() filesystem.get_resource_directory(1) end)
        expect_throw(function() filesystem.get_working_directory(1) end)
        expect_throw(function() filesystem.set_working_directory() end)
        expect_throw(function() filesystem.get_args(1) end)
        expect_throw(function() filesystem.list_directory() end)
        expect_throw(function() filesystem.get_path_info() end)
        expect_throw(function() filesystem.read_file() end)
        expect_throw(function() filesystem.write_file("x") end)
        expect_throw(function() filesystem.make_directory() end)
        expect_throw(function() filesystem.rename("x") end)
        expect_throw(function() filesystem.remove() end)
    end)

    test("filesystem.get_resource_directory", "returns string", function()
        local dir, err = filesystem.get_resource_directory()
        ok(dir, err)
        is_type(dir, "string")
    end)

    test("filesystem.get_working_directory", "returns string", function()
        local dir, err = filesystem.get_working_directory()
        ok(dir, err)
        is_type(dir, "string")
    end)

    test("filesystem.set_working_directory/get_working_directory", "roundtrips and restores", function()
        local cwd, err = filesystem.get_working_directory()
        ok(cwd, err)

        local dir = new_sandbox("cwd")
        local ok_set, err_set = filesystem.set_working_directory(dir)
        ok(ok_set, err_set)

        local changed, err_changed = filesystem.get_working_directory()
        ok(changed, err_changed)
        eq(changed, dir)

        local ok_restore, err_restore = filesystem.set_working_directory(cwd)
        ok(ok_restore, err_restore)

        local restored, err_restored = filesystem.get_working_directory()
        ok(restored, err_restored)
        eq(restored, cwd)
    end)

    test("filesystem.set_working_directory", "missing path returns false, err", function()
        local ok_set, err = filesystem.set_working_directory(join_path(SUITE_ROOT, "does_not_exist"))
        expect_false_err(ok_set, err)
    end)

    test("filesystem.get_args", "returns array of strings", function()
        local args = filesystem.get_args()
        eq(type(args), "table")
        for i = 1, #args do
            is_type(args[i], "string")
        end
    end)

    test("filesystem.make_directory", "existing dir returns false, err", function()
        local dir = new_sandbox("fs_mkdir_exists")
        local ok_mkdir, err = filesystem.make_directory(dir)
        expect_false_err(ok_mkdir, err)
    end)

    test("filesystem.remove", "empty dir returns true", function()
        local dir = new_sandbox("fs_remove_empty")
        local ok_remove, err = filesystem.remove(dir)
        ok(ok_remove, err)
    end)

    test("filesystem.make_directory/write_file/read_file/get_path_info/list_directory/rename/remove", "roundtrip and metadata", function()
        local dir = new_sandbox("fs_roundtrip")
        local file_a = join_path(dir, "roundtrip.bin")
        local file_b = join_path(dir, "renamed.bin")

        local ok_write, err_write = filesystem.write_file(file_a, "hello")
        ok(ok_write, err_write)

        local data, err_read = filesystem.read_file(file_a)
        ok(data, err_read)
        eq(data, "hello")

        local info, err_info = filesystem.get_path_info(file_a)
        ok(info, err_info)
        eq(type(info), "table")
        eq(info.kind, "file")
        is_type(info.size, "number")
        is_type(info.modified_time, "number")

        local items, err_list = filesystem.list_directory(dir)
        ok(items, err_list)
        local entry = find_entry(items, "roundtrip.bin")
        ok(entry, "missing directory entry")
        eq(entry.kind, "file")

        local ok_rename, err_rename = filesystem.rename(file_a, file_b)
        ok(ok_rename, err_rename)

        local renamed, err_renamed = filesystem.read_file(file_b)
        ok(renamed, err_renamed)
        eq(renamed, "hello")

        local ok_remove, err_remove = filesystem.remove(file_b)
        ok(ok_remove, err_remove)
    end)

    test("filesystem.list_directory", "mixed file and directory kinds", function()
        local dir = new_sandbox("fs_mixed")
        filesystem.make_directory(join_path(dir, "subdir"))
        filesystem.write_file(join_path(dir, "file.txt"), "data")

        local items = filesystem.list_directory(dir)
        local d_entry = find_entry(items, "subdir")
        local f_entry = find_entry(items, "file.txt")

        ok(d_entry, "missing subdir entry")
        eq(d_entry.kind, "directory")
        ok(f_entry, "missing file entry")
        eq(f_entry.kind, "file")
    end)

    test("filesystem.write_file/read_file", "binary-safe roundtrip with embedded NUL", function()
        local dir = new_sandbox("fs_binary")
        local file_a = join_path(dir, "roundtrip.bin")
        local payload = "a\0b\255c"

        local ok_write, err_write = filesystem.write_file(file_a, payload)
        ok(ok_write, err_write)

        local data, err_read = filesystem.read_file(file_a)
        ok(data, err_read)
        eq(data, payload)
    end)

    test("filesystem.read_file", "missing path returns nil, err", function()
        local dir = new_sandbox("fs_missing_read")
        local data, err = filesystem.read_file(join_path(dir, "missing.bin"))
        expect_nil_err(data, err)
    end)

    test("filesystem.read_file", "reading a directory returns nil, err", function()
        local dir = new_sandbox("fs_read_dir")
        local data, err = filesystem.read_file(dir)
        expect_nil_err(data, err)
    end)

    test("filesystem.write_file", "bad path returns false, err", function()
        local dir = new_sandbox("fs_bad_write")
        local bad = join_path(join_path(dir, "missing_parent"), "nope.bin")
        local ok_write, err = filesystem.write_file(bad, "x")
        expect_false_err(ok_write, err)
    end)

    test("filesystem.list_directory", "missing dir returns nil, err", function()
        local dir = new_sandbox("fs_missing_list")
        local items, err = filesystem.list_directory(join_path(dir, "missing_dir"))
        expect_nil_err(items, err)
    end)

    test("filesystem.get_path_info", "missing path returns nil, err", function()
        local dir = new_sandbox("fs_missing_info")
        local info, err = filesystem.get_path_info(join_path(dir, "missing.bin"))
        expect_nil_err(info, err)
    end)

    test("filesystem.rename", "missing path returns false, err", function()
        local dir = new_sandbox("fs_missing_rename")
        local ok_rename, err = filesystem.rename(join_path(dir, "missing.bin"), join_path(dir, "out.bin"))
        expect_false_err(ok_rename, err)
    end)

    test("filesystem.remove", "missing path returns false, err", function()
        local dir = new_sandbox("fs_missing_remove")
        local ok_remove, err = filesystem.remove(join_path(dir, "missing.bin"))
        expect_false_err(ok_remove, err)
    end)
end

local function run_graphics_asset_tests()
    section("graphics / assets")

    test("graphics.*", "representative arity and type misuse throws", function()
        -- Graphics currently tolerates extra args in places. These checks only
        -- pin down missing required args and obvious wrong-type misuse.
        expect_throw(function() graphics.set_translation(1) end)
        expect_throw(function() graphics.set_clip_rect(1, 2, 3) end)
        expect_throw(function() graphics.new_canvas("string") end)
    end)

    test("graphics.load_image", "missing path returns nil, err", function()
        local img, err = graphics.load_image(join_path(resource_dir, "missing_image.png"))
        expect_nil_err(img, err)
    end)

    test("graphics.load_image/get_image_size", "valid image loads and reports size", function()
        local img, err = graphics.load_image(ASSET_IMG)
        ok(img, err)
        state.assets.image = img

        local w, h = graphics.get_image_size(img)
        is_type(w, "number")
        is_type(h, "number")
        ok(w > 0 and h > 0, "image size should be positive")
    end)

    test("graphics.new_canvas", "rejects non-positive sizes", function()
        expect_throw(function() graphics.new_canvas(0, 64) end)
        expect_throw(function() graphics.new_canvas(-1, 64) end)
    end)

    test("graphics.new_canvas/get_image_size", "valid sizes return Image", function()
        local canvas, err = graphics.new_canvas(32, 16)
        ok(canvas, err)

        local w, h = graphics.get_image_size(canvas)
        eq(w, 32)
        eq(h, 16)

        free(canvas)
    end)

    test("graphics.set_canvas", "accepts canvas nil and no-arg, rejects normal image, ignores dead resource", function()
        local canvas = new_canvas_or_fail(16, 16)

        expect_nothrow(function() graphics.set_canvas(canvas) end)
        expect_nothrow(function() graphics.set_canvas(nil) end)
        expect_nothrow(function() graphics.set_canvas() end)
        expect_throw(function() graphics.set_canvas(state.assets.image) end)

        free(canvas)
        expect_nothrow(function() graphics.set_canvas(canvas) end)
    end)

    test("free/graphics.get_image_size", "freed canvas query returns nil,nil", function()
        local canvas = new_canvas_or_fail(8, 8)
        free(canvas)
        local w, h = graphics.get_image_size(canvas)
        eq(w, nil)
        eq(h, nil)
    end)

    test("graphics.new_pixelmap", "rejects non-positive sizes with nil, err", function()
        local p1, err1 = graphics.new_pixelmap(0, 10)
        expect_nil_err(p1, err1)

        local p2, err2 = graphics.new_pixelmap(-10, 10)
        expect_nil_err(p2, err2)
    end)

    test("graphics.new_pixelmap/get_pixelmap_size", "create and size query work", function()
        local pmap = new_blank_pixelmap(8, 6)
        local w, h = graphics.get_pixelmap_size(pmap)
        eq(w, 8)
        eq(h, 6)
        free(pmap)
    end)

    test("graphics.pixelmap_set_pixel/get_pixel", "set/get and OOB logic work", function()
        local pmap = new_blank_pixelmap(4, 4)
        graphics.pixelmap_set_pixel(pmap, 1, 2, rgba(1, 2, 3, 4))
        assert_pixel(pmap, 1, 2, rgba(1, 2, 3, 4))

        eq(graphics.pixelmap_get_pixel(pmap, -1, 0), 0)
        eq(graphics.pixelmap_get_pixel(pmap, 9, 9), 0)

        expect_nothrow(function()
            graphics.pixelmap_set_pixel(pmap, -100, -100, rgba(255, 255, 255, 255))
        end)
        assert_pixel(pmap, 0, 0, 0)

        free(pmap)
    end)

    test("free/graphics.pixelmap_get_pixel/get_cptr", "freed pixelmap queries return nil", function()
        local pmap = new_blank_pixelmap(2, 2)
        free(pmap)
        eq(graphics.pixelmap_get_pixel(pmap, 0, 0), nil)
        eq(graphics.pixelmap_get_cptr(pmap), nil)
    end)

    test("graphics.save_pixelmap/load_pixelmap", "save/load roundtrip and bad path returns false, err", function()
        local dir = new_sandbox("pixelmap_io")
        local file_png = join_path(dir, "pixelmap.png")
        local pmap = new_blank_pixelmap(3, 3)
        graphics.pixelmap_set_pixel(pmap, 1, 1, rgba(255, 0, 0, 255))

        local ok_save, err_save = graphics.save_pixelmap(pmap, file_png)
        ok(ok_save, err_save)

        local loaded, w, h = graphics.load_pixelmap(file_png)
        ok(loaded)
        eq(w, 3)
        eq(h, 3)
        assert_pixel(loaded, 1, 1, rgba(255, 0, 0, 255))

        local ok_bad, err_bad = graphics.save_pixelmap(pmap, join_path(dir, "missing_dir/out.png"))
        expect_false_err(ok_bad, err_bad)

        free(pmap)
        free(loaded)
    end)

    test("graphics.load_pixelmap", "missing path returns nil, err", function()
        local pmap, err = graphics.load_pixelmap(join_path(resource_dir, "missing_pixelmap.png"))
        expect_nil_err(pmap, err)
    end)

    test("graphics.pixelmap_clone", "produces independent copy", function()
        local a = new_blank_pixelmap(2, 2)
        graphics.pixelmap_set_pixel(a, 0, 0, rgba(10, 20, 30, 40))

        local b, err = graphics.pixelmap_clone(a)
        ok(b, err)

        graphics.pixelmap_set_pixel(b, 0, 0, rgba(90, 80, 70, 60))
        assert_pixel(a, 0, 0, rgba(10, 20, 30, 40))
        assert_pixel(b, 0, 0, rgba(90, 80, 70, 60))

        free(a)
        free(b)
    end)

    test("graphics.pixelmap_clone", "dead source returns nil, err", function()
        local pmap = new_blank_pixelmap(2, 2)
        free(pmap)
        local clone, err = graphics.pixelmap_clone(pmap)
        expect_nil_err(clone, err)
    end)

    test("graphics.pixelmap_get_cptr", "returns lightuserdata", function()
        local pmap = new_blank_pixelmap(2, 2)
        local ptr = graphics.pixelmap_get_cptr(pmap)
        ok(ptr ~= nil)
        eq(type(ptr), "userdata")
        free(pmap)
    end)

    test("graphics.pixelmap_flood_fill", "fills bounded region and ignores OOB and same-color", function()
        local pmap = new_blank_pixelmap(5, 5)
        graphics.blit_rect(pmap, 1, 1, 3, 3, rgba(10, 10, 10, 255), "replace")

        graphics.pixelmap_flood_fill(pmap, 2, 2, rgba(200, 0, 0, 255))
        assert_pixel(pmap, 2, 2, rgba(200, 0, 0, 255))
        assert_pixel(pmap, 0, 0, 0)

        graphics.pixelmap_flood_fill(pmap, 99, 99, rgba(0, 255, 0, 255))
        assert_pixel(pmap, 0, 0, 0)

        graphics.pixelmap_flood_fill(pmap, 2, 2, rgba(200, 0, 0, 255))
        assert_pixel(pmap, 2, 2, rgba(200, 0, 0, 255))

        free(pmap)
    end)

    test("graphics.pixelmap_raycast", "miss and hit contracts", function()
        local pmap = new_blank_pixelmap(8, 8)

        local hit = pack(graphics.pixelmap_raycast(pmap, 0, 0, 7, 7))
        eq(hit.n, 1)
        eq(hit[1], false)

        graphics.pixelmap_set_pixel(pmap, 3, 3, rgba(1, 2, 3, 255))
        local hit2 = pack(graphics.pixelmap_raycast(pmap, 0, 0, 7, 7))
        eq(hit2.n, 4)
        eq(hit2[1], true)
        eq(hit2[2], 3)
        eq(hit2[3], 3)
        eq(hit2[4], rgba(1, 2, 3, 255))

        free(pmap)
    end)

    test("graphics.blit_*", "geometry ops draw and fully clipped cases leave target unchanged", function()
        local p = new_blank_pixelmap(16, 16)

        graphics.blit_rect(p, 1, 1, 4, 3, rgba(255, 0, 0, 255), "replace")
        assert_pixel(p, 2, 2, rgba(255, 0, 0, 255), "blit_rect changed pixel")
        assert_pixel(p, 0, 0, 0, "blit_rect untouched pixel")

        graphics.blit_rect(p, -100, -100, 10, 10, rgba(255, 255, 255, 255), "replace")
        assert_pixel(p, 0, 0, 0, "fully clipped blit_rect unchanged pixel")

        graphics.blit_line(p, 0, 15, 15, 0, rgba(0, 255, 0, 255), "replace")
        assert_pixel(p, 8, 7, rgba(0, 255, 0, 255), "blit_line changed pixel")

        graphics.blit_triangle(p, 8, 1, 12, 8, 4, 8, rgba(0, 0, 255, 255), "replace")
        assert_pixel(p, 8, 5, rgba(0, 0, 255, 255), "blit_triangle changed pixel")

        graphics.blit_circle(p, 8, 8, 2.5, rgba(255, 255, 0, 255), "replace")
        assert_pixel(p, 8, 8, rgba(255, 255, 0, 255), "blit_circle changed pixel")

        graphics.blit_circle_outline(p, 8, 8, 5.0, 1.5, rgba(255, 0, 255, 255), "replace")
        assert_pixel(p, 8, 3, rgba(255, 0, 255, 255), "blit_circle_outline changed pixel")

        graphics.blit_circle_pixel_outline(p, 4, 12, 2, rgba(0, 255, 255, 255), "replace")
        assert_pixel(p, 4, 10, rgba(0, 255, 255, 255), "blit_circle_pixel_outline changed pixel")

        graphics.blit_capsule(p, 1, 12, 10, 12, 1.5, rgba(200, 100, 50, 255), "replace")
        assert_pixel(p, 5, 12, rgba(200, 100, 50, 255), "blit_capsule changed pixel")

        local src = new_blank_pixelmap(2, 2)
        graphics.blit_rect(src, 0, 0, 2, 2, rgba(123, 45, 67, 255), "replace")
        graphics.blit(p, src, 13, 13, "replace")
        assert_pixel(p, 13, 13, rgba(123, 45, 67, 255), "blit changed pixel")

        local src2 = new_blank_pixelmap(4, 4)
        graphics.blit_rect(src2, 1, 1, 2, 2, rgba(89, 90, 91, 255), "replace")
        graphics.blit_region(p, src2, 1, 1, 2, 2, 0, 13, "replace")
        assert_pixel(p, 0, 13, rgba(89, 90, 91, 255), "blit_region changed pixel")

        graphics.blit_rect(p, 0, 0, 0, 5, rgba(1, 1, 1, 255), "replace")
        graphics.blit_circle_pixel_outline(p, 5, 5, -1, rgba(1, 1, 1, 255), "replace")
        graphics.blit_region(p, src2, 100, 100, 2, 2, 0, 0, "replace")

        free(src)
        free(src2)
        free(p)
    end)

    test("graphics.blit_rect", "pixelmap blend modes are deterministic", function()
        local modes = { "replace", "blend", "add", "multiply", "erase", "mask" }
        local dst = rgba(10, 20, 30, 40)
        local src = rgba(100, 150, 200, 128)

        for i = 1, #modes do
            local mode = modes[i]
            local p = new_blank_pixelmap(1, 1)
            graphics.pixelmap_set_pixel(p, 0, 0, dst)
            graphics.blit_rect(p, 0, 0, 1, 1, src, mode)
            assert_pixel(p, 0, 0, blend_expected(dst, src, mode), "mode " .. mode)
            free(p)
        end

        expect_throw(function()
            local p = new_blank_pixelmap(1, 1)
            graphics.blit_rect(p, 0, 0, 1, 1, src, "bad")
        end)
    end)

    test("graphics.new_image_from_pixelmap/update_image_from_pixelmap", "pixelmap bridge works", function()
        local pmap = new_blank_pixelmap(4, 4)
        graphics.pixelmap_set_pixel(pmap, 0, 0, rgba(255, 0, 0, 255))

        local img, err = graphics.new_image_from_pixelmap(pmap)
        ok(img, err)

        local w, h = graphics.get_image_size(img)
        eq(w, 4)
        eq(h, 4)

        expect_nothrow(function() graphics.update_image_from_pixelmap(img, pmap) end)
        expect_nothrow(function() graphics.update_image_from_pixelmap(img, pmap, 0, 0) end)
        expect_nothrow(function() graphics.update_image_region_from_pixelmap(img, pmap, 0, 0, 2, 2, 1, 1) end)
        expect_nothrow(function() graphics.update_image_region_from_pixelmap(img, pmap, -1, 0, 2, 2, 0, 0) end)

        free(pmap)
        expect_nothrow(function() graphics.update_image_from_pixelmap(img, pmap) end)

        free(img)
        local live_pmap = new_blank_pixelmap(2, 2)
        expect_nothrow(function() graphics.update_image_from_pixelmap(img, live_pmap) end)
        free(live_pmap)
    end)

    test("graphics.new_image_from_pixelmap", "dead source returns nil, err", function()
        local pmap = new_blank_pixelmap(2, 2)
        free(pmap)
        local img, err = graphics.new_image_from_pixelmap(pmap)
        expect_nil_err(img, err)
    end)

    test("graphics.save_pixelmap", "freed source returns false, err", function()
        local dir = new_sandbox("pixelmap_dead_save")
        local file_png = join_path(dir, "pixelmap.png")
        local pmap = new_blank_pixelmap(2, 2)
        free(pmap)
        local ok_save, err = graphics.save_pixelmap(pmap, file_png)
        expect_false_err(ok_save, err)
    end)
end

local function run_graphics_text_tests()
    section("graphics / text")

    test("graphics.load_font", "missing path returns nil, err", function()
        local font, err = graphics.load_font(join_path(resource_dir, "missing_font.ttf"), 16)
        expect_nil_err(font, err)
    end)

    test("graphics.load_font", "rejects non-positive size with nil, err", function()
        local f1, e1 = graphics.load_font(ASSET_FONT, 0)
        expect_nil_err(f1, e1)

        local f2, e2 = graphics.load_font(ASSET_FONT, -10)
        expect_nil_err(f2, e2)
    end)

    test("graphics.load_font", "valid font loads", function()
        state.assets.font = new_font_or_fail(ASSET_FONT, 20)
    end)

    test("graphics.set_font", "accepts Font, nil, and no-arg reset; rejects wrong type and arity", function()
        expect_nothrow(function() graphics.set_font(state.assets.font) end)
        expect_nothrow(function() graphics.set_font(nil) end)
        expect_nothrow(function() graphics.set_font() end)
        expect_throw(function() graphics.set_font(state.assets.image) end)
        expect_throw(function() graphics.set_font(state.assets.font, state.assets.font) end)
    end)

    test("graphics text queries", "representative arity and type misuse throws", function()
        expect_throw(function() graphics.get_font_height(state.assets.image) end)
        expect_throw(function() graphics.measure_text() end)
        expect_throw(function() graphics.measure_text_wrap("abc") end)
        expect_throw(function() graphics.measure_text_fit("abc") end)
        expect_throw(function() graphics.font_has_glyph() end)
        expect_throw(function() graphics.get_glyph_metrics() end)
    end)

    test("graphics.get_font_*", "explicit font metrics return numbers", function()
        local font = state.assets.font

        local height = graphics.get_font_height(font)
        local ascent = graphics.get_font_ascent(font)
        local descent = graphics.get_font_descent(font)
        local line_skip = graphics.get_font_line_skip(font)

        is_type(height, "number")
        is_type(ascent, "number")
        is_type(descent, "number")
        is_type(line_skip, "number")

        ok(height > 0, "font height should be positive")
        ok(line_skip > 0, "line skip should be positive")
    end)

    test("graphics.get_font_*", "default font metrics return numbers on no-arg form", function()
        local height = graphics.get_font_height()
        local ascent = graphics.get_font_ascent()
        local descent = graphics.get_font_descent()
        local line_skip = graphics.get_font_line_skip()

        is_type(height, "number")
        is_type(ascent, "number")
        is_type(descent, "number")
        is_type(line_skip, "number")

        ok(height > 0, "default font height should be positive")
        ok(line_skip > 0, "default font line skip should be positive")
    end)

    test("graphics.get_font_*", "default font metrics return numbers on nil form", function()
        local height = graphics.get_font_height(nil)
        local ascent = graphics.get_font_ascent(nil)
        local descent = graphics.get_font_descent(nil)
        local line_skip = graphics.get_font_line_skip(nil)

        is_type(height, "number")
        is_type(ascent, "number")
        is_type(descent, "number")
        is_type(line_skip, "number")

        ok(height > 0, "default font height should be positive")
        ok(line_skip > 0, "default font line skip should be positive")
    end)

    test("graphics.measure_text", "explicit font returns width and height for newline-aware text", function()
        local font = state.assets.font
        local w, h = graphics.measure_text(font, "abc\ndef")
    
        is_type(w, "number")
        is_type(h, "number")
        ok(w >= 0, "measure_text width should be non-negative")
        ok(h > 0, "measure_text height should be positive")
    end)
    
    test("graphics.measure_text", "default font returns width and height on no-arg form", function()
        local w, h = graphics.measure_text("abc\ndef")
    
        is_type(w, "number")
        is_type(h, "number")
        ok(w >= 0, "measure_text width should be non-negative")
        ok(h > 0, "measure_text height should be positive")
    end)
    
    test("graphics.measure_text", "default font returns width and height on nil form", function()
        local w, h = graphics.measure_text(nil, "abc\ndef")
    
        is_type(w, "number")
        is_type(h, "number")
        ok(w >= 0, "measure_text width should be non-negative")
        ok(h > 0, "measure_text height should be positive")
    end)

    test("graphics.measure_text_wrap", "explicit font returns width and height for wrapped text", function()
        local font = state.assets.font
        local w, h = graphics.measure_text_wrap(font, "wrapped text should measure cleanly", 120)

        is_type(w, "number")
        is_type(h, "number")
        ok(w >= 0, "measure_text_wrap width should be non-negative")
        ok(h > 0, "measure_text_wrap height should be positive")
        ok(w <= 120, "wrapped width should not exceed requested width")
    end)

    test("graphics.measure_text_wrap", "default font returns width and height on no-arg form", function()
        local w, h = graphics.measure_text_wrap("wrapped text should measure cleanly", 120)

        is_type(w, "number")
        is_type(h, "number")
        ok(w >= 0, "measure_text_wrap width should be non-negative")
        ok(h > 0, "measure_text_wrap height should be positive")
        ok(w <= 120, "wrapped width should not exceed requested width")
    end)

    test("graphics.measure_text_wrap", "default font returns width and height on nil form", function()
        local w, h = graphics.measure_text_wrap(nil, "wrapped text should measure cleanly", 120)

        is_type(w, "number")
        is_type(h, "number")
        ok(w >= 0, "measure_text_wrap width should be non-negative")
        ok(h > 0, "measure_text_wrap height should be positive")
        ok(w <= 120, "wrapped width should not exceed requested width")
    end)

    test("graphics.measure_text_fit", "explicit font returns fitted width and prefix length", function()
        local font = state.assets.font
        local text = "abcdef"

        local fit_w1, fit_len1 = graphics.measure_text_fit(font, text, 0)
        eq(fit_len1, #text)
        ok(fit_w1 >= 0, "unbounded fit width should be non-negative")

        local fit_w2, fit_len2 = graphics.measure_text_fit(font, text, 40)
        is_type(fit_w2, "number")
        is_type(fit_len2, "number")
        ok(fit_w2 <= 40, "fit width should not exceed requested width")
        ok(fit_len2 >= 0 and fit_len2 <= #text, "fit length should be within ASCII byte length")

        local fit_w3, fit_len3 = graphics.measure_text_fit(font, text, 10000)
        eq(fit_len3, #text)
        ok(fit_w3 >= fit_w2, "larger width should fit at least as much text")
    end)

    test("graphics.measure_text_fit", "default font returns fitted width and prefix length on no-arg form", function()
        local text = "abcdef"

        local fit_w1, fit_len1 = graphics.measure_text_fit(text, 0)
        eq(fit_len1, #text)
        ok(fit_w1 >= 0, "unbounded fit width should be non-negative")

        local fit_w2, fit_len2 = graphics.measure_text_fit(text, 40)
        is_type(fit_w2, "number")
        is_type(fit_len2, "number")
        ok(fit_w2 <= 40, "fit width should not exceed requested width")
        ok(fit_len2 >= 0 and fit_len2 <= #text, "fit length should be within ASCII byte length")
    end)

    test("graphics.measure_text_fit", "default font returns fitted width and prefix length on nil form", function()
        local text = "abcdef"

        local fit_w1, fit_len1 = graphics.measure_text_fit(nil, text, 0)
        eq(fit_len1, #text)
        ok(fit_w1 >= 0, "unbounded fit width should be non-negative")

        local fit_w2, fit_len2 = graphics.measure_text_fit(nil, text, 40)
        is_type(fit_w2, "number")
        is_type(fit_len2, "number")
        ok(fit_w2 <= 40, "fit width should not exceed requested width")
        ok(fit_len2 >= 0 and fit_len2 <= #text, "fit length should be within ASCII byte length")
    end)

    test("graphics.font_has_glyph", "explicit font returns booleans for representative codepoints", function()
        local font = state.assets.font

        eq(type(graphics.font_has_glyph(font, string.byte("A"))), "boolean")
        eq(type(graphics.font_has_glyph(font, string.byte("?"))), "boolean")
        eq(type(graphics.font_has_glyph(font, 9)), "boolean")
    end)

    test("graphics.font_has_glyph", "default font returns booleans on no-arg form", function()
        eq(type(graphics.font_has_glyph(string.byte("A"))), "boolean")
        eq(type(graphics.font_has_glyph(string.byte("?"))), "boolean")
        eq(type(graphics.font_has_glyph(9)), "boolean")
    end)

    test("graphics.font_has_glyph", "default font returns booleans on nil form", function()
        eq(type(graphics.font_has_glyph(nil, string.byte("A"))), "boolean")
        eq(type(graphics.font_has_glyph(nil, string.byte("?"))), "boolean")
        eq(type(graphics.font_has_glyph(nil, 9)), "boolean")
    end)

    test("graphics.get_glyph_metrics", "explicit font returns five numbers for representative glyph", function()
        local font = state.assets.font
        local minx, maxx, miny, maxy, advance = graphics.get_glyph_metrics(font, string.byte("A"))

        is_type(minx, "number")
        is_type(maxx, "number")
        is_type(miny, "number")
        is_type(maxy, "number")
        is_type(advance, "number")
    end)

    test("graphics.get_glyph_metrics", "default font returns five numbers on no-arg form", function()
        local minx, maxx, miny, maxy, advance = graphics.get_glyph_metrics(string.byte("A"))

        is_type(minx, "number")
        is_type(maxx, "number")
        is_type(miny, "number")
        is_type(maxy, "number")
        is_type(advance, "number")
    end)

    test("graphics.get_glyph_metrics", "default font returns five numbers on nil form", function()
        local minx, maxx, miny, maxy, advance = graphics.get_glyph_metrics(nil, string.byte("A"))

        is_type(minx, "number")
        is_type(maxx, "number")
        is_type(miny, "number")
        is_type(maxy, "number")
        is_type(advance, "number")
    end)

    test("free/font queries", "dead explicit font queries return nil", function()
        local font = new_font_or_fail(ASSET_FONT, 18)
        free(font)

        eq(graphics.get_font_height(font), nil)
        eq(graphics.get_font_ascent(font), nil)
        eq(graphics.get_font_descent(font), nil)
        eq(graphics.get_font_line_skip(font), nil)

        local w1, h1 = graphics.measure_text(font, "abc")
        eq(w1, nil)
        eq(h1, nil)

        local w2, h2 = graphics.measure_text_wrap(font, "abc", 50)
        eq(w2, nil)
        eq(h2, nil)

        local fw, fl = graphics.measure_text_fit(font, "abc", 50)
        eq(fw, nil)
        eq(fl, nil)

        eq(graphics.font_has_glyph(font, string.byte("A")), nil)

        local minx, maxx, miny, maxy, advance = graphics.get_glyph_metrics(font, string.byte("A"))
        eq(minx, nil)
        eq(maxx, nil)
        eq(miny, nil)
        eq(maxy, nil)
        eq(advance, nil)
    end)

    test("graphics.font_has_glyph", "dead explicit font returns nil, not false", function()
        local font = new_font_or_fail(ASSET_FONT, 18)
        free(font)
        eq(graphics.font_has_glyph(font, string.byte("A")), nil)
    end)

    test("free/graphics.set_font", "setting a freed font does not throw", function()
        local font = new_font_or_fail(ASSET_FONT, 18)
        free(font)
        expect_nothrow(function() graphics.set_font(font) end)
    end)
end

local function run_audio_tests_init()
    section("audio / init")

    test("audio.*", "representative arity and type misuse throws", function()
        expect_throw(function() audio.load_sound() end)
        expect_throw(function() audio.play() end)
        expect_throw(function() audio.set_voice_volume() end)
    end)

    test("audio.config_bus_delay_times", "throws after init", function()
        expect_throw(function()
            audio.config_bus_delay_times({ [1] = 0.25 })
        end)
    end)

    test("audio.load_sound", "missing path returns nil, err", function()
        local s, err = audio.load_sound(join_path(resource_dir, "missing_audio.wav"))
        expect_nil_err(s, err)
    end)

    test("audio.load_sound", "valid static and stream loads work", function()
        local sfx, err_sfx = audio.load_sound(ASSET_SFX)
        ok(sfx, err_sfx)
        state.assets.sfx = sfx

        local sfx2, err_sfx2 = audio.load_sound(ASSET_SFX, "static")
        ok(sfx2, err_sfx2)
        state.assets.sfx2 = sfx2

        local bgm, err_bgm = audio.load_sound(ASSET_BGM, "stream")
        ok(bgm, err_bgm)
        state.assets.bgm = bgm
    end)

    test("audio.load_sound", "invalid mode throws", function()
        expect_throw(function()
            audio.load_sound(ASSET_SFX, "bad")
        end)
    end)

    test("audio.get_sound_info", "returns expected shapes", function()
        local path1, dur1, stream1 = audio.get_sound_info(state.assets.sfx)
        is_type(path1, "string")
        is_type(dur1, "number")
        eq(stream1, false)

        local path2, dur2, stream2 = audio.get_sound_info(state.assets.bgm)
        is_type(path2, "string")
        is_type(dur2, "number")
        eq(stream2, true)
    end)

    test("audio.play/audio.play_at", "return handles and accept valid arity cascades", function()
        local sfx = state.assets.sfx

        local h1, err1 = audio.play(sfx, 1)
        ok(h1, err1)

        local h2, err2 = audio.play(sfx, 1, 0.5)
        ok(h2, err2)

        local h3, err3 = audio.play(sfx, 1, 0.5, 1.2)
        ok(h3, err3)

        local h4, err4 = audio.play(sfx, 1, 0.5, 1.2, -0.5)
        ok(h4, err4)

        local h5, err5 = audio.play_at(sfx, 2, 100, 200)
        ok(h5, err5)

        local h6, err6 = audio.play_at(sfx, 2, 100, 200, 0.5)
        ok(h6, err6)

        local h7, err7 = audio.play_at(sfx, 2, 100, 200, 0.5, 1.2)
        ok(h7, err7)

        audio.stop_all_voices()
    end)

    test("audio.play/audio.play_at", "invalid bus throws", function()
        expect_throw(function() audio.play(state.assets.sfx, 99) end)
        expect_throw(function() audio.play_at(state.assets.bgm, 99, 0, 0) end)
    end)

    test("audio.set_listener_*/set_default_*", "listener and default setters work across valid modes", function()
        expect_nothrow(function() audio.set_listener_position(10, 20) end)
        expect_nothrow(function() audio.set_listener_rotation(45) end)
        expect_nothrow(function() audio.set_listener_velocity(3, 4) end)
        expect_nothrow(function() audio.set_default_falloff(100) end)
        expect_nothrow(function() audio.set_default_falloff(100, 500) end)

        expect_nothrow(function() audio.set_default_falloff_mode("none") end)
        expect_nothrow(function() audio.set_default_falloff_mode("linear") end)
        expect_nothrow(function() audio.set_default_falloff_mode("exponential") end)
        expect_nothrow(function() audio.set_default_falloff_mode("inverse") end)
        expect_throw(function() audio.set_default_falloff_mode("bad") end)
    end)

    test("free/audio.get_sound_info/audio.play/audio.play_at", "freed sound query returns nil and play returns nil, err", function()
        local temp, err = audio.load_sound(ASSET_BGM, "stream")
        ok(temp, err)
        free(temp)

        local a, b, c = audio.get_sound_info(temp)
        eq(a, nil)
        eq(b, nil)
        eq(c, nil)

        local h1, err1 = audio.play(temp, 1)
        expect_nil_err(h1, err1)

        local h2, err2 = audio.play_at(temp, 1, 0, 0)
        expect_nil_err(h2, err2)
    end)

    test("free/audio.is_voice_playing/audio.get_voice_info", "free sweeps active voices using that sound", function()
        local temp, err = audio.load_sound(ASSET_BGM, "stream")
        ok(temp, err)

        local handle, play_err = audio.play(temp, 1)
        ok(handle, play_err)
        audio.set_voice_looping(handle, true)
        eq(audio.is_voice_playing(handle), true)

        free(temp)
        eq(audio.is_voice_playing(handle), false)

        local t, d = audio.get_voice_info(handle)
        eq(t, nil)
        eq(d, nil)
    end)
end

local function run_window_tests()
    section("window")

    test("window.*", "representative arity misuse throws", function()
        expect_throw(function() window.set_title() end)
        expect_throw(function() window.set_size() end)
    end)

    test("window.should_close", "starts false", function()
        eq(window.should_close(), false)
    end)

    test("window.close/cancel_close/should_close", "cancel_close clears close request", function()
        window.close()
        eq(window.should_close(), true)
        window.cancel_close()
        eq(window.should_close(), false)
    end)

    test("window.get_size/window.get_position", "return numbers", function()
        local w, h = window.get_size()
        is_type(w, "number")
        is_type(h, "number")

        local x, y = window.get_position()
        is_type(x, "number")
        is_type(y, "number")
    end)

    test("window.set_title/set_size/set_position/maximize/minimize", "setters and state work", function()
        expect_nothrow(function() window.set_title("Luagame Lua API Tests") end)
        expect_nothrow(function() window.set_size(960, 540) end)

        local w, h = window.get_size()
        eq(w, 960)
        eq(h, 540)

        expect_nothrow(function() window.set_position(50, 50) end)

        -- Maximize is only meaningful on a resizable window.
        window.set_flags({ "resizable" })
        expect_nothrow(function() window.maximize() end)
        expect_nothrow(function() window.minimize() end)
        window.set_flags(nil)
    end)

    test("window.set_flags", "valid forms work and bad token throws", function()
        expect_nothrow(function() window.set_flags() end)
        expect_nothrow(function() window.set_flags(nil) end)
        expect_nothrow(function() window.set_flags({}) end)
        expect_nothrow(function() window.set_flags({ "resizable" }) end)
        expect_nothrow(function() window.set_flags({ "borderless", "resizable" }) end)
        expect_throw(function() window.set_flags({ "badflag" }) end)
        window.set_flags(nil)
    end)

    test("window.set_cursor/cursor_show/cursor_hide/is_cursor_visible", "cursor API works", function()
        expect_nothrow(function() window.set_cursor("arrow") end)
        expect_throw(function() window.set_cursor("bad") end)
        expect_nothrow(function() window.cursor_show() end)
        eq(type(window.is_cursor_visible()), "boolean")
        expect_nothrow(function() window.cursor_hide() end)
        eq(type(window.is_cursor_visible()), "boolean")
        window.cursor_show()
    end)

    test("window.set_clipboard/get_clipboard", "roundtrip works and rejects NUL", function()
        window.set_clipboard("hello clipboard")
        eq(window.get_clipboard(), "hello clipboard")
        expect_throw(function() window.set_clipboard("a\0b") end)
    end)
end

local function run_input_tests()
    section("input")

    test("input.*", "representative arity misuse throws", function()
        expect_throw(function() input.get_mouse_position(1) end)
        expect_throw(function() input.get_mouse_wheel(1) end)
        expect_throw(function() input.start_text(1) end)
        expect_throw(function() input.stop_text(1) end)
        expect_throw(function() input.get_text(1) end)
    end)

    test("input.down/pressed/repeated/released", "key and mouse queries return booleans", function()
        eq(type(input.down("a")), "boolean")
        eq(type(input.pressed("a")), "boolean")
        eq(type(input.repeated("a")), "boolean")
        eq(type(input.released("a")), "boolean")
        eq(type(input.down("mouse1")), "boolean")
        eq(type(input.pressed("mouse1")), "boolean")
        eq(type(input.released("mouse1")), "boolean")
    end)

    test("input.repeated/down/pressed/released", "mouse repeated rejects and bad tokens throw", function()
        expect_throw(function() input.repeated("mouse1") end)
        expect_throw(function() input.down("__bad__") end)
        expect_throw(function() input.pressed("__bad__") end)
        expect_throw(function() input.repeated("__bad__") end)
        expect_throw(function() input.released("__bad__") end)
    end)

    test("input.get_mouse_position/get_mouse_wheel", "return numbers", function()
        local x, y = input.get_mouse_position()
        is_type(x, "number")
        is_type(y, "number")

        local wx, wy = input.get_mouse_wheel()
        is_type(wx, "number")
        is_type(wy, "number")
    end)

    test("input.start_text/stop_text/get_text", "text API works and empty is exact string", function()
        expect_nothrow(function() input.start_text() end)
        expect_nothrow(function() input.stop_text() end)
        is_type(input.get_text(), "string")
        eq(input.get_text(), "")
    end)
end

local function run_audio_runtime_tests()
    section("audio / runtime")

    test("audio voice stealing", "65th static sound steals oldest and stream fails when pool is full", function()
        local handles = {}
        for i = 1, 64 do
            local h, err = audio.play(state.assets.sfx, 1)
            ok(h, err)
            handles[i] = h
        end

        local h65, err65 = audio.play(state.assets.sfx, 1)
        ok(h65, err65)
        eq(audio.is_voice_playing(handles[1]), false, "oldest voice should be stolen")
        eq(audio.is_voice_playing(h65), true, "new voice should be playing")

        audio.stop_all_voices()

        for i = 1, 64 do
            local h, err = audio.play(state.assets.bgm, 1)
            ok(h, err)
        end

        local h65_stream, err = audio.play(state.assets.bgm, 1)
        expect_nil_err(h65_stream, err)

        audio.stop_all_voices()
    end)

    test("audio voice handle API", "voice lifecycle, bogus handles, and stale handles behave correctly", function()
        local handle, err = audio.play(state.assets.bgm, 1, 0.5, 1.0, 0.0)
        ok(handle, err)
        audio.set_voice_looping(handle, true)
        eq(audio.is_voice_playing(handle), true)

        local t, d = audio.get_voice_info(handle)
        is_type(t, "number")
        is_type(d, "number")

        expect_nothrow(function() audio.set_voice_volume(handle, 0.25) end)
        expect_nothrow(function() audio.set_voice_pitch(handle, 1.1) end)
        expect_nothrow(function() audio.set_voice_pan(handle, -0.2) end)
        expect_nothrow(function() audio.seek_voice(handle, 0.0) end)
        expect_nothrow(function() audio.seek_voice(handle, 0, "samples") end)
        expect_nothrow(function() audio.seek_voice(handle, 999999) end)
        expect_throw(function() audio.seek_voice(handle, 0, "bad") end)
        expect_nothrow(function() audio.fade_voice(handle, 0.8, 0.05) end)

        expect_nothrow(function() audio.set_voice_position(handle, 100, 200) end)
        expect_nothrow(function() audio.set_voice_velocity(handle, 5, 6) end)
        expect_nothrow(function() audio.set_voice_falloff(handle, 100) end)
        expect_nothrow(function() audio.set_voice_falloff(handle, 100, 500) end)
        expect_nothrow(function() audio.set_voice_falloff_intensity(handle, 1.5) end)

        expect_nothrow(function() audio.set_voice_falloff_mode(handle, "none") end)
        expect_nothrow(function() audio.set_voice_falloff_mode(handle, "exponential") end)
        expect_nothrow(function() audio.set_voice_falloff_mode(handle, "linear") end)
        expect_nothrow(function() audio.set_voice_pan_mode(handle, "balance") end)
        expect_nothrow(function() audio.set_voice_pan_mode(handle, "pan") end)
        expect_throw(function() audio.set_voice_falloff_mode(handle, "bad") end)
        expect_throw(function() audio.set_voice_pan_mode(handle, "bad") end)

        audio.pause_voice(handle)
        eq(audio.is_voice_playing(handle), false)
        audio.resume_voice(handle)
        eq(audio.is_voice_playing(handle), true)

        eq(audio.is_voice_playing(999999), false)
        local bt, bd = audio.get_voice_info(999999)
        eq(bt, nil)
        eq(bd, nil)

        audio.stop_voice(handle)
        eq(audio.is_voice_playing(handle), false)
        local t2, d2 = audio.get_voice_info(handle)
        eq(t2, nil)
        eq(d2, nil)

        expect_nothrow(function() audio.set_voice_volume(handle, 1.0) end)
        expect_nothrow(function() audio.set_voice_pitch(handle, 1.0) end)
        expect_nothrow(function() audio.set_voice_pan(handle, 0.0) end)
        expect_nothrow(function() audio.set_voice_position(handle, 0, 0) end)
        expect_nothrow(function() audio.set_voice_velocity(handle, 0, 0) end)
        expect_nothrow(function() audio.set_voice_falloff(handle, 50, 100) end)
        expect_nothrow(function() audio.set_voice_falloff_intensity(handle, 1.0) end)
        expect_nothrow(function() audio.pause_voice(handle) end)
        expect_nothrow(function() audio.resume_voice(handle) end)
        expect_nothrow(function() audio.stop_voice(handle) end)
    end)

    test("audio bus API", "bus controls, invalid bus rules, and stop semantics work", function()
        local h1, err1 = audio.play(state.assets.bgm, 1, 0.4, 1.0, 0.0)
        ok(h1, err1)
        audio.set_voice_looping(h1, true)

        local h2, err2 = audio.play(state.assets.bgm, 2, 0.4, 1.0, 0.0)
        ok(h2, err2)
        audio.set_voice_looping(h2, true)

        expect_nothrow(function() audio.set_bus_volume(0, 0.9) end)
        expect_nothrow(function() audio.set_bus_pitch(0, 1.0) end)
        expect_nothrow(function() audio.set_bus_pan(0, 0.0) end)
        expect_nothrow(function() audio.fade_bus(0, 0.5, 0.05) end)
        expect_nothrow(function() audio.pause_bus(1) end)
        expect_nothrow(function() audio.resume_bus(1) end)

        expect_throw(function() audio.set_bus_volume(99, 1.0) end)
        expect_throw(function() audio.set_bus_pitch(99, 1.0) end)
        expect_throw(function() audio.set_bus_pan(99, 0.0) end)
        expect_throw(function() audio.fade_bus(99, 0.0, 0.1) end)
        expect_throw(function() audio.pause_bus(99) end)
        expect_throw(function() audio.resume_bus(99) end)
        expect_throw(function() audio.stop_bus(99) end)

        expect_throw(function() audio.set_bus_lpf(0, 1000) end)
        expect_throw(function() audio.set_bus_hpf(0, 1000) end)
        expect_throw(function() audio.set_bus_delay_mix(0, 0.5, 0.5) end)
        expect_throw(function() audio.set_bus_delay_feedback(0, 0.5) end)

        expect_nothrow(function() audio.set_bus_lpf(1, 5) end)
        expect_nothrow(function() audio.set_bus_hpf(1, 50000) end)
        expect_nothrow(function() audio.set_bus_delay_mix(1, 2.0) end)
        expect_nothrow(function() audio.set_bus_delay_mix(1, 2.0, -1.0) end)
        expect_nothrow(function() audio.set_bus_delay_feedback(1, 2.0) end)

        audio.stop_bus(1)
        eq(audio.is_voice_playing(h1), false)
        eq(audio.is_voice_playing(h2), true)

        audio.stop_all_voices()
        eq(audio.is_voice_playing(h2), false)
        local stopped_t, stopped_d = audio.get_voice_info(h2)
        eq(stopped_t, nil)
        eq(stopped_d, nil)
    end)
end

local function run_audio_robustness_tests_step0()
    section("audio / robustness")

    -- This is intentionally a backend-facing behavior check, not a strict API
    -- law. It guards against seek being ignored or reporting a wildly wrong
    -- cursor after the call.
    test("audio.get_voice_info", "seek lands near the requested target", function()
        local handle, err = audio.play(state.assets.bgm, 3, 0.3, 1.0, 0.0)
        ok(handle, err)
        audio.set_voice_looping(handle, true)

        audio.seek_voice(handle, 2.5)
        local t0 = select(1, audio.get_voice_info(handle))
        is_type(t0, "number")
        near(t0, 2.5, 0.1)

        state.audio_progress_handle = handle
        state.audio_progress_t0 = t0
    end)
end

local function run_audio_robustness_tests_step1()
    section("audio / time progression")

    test("audio.get_voice_info", "voice time moves forward across updates", function()
        local handle = state.audio_progress_handle
        local t0 = state.audio_progress_t0
        ok(handle ~= nil, "missing progress handle")

        local t1 = select(1, audio.get_voice_info(handle))
        is_type(t1, "number")
        ok(t1 >= t0, "voice time did not move forward")

        audio.stop_voice(handle)
        state.audio_progress_handle = nil
        state.audio_progress_t0 = nil
    end)
end

local function run_graphics_robustness_tests()
    section("graphics / robustness")

    -- This is a crash-resistance check. It does not promise that non-finite
    -- coordinates are meaningful, only that passing them does not wedge the
    -- renderer or poison later graphics state.
    test("graphics non-finite input", "transform and draw tolerate NaN and Infinity without crashing", function()
        local nan = 0 / 0
        local inf = 1 / 0

        expect_nothrow(function() graphics.set_translation(nan, inf) end)
        expect_nothrow(function() graphics.draw_rect(nan, 0, inf, 10, rgba(255, 255, 255, 255)) end)

        graphics.use_screen_space()
    end)
end

local function run_graphics_draw_tests()
    section("graphics / draw")

    test("graphics.clear/draw_rect/debug_line/debug_rect/debug_text", "core draw calls do not throw and omitted colors are accepted", function()
        graphics.clear()
        graphics.clear(rgba(16, 14, 28, 255))
        graphics.draw_rect(10, 10, 20, 30, rgba(255, 0, 0, 255))
        graphics.draw_rect(10, 10, 20, 30)
        graphics.debug_line(0, 0, 50, 50, rgba(0, 255, 0, 255))
        graphics.debug_rect(5, 5, 40, 20, rgba(0, 0, 255, 255))
        graphics.debug_text(10, 60, "draw smoke", rgba(255, 255, 255, 255))
        graphics.debug_text(10, 80, "omitted color txt")
    end)

    test("graphics.set_blend_mode", "accepts valid tokens, no-arg default, and rejects bad token", function()
        local modes = { "replace", "blend", "add", "multiply", "modulate", "premultiplied" }
        for i = 1, #modes do
            graphics.set_blend_mode(modes[i])
        end
        expect_throw(function() graphics.set_blend_mode("bad") end)
        expect_nothrow(function() graphics.set_blend_mode() end)
    end)

    test("graphics.set_clip_rect/get_clip_rect", "disable returns 0,0,0,0", function()
        graphics.set_clip_rect(1, 2, 30, 40)
        local x, y, w, h = graphics.get_clip_rect()
        eq(x, 1)
        eq(y, 2)
        eq(w, 30)
        eq(h, 40)

        graphics.set_clip_rect()
        local x2, y2, w2, h2 = graphics.get_clip_rect()
        eq(x2, 0)
        eq(y2, 0)
        eq(w2, 0)
        eq(h2, 0)
    end)

    test("graphics.draw_image/draw_image_region", "live image calls do not throw and nil misuse throws", function()
        graphics.draw_image(state.assets.image, 100, 100)
        graphics.draw_image(state.assets.image, 120, 100, rgba(255, 255, 255, 200))

        local iw, ih = graphics.get_image_size(state.assets.image)
        graphics.draw_image_region(state.assets.image, 0, 0, max(1, iw / 2), max(1, ih / 2), 140, 100)

        expect_throw(function() graphics.draw_image(nil, 0, 0) end)
        expect_throw(function() graphics.draw_image_region(nil, 0, 0, 1, 1, 0, 0) end)
    end)

    test("graphics.draw_image/draw_image_region", "drawing a freed image does not throw", function()
        local img, err = graphics.load_image(ASSET_IMG)
        ok(img, err)
        free(img)
        expect_nothrow(function() graphics.draw_image(img, 0, 0) end)
        expect_nothrow(function() graphics.draw_image_region(img, 0, 0, 1, 1, 0, 0) end)
    end)

    test("graphics transform API", "transform stack and coordinate conversion work", function()
        local sx, sy = graphics.local_to_screen(1, 2)
        eq(sx, 1)
        eq(sy, 2)

        local lx, ly = graphics.screen_to_local(3, 4)
        eq(lx, 3)
        eq(ly, 4)

        graphics.begin_transform()
        graphics.set_translation(10, 20)
        local a, b = graphics.local_to_screen(1, 2)
        eq(a, 11)
        eq(b, 22)
        graphics.end_transform()

        graphics.begin_transform()
        graphics.set_scale(2)
        local c1, c2 = graphics.local_to_screen(3, 4)
        eq(c1, 6)
        eq(c2, 8)
        graphics.end_transform()

        graphics.begin_transform()
        graphics.set_scale(2, 3)
        local d1, d2 = graphics.local_to_screen(3, 4)
        eq(d1, 6)
        eq(d2, 12)
        graphics.end_transform()

        graphics.begin_transform()
        graphics.set_rotation(math.pi * 0.5)
        local r1, r2 = graphics.local_to_screen(1, 0)
        near(r1, 0, 1e-4)
        near(r2, 1, 1e-4)
        graphics.end_transform()

        graphics.begin_transform()
        graphics.set_translation(10, 0)
        graphics.begin_transform()
        graphics.set_translation(5, 0)
        local n1, n2 = graphics.local_to_screen(1, 1)
        eq(n1, 16)
        eq(n2, 1)
        graphics.end_transform()
        local p1, p2 = graphics.local_to_screen(1, 1)
        eq(p1, 11)
        eq(p2, 1)
        graphics.end_transform()

        graphics.begin_transform()
        graphics.set_translation(100, 200)
        graphics.begin_transform()
        graphics.use_screen_space()
        local u1, u2 = graphics.local_to_screen(2, 3)
        eq(u1, 2)
        eq(u2, 3)
        graphics.end_transform()
        graphics.end_transform()
    end)

    test("graphics transform", "local_to_screen and screen_to_local are precise inverses", function()
        graphics.begin_transform()
        graphics.set_translation(123.4, 567.8)
        graphics.set_scale(2.5, 0.5)
        graphics.set_rotation(0.785398)

        local lx, ly = 42.0, -17.5
        local sx, sy = graphics.local_to_screen(lx, ly)
        local rx, ry = graphics.screen_to_local(sx, sy)
        near(rx, lx, 0.001)
        near(ry, ly, 0.001)

        graphics.end_transform()
    end)

    test("graphics.begin_transform/end_transform", "underflow and overflow throw", function()
        expect_throw(function() graphics.end_transform() end)
        for _ = 1, 31 do
            graphics.begin_transform()
        end
        expect_throw(function() graphics.begin_transform() end)
        for _ = 1, 31 do
            graphics.end_transform()
        end
    end)

    test("graphics.set_origin", "offsets local coordinates", function()
        graphics.begin_transform()
        graphics.set_translation(10, 20)
        graphics.set_origin(2, 3)
        local x, y = graphics.local_to_screen(2, 3)
        eq(x, 10)
        eq(y, 20)
        graphics.end_transform()
    end)

    test("graphics.set_canvas/draw_rect/draw_image", "canvas rect path and return-to-screen image path do not throw", function()
        local canvas = new_canvas_or_fail(16, 16)
        graphics.set_canvas(canvas)
        graphics.clear(rgba(0, 0, 0, 0))
        graphics.draw_rect(0, 0, 8, 8, rgba(255, 255, 255, 255))
        graphics.set_canvas(nil)
        graphics.draw_image(canvas, 180, 100)
        free(canvas)
    end)

    test("graphics.draw_text/draw_text_wrap", "startup and reset default-font paths do not throw", function()
        graphics.draw_text("default font startup", 20, 20)
        graphics.draw_text_wrap("default font startup wrap", 20, 50, 180)

        graphics.set_font(nil)
        graphics.draw_text("default font after nil", 20, 100)
        graphics.draw_text_wrap("default font wrap after nil", 20, 130, 180)

        graphics.set_font()
        graphics.draw_text("default font after no-arg", 20, 180)
        graphics.draw_text_wrap("default font wrap after no-arg", 20, 210, 180)
    end)

    test("graphics.draw_text/draw_text_wrap", "explicit font calls do not throw across valid forms", function()
        graphics.set_font(state.assets.font)

        graphics.draw_text("single line", 20, 20)
        graphics.draw_text("multi\nline", 20, 50, rgba(170, 255, 255, 255))

        local sample = "wrapped text should wrap across multiple lines and honor alignment"

        graphics.draw_text_wrap(sample, 20, 120, 180)
        graphics.draw_text_wrap(sample, 240, 120, 180, rgba(255, 204, 136, 255))
        graphics.draw_text_wrap(sample, 460, 120, 180, "center")
        graphics.draw_text_wrap(sample, 680, 120, 180, "right", rgba(136, 200, 255, 255))
    end)

    test("graphics.draw_text/draw_text_wrap", "drawing after freeing the active font does not throw", function()
        local font = new_font_or_fail(ASSET_FONT, 18)
        graphics.set_font(font)
        free(font)

        expect_nothrow(function() graphics.draw_text("dead font draw", 20, 260) end)
        expect_nothrow(function() graphics.draw_text_wrap("dead font wrap", 20, 290, 120) end)

        graphics.set_font(state.assets.font)
    end)

    test("graphics.draw_text", "text draw respects transform stack", function()
        graphics.set_font(state.assets.font)

        graphics.begin_transform()
        graphics.set_translation(100, 50)
        graphics.draw_text("transformed text", 0, 0, rgba(255, 255, 255, 255))
        graphics.end_transform()
    end)

    test("graphics.set_canvas/draw_text", "canvas text path and return-to-screen image path do not throw", function()
        graphics.set_font(state.assets.font)

        local canvas = new_canvas_or_fail(128, 64)
        graphics.set_canvas(canvas)
        graphics.clear(rgba(0, 0, 0, 0))
        graphics.draw_text("canvas text", 4, 4, rgba(255, 255, 255, 255))
        graphics.set_canvas(nil)

        graphics.draw_image(canvas, 20, 320)
        free(canvas)
    end)
end

local function finalize_and_exit()
    if state.finalized then
        return
    end
    state.finalized = true

    section("cleanup")

    test("filesystem cleanup", "sandbox cleanup leaves working directory restored", function()
        filesystem.set_working_directory(original_cwd)
        rm_tree(SUITE_ROOT)

        local cwd, err = filesystem.get_working_directory()
        ok(cwd, err)
        eq(cwd, original_cwd)

        local info = filesystem.get_path_info(SUITE_ROOT)
        eq(info, nil)
    end)

    test("window.close/window.should_close", "close flips should_close true", function()
        window.close()
        eq(window.should_close(), true)
    end)

    section("summary")
    print("")
    print(("total:   %d"):format(Runner.total))
    print(("passed:  %d"):format(Runner.passed))
    print(("failed:  %d"):format(Runner.failed))
    print(("skipped: %d"):format(0))

    if Runner.failed > 0 then
        print("")
        print("failed tests:")
        for i = 1, #Runner.failures do
            local f = Runner.failures[i]
            print(("  %s : %s [%s]"):format(f.api, f.desc, f.detail))
        end
    end
end

function runtime.init()
    window.set_title("Luagame Lua API Test Suite")
    run_globals_tests()
    run_filesystem_tests()
    run_graphics_asset_tests()
    run_graphics_text_tests()
    run_audio_tests_init()
end

function runtime.update(dt)
    if state.update_phase == 0 then
        run_window_tests()
        run_input_tests()
        run_audio_runtime_tests()
        run_audio_robustness_tests_step0()
        state.update_phase = 1
        state.update_timer = 0
        return
    end

    if state.update_phase == 1 then
        state.update_timer = state.update_timer + dt
        if state.update_timer >= 0.10 then
            run_audio_robustness_tests_step1()
            state.update_phase = 2
        end
        return
    end

    if state.update_phase == 2 and state.draw_done then
        finalize_and_exit()
        state.update_phase = 3
    end
end

function runtime.draw()
    if not state.draw_done then
        run_graphics_robustness_tests()
        run_graphics_draw_tests()
        state.draw_done = true
    end
end