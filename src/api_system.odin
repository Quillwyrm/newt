package main

import "core:c"
import lua "luajit"
import sdl "vendor:sdl3"

// ============================================================================
// Lua System Bindings
// ============================================================================

MAX_MESSAGE_BOX_BUTTONS :: 8
MAX_FILE_DIALOG_SELECTIONS :: 256
MAX_FILE_DIALOG_FILTERS :: 16
MAX_FILE_DIALOG_ERROR_TEXT_BYTES :: 1024

System_State: struct {
	file_dialog_sem: ^sdl.Semaphore,

	file_dialog_error: bool,
	file_dialog_error_text: [MAX_FILE_DIALOG_ERROR_TEXT_BYTES]u8,

	file_dialog_path_count: int,
	file_dialog_paths: [MAX_FILE_DIALOG_SELECTIONS]cstring,
}

// == Shell ==

// system.open_url(url) -> true | nil, err
lua_system_open_url :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) != 1 {
		lua.L_error(L, "system.open_url: expected 1 argument: url")
		return 0
	}

	url := lua_check_cstring(L, 1, "system.open_url", "url")

	if !sdl.OpenURL(cast(cstring)(url)) {
		lua.pushnil(L)
		lua.pushfstring(L, "system.open_url: failed to open URL: %s", sdl.GetError())
		return 2
	}

	lua.pushboolean(L, true)
	return 1
}

// == Message Boxes ==

read_message_box_flags :: proc "contextless" (L: ^lua.State, options_idx: lua.Index, fn_name: cstring) -> sdl.MessageBoxFlags {
	flags: sdl.MessageBoxFlags

	if bool(lua.isnoneornil(L, options_idx)) {
		return flags
	}

	lua.L_checktype(L, cast(c.int)(options_idx), lua.Type.TABLE)

	lua.getfield(L, options_idx, "type")
	if !bool(lua.isnoneornil(L, -1)) {
		p := lua_check_cstring(L, -1, fn_name, "type")
		box_type := string(p)

		if box_type == "info" {
			flags += {.INFORMATION}
		} else if box_type == "warning" {
			flags += {.WARNING}
		} else if box_type == "error" {
			flags += {.ERROR}
		} else {
			lua.L_error(L, "%s: unknown message box type '%s'", fn_name, p)
		}
	}
	lua.pop(L, 1)

	return flags
}

// system.show_message_box(title, message, options?) -> true | nil, err
lua_system_show_message_box :: proc "c" (L: ^lua.State) -> c.int {
	argc := lua.gettop(L)
	if argc < 2 || argc > 3 {
		lua.L_error(L, "system.show_message_box: expected 2 or 3 arguments: title, message, options")
		return 0
	}

	title := lua_check_cstring(L, 1, "system.show_message_box", "title")
	message := lua_check_cstring(L, 2, "system.show_message_box", "message")
	flags := read_message_box_flags(L, 3, "system.show_message_box")

	if !sdl.ShowSimpleMessageBox(flags, title, message, Window) {
		lua.pushnil(L)
		lua.pushfstring(L, "system.show_message_box: failed to show message box: %s", sdl.GetError())
		return 2
	}

	lua.pushboolean(L, true)
	return 1
}

// system.show_choice_box(title, message, buttons, options?) -> button_index | nil, err
lua_system_show_choice_box :: proc "c" (L: ^lua.State) -> c.int {
	argc := lua.gettop(L)
	if argc < 3 || argc > 4 {
		lua.L_error(L, "system.show_choice_box: expected 3 or 4 arguments: title, message, buttons, options")
		return 0
	}

	title := lua_check_cstring(L, 1, "system.show_choice_box", "title")
	message := lua_check_cstring(L, 2, "system.show_choice_box", "message")

	lua.L_checktype(L, 3, lua.Type.TABLE)
	button_count := int(lua.objlen(L, 3))
	if button_count <= 0 {
		lua.L_error(L, "system.show_choice_box: buttons must not be empty")
		return 0
	}
	if button_count > MAX_MESSAGE_BOX_BUTTONS {
		lua.L_error(L, "system.show_choice_box: too many buttons; max is %d", MAX_MESSAGE_BOX_BUTTONS)
		return 0
	}

	flags := read_message_box_flags(L, 4, "system.show_choice_box")

	default_button := 0
	escape_button := 0
	if !bool(lua.isnoneornil(L, 4)) {
		lua.getfield(L, 4, "default")
		if !bool(lua.isnoneornil(L, -1)) {
			default_button = int(lua.L_checkinteger(L, -1))
			if default_button < 1 || default_button > button_count {
				lua.L_error(L, "system.show_choice_box: default button index out of range")
				return 0
			}
		}
		lua.pop(L, 1)

		lua.getfield(L, 4, "escape")
		if !bool(lua.isnoneornil(L, -1)) {
			escape_button = int(lua.L_checkinteger(L, -1))
			if escape_button < 1 || escape_button > button_count {
				lua.L_error(L, "system.show_choice_box: escape button index out of range")
				return 0
			}
		}
		lua.pop(L, 1)
	}

	buttons: [MAX_MESSAGE_BOX_BUTTONS]sdl.MessageBoxButtonData
	for i in 0..<button_count {
		lua.rawgeti(L, 3, lua.Integer(i + 1))
		button_text := lua_check_cstring(L, -1, "system.show_choice_box", "button text")

		button_flags: sdl.MessageBoxButtonFlags
		if i + 1 == default_button {
			button_flags += {.RETURNKEY_DEFAULT}
		}
		if i + 1 == escape_button {
			button_flags += {.ESCAPEKEY_DEFAULT}
		}

		buttons[i] = sdl.MessageBoxButtonData {
			flags = button_flags,
			buttonID = c.int(i + 1),
			text = button_text,
		}

		lua.pop(L, 1)
	}

	data := sdl.MessageBoxData {
		flags = flags,
		window = Window,
		title = title,
		message = message,
		numbuttons = c.int(button_count),
		buttons = raw_data(buttons[:]),
		colorScheme = nil,
	}

	button_id: c.int
	if !sdl.ShowMessageBox(data, &button_id) {
		lua.pushnil(L)
		lua.pushfstring(L, "system.show_choice_box: failed to show choice box: %s", sdl.GetError())
		return 2
	}

	lua.pushinteger(L, lua.Integer(button_id))
	return 1
}

// == File Dialogs ==

set_file_dialog_error :: proc "contextless" (msg: cstring) {
	System_State.file_dialog_error = true
	System_State.file_dialog_error_text[0] = 0
	if msg != nil {
		_ = sdl.strlcpy(raw_data(System_State.file_dialog_error_text[:]), msg, uint(len(System_State.file_dialog_error_text)))
	}
}

clear_file_dialog_result :: proc "contextless" () {
	free_file_dialog_paths()

	System_State.file_dialog_error = false
	System_State.file_dialog_error_text[0] = 0
}

free_file_dialog_paths :: proc "contextless" () {
	for i in 0..<System_State.file_dialog_path_count {
		if System_State.file_dialog_paths[i] != nil {
			sdl.free(rawptr(System_State.file_dialog_paths[i]))
			System_State.file_dialog_paths[i] = nil
		}
	}
	System_State.file_dialog_path_count = 0
}

destroy_file_dialog_semaphore :: proc "contextless" () {
	if System_State.file_dialog_sem != nil {
		sdl.DestroySemaphore(System_State.file_dialog_sem)
		System_State.file_dialog_sem = nil
	}
}

fail_file_dialog_setup :: proc "contextless" (L: ^lua.State, props: sdl.PropertiesID, fn_name, action: cstring) -> c.int {
	err := sdl.GetError()

	if props != sdl.PropertiesID(0) {
		sdl.DestroyProperties(props)
	}
	destroy_file_dialog_semaphore()

	lua.pushnil(L)
	lua.pushfstring(L, "%s: %s: %s", fn_name, action, err)
	return 2
}

file_dialog_callback :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	if filelist == nil {
		set_file_dialog_error(sdl.GetError())
		sdl.SignalSemaphore(System_State.file_dialog_sem)
		return
	}

	for filelist[System_State.file_dialog_path_count] != nil {
		if System_State.file_dialog_path_count == MAX_FILE_DIALOG_SELECTIONS {
			set_file_dialog_error("too many selected paths")
			break
		}

		i := System_State.file_dialog_path_count
		path := sdl.strdup(filelist[i])
		if path == nil {
			set_file_dialog_error("failed to copy selected path")
			break
		}

		System_State.file_dialog_paths[i] = cstring(path)
		System_State.file_dialog_path_count += 1
	}

	sdl.SignalSemaphore(System_State.file_dialog_sem)
}

read_file_dialog_filters :: proc "contextless" (
	L: ^lua.State,
	options_idx: lua.Index,
	fn_name: cstring,
	filters: ^[MAX_FILE_DIALOG_FILTERS]sdl.DialogFileFilter,
) -> int {
	filter_count := 0

	lua.getfield(L, options_idx, "filters")
	if !bool(lua.isnoneornil(L, -1)) {
		lua.L_checktype(L, -1, lua.Type.TABLE)

		filter_count = int(lua.objlen(L, -1))
		if filter_count > MAX_FILE_DIALOG_FILTERS {
			lua.L_error(L, "%s: too many filters; max is %d", fn_name, MAX_FILE_DIALOG_FILTERS)
			return 0
		}

		for i in 0..<filter_count {
			lua.rawgeti(L, -1, lua.Integer(i + 1))
			lua.L_checktype(L, -1, lua.Type.TABLE)

			lua.getfield(L, -1, "name")
			name := lua_check_cstring(L, -1, fn_name, "filter name")
			lua.pop(L, 1)

			lua.getfield(L, -1, "pattern")
			pattern := lua_check_cstring(L, -1, fn_name, "filter pattern")
			lua.pop(L, 1)

			filters[i] = sdl.DialogFileFilter {
				name = name,
				pattern = pattern,
			}

			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1)

	return filter_count
}

push_file_dialog_result :: proc "contextless" (L: ^lua.State, fn_name: cstring, multiple: bool) -> c.int {
	if System_State.file_dialog_error {
		free_file_dialog_paths()
		lua.pushnil(L)
		lua.pushfstring(L, "%s: %s", fn_name, cstring(raw_data(System_State.file_dialog_error_text[:])))
		return 2
	}

	if System_State.file_dialog_path_count == 0 {
		lua.pushnil(L)
		return 1
	}

	if multiple {
		lua.createtable(L, c.int(System_State.file_dialog_path_count), 0)
		for i in 0..<System_State.file_dialog_path_count {
			lua.pushstring(L, System_State.file_dialog_paths[i])
			lua.rawseti(L, -2, c.int(i + 1))
		}
		free_file_dialog_paths()
		return 1
	}

	lua.pushstring(L, System_State.file_dialog_paths[0])
	free_file_dialog_paths()
	return 1
}

// system.open_file_dialog(options?) -> path | paths | nil, err
lua_system_open_file_dialog :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) > 1 {
		lua.L_error(L, "system.open_file_dialog: expected 0 or 1 argument: options")
		return 0
	}

	title: cstring
	location: cstring
	accept: cstring
	cancel: cstring
	multiple := false
	filters: [MAX_FILE_DIALOG_FILTERS]sdl.DialogFileFilter
	filter_count := 0

	if !bool(lua.isnoneornil(L, 1)) {
		lua.L_checktype(L, 1, lua.Type.TABLE)

		lua.getfield(L, 1, "title")
		if !bool(lua.isnoneornil(L, -1)) {
			title = lua_check_cstring(L, -1, "system.open_file_dialog", "title")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "location")
		if !bool(lua.isnoneornil(L, -1)) {
			location = lua_check_cstring(L, -1, "system.open_file_dialog", "location")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "accept")
		if !bool(lua.isnoneornil(L, -1)) {
			accept = lua_check_cstring(L, -1, "system.open_file_dialog", "accept")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "cancel")
		if !bool(lua.isnoneornil(L, -1)) {
			cancel = lua_check_cstring(L, -1, "system.open_file_dialog", "cancel")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "multiple")
		if !bool(lua.isnoneornil(L, -1)) {
			lua.L_checktype(L, -1, lua.Type.BOOLEAN)
			multiple = bool(lua.toboolean(L, -1))
		}
		lua.pop(L, 1)

		filter_count = read_file_dialog_filters(L, 1, "system.open_file_dialog", &filters)
	}

	clear_file_dialog_result()

	System_State.file_dialog_sem = sdl.CreateSemaphore(0)
	if System_State.file_dialog_sem == nil {
		lua.pushnil(L)
		lua.pushfstring(L, "system.open_file_dialog: failed to create semaphore: %s", sdl.GetError())
		return 2
	}

	props := sdl.CreateProperties()
	if props == sdl.PropertiesID(0) {
		return fail_file_dialog_setup(L, props, "system.open_file_dialog", "failed to create dialog properties")
	}

	if Window != nil && !sdl.SetPointerProperty(props, sdl.PROP_FILE_DIALOG_WINDOW_POINTER, rawptr(Window)) {
		return fail_file_dialog_setup(L, props, "system.open_file_dialog", "failed to set dialog window")
	}

	if title != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_TITLE_STRING, title) {
		return fail_file_dialog_setup(L, props, "system.open_file_dialog", "failed to set dialog title")
	}

	if location != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_LOCATION_STRING, location) {
		return fail_file_dialog_setup(L, props, "system.open_file_dialog", "failed to set dialog location")
	}

	if accept != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_ACCEPT_STRING, accept) {
		return fail_file_dialog_setup(L, props, "system.open_file_dialog", "failed to set dialog accept label")
	}

	if cancel != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_CANCEL_STRING, cancel) {
		return fail_file_dialog_setup(L, props, "system.open_file_dialog", "failed to set dialog cancel label")
	}

	if multiple && !sdl.SetBooleanProperty(props, sdl.PROP_FILE_DIALOG_MANY_BOOLEAN, true) {
		return fail_file_dialog_setup(L, props, "system.open_file_dialog", "failed to set multi-select option")
	}

	if filter_count > 0 {
		if !sdl.SetPointerProperty(props, sdl.PROP_FILE_DIALOG_FILTERS_POINTER, raw_data(filters[:])) {
			return fail_file_dialog_setup(L, props, "system.open_file_dialog", "failed to set dialog filters")
		}

		if !sdl.SetNumberProperty(props, sdl.PROP_FILE_DIALOG_NFILTERS_NUMBER, sdl.Sint64(filter_count)) {
			return fail_file_dialog_setup(L, props, "system.open_file_dialog", "failed to set dialog filter count")
		}
	}

	sdl.ShowFileDialogWithProperties(.OPENFILE, file_dialog_callback, nil, props)

	for !sdl.TryWaitSemaphore(System_State.file_dialog_sem) {
		sdl.PumpEvents()
		sdl.Delay(10)
	}

	sdl.DestroyProperties(props)
	destroy_file_dialog_semaphore()

	return push_file_dialog_result(L, "system.open_file_dialog", multiple)
}

// system.save_file_dialog(options?) -> path | nil, err
lua_system_save_file_dialog :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) > 1 {
		lua.L_error(L, "system.save_file_dialog: expected 0 or 1 argument: options")
		return 0
	}

	title: cstring
	location: cstring
	accept: cstring
	cancel: cstring
	filters: [MAX_FILE_DIALOG_FILTERS]sdl.DialogFileFilter
	filter_count := 0

	if !bool(lua.isnoneornil(L, 1)) {
		lua.L_checktype(L, 1, lua.Type.TABLE)

		lua.getfield(L, 1, "title")
		if !bool(lua.isnoneornil(L, -1)) {
			title = lua_check_cstring(L, -1, "system.save_file_dialog", "title")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "location")
		if !bool(lua.isnoneornil(L, -1)) {
			location = lua_check_cstring(L, -1, "system.save_file_dialog", "location")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "accept")
		if !bool(lua.isnoneornil(L, -1)) {
			accept = lua_check_cstring(L, -1, "system.save_file_dialog", "accept")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "cancel")
		if !bool(lua.isnoneornil(L, -1)) {
			cancel = lua_check_cstring(L, -1, "system.save_file_dialog", "cancel")
		}
		lua.pop(L, 1)

		filter_count = read_file_dialog_filters(L, 1, "system.save_file_dialog", &filters)
	}

	clear_file_dialog_result()

	System_State.file_dialog_sem = sdl.CreateSemaphore(0)
	if System_State.file_dialog_sem == nil {
		lua.pushnil(L)
		lua.pushfstring(L, "system.save_file_dialog: failed to create semaphore: %s", sdl.GetError())
		return 2
	}

	props := sdl.CreateProperties()
	if props == sdl.PropertiesID(0) {
		return fail_file_dialog_setup(L, props, "system.save_file_dialog", "failed to create dialog properties")
	}

	if Window != nil && !sdl.SetPointerProperty(props, sdl.PROP_FILE_DIALOG_WINDOW_POINTER, rawptr(Window)) {
		return fail_file_dialog_setup(L, props, "system.save_file_dialog", "failed to set dialog window")
	}

	if title != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_TITLE_STRING, title) {
		return fail_file_dialog_setup(L, props, "system.save_file_dialog", "failed to set dialog title")
	}

	if location != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_LOCATION_STRING, location) {
		return fail_file_dialog_setup(L, props, "system.save_file_dialog", "failed to set dialog location")
	}

	if accept != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_ACCEPT_STRING, accept) {
		return fail_file_dialog_setup(L, props, "system.save_file_dialog", "failed to set dialog accept label")
	}

	if cancel != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_CANCEL_STRING, cancel) {
		return fail_file_dialog_setup(L, props, "system.save_file_dialog", "failed to set dialog cancel label")
	}

	if filter_count > 0 {
		if !sdl.SetPointerProperty(props, sdl.PROP_FILE_DIALOG_FILTERS_POINTER, raw_data(filters[:])) {
			return fail_file_dialog_setup(L, props, "system.save_file_dialog", "failed to set dialog filters")
		}

		if !sdl.SetNumberProperty(props, sdl.PROP_FILE_DIALOG_NFILTERS_NUMBER, sdl.Sint64(filter_count)) {
			return fail_file_dialog_setup(L, props, "system.save_file_dialog", "failed to set dialog filter count")
		}
	}

	sdl.ShowFileDialogWithProperties(.SAVEFILE, file_dialog_callback, nil, props)

	for !sdl.TryWaitSemaphore(System_State.file_dialog_sem) {
		sdl.PumpEvents()
		sdl.Delay(10)
	}

	sdl.DestroyProperties(props)
	destroy_file_dialog_semaphore()

	return push_file_dialog_result(L, "system.save_file_dialog", false)
}

// system.open_folder_dialog(options?) -> path | paths | nil, err
lua_system_open_folder_dialog :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) > 1 {
		lua.L_error(L, "system.open_folder_dialog: expected 0 or 1 argument: options")
		return 0
	}

	title: cstring
	location: cstring
	accept: cstring
	cancel: cstring
	multiple := false

	if !bool(lua.isnoneornil(L, 1)) {
		lua.L_checktype(L, 1, lua.Type.TABLE)

		lua.getfield(L, 1, "title")
		if !bool(lua.isnoneornil(L, -1)) {
			title = lua_check_cstring(L, -1, "system.open_folder_dialog", "title")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "location")
		if !bool(lua.isnoneornil(L, -1)) {
			location = lua_check_cstring(L, -1, "system.open_folder_dialog", "location")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "accept")
		if !bool(lua.isnoneornil(L, -1)) {
			accept = lua_check_cstring(L, -1, "system.open_folder_dialog", "accept")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "cancel")
		if !bool(lua.isnoneornil(L, -1)) {
			cancel = lua_check_cstring(L, -1, "system.open_folder_dialog", "cancel")
		}
		lua.pop(L, 1)

		lua.getfield(L, 1, "multiple")
		if !bool(lua.isnoneornil(L, -1)) {
			lua.L_checktype(L, -1, lua.Type.BOOLEAN)
			multiple = bool(lua.toboolean(L, -1))
		}
		lua.pop(L, 1)
	}

	clear_file_dialog_result()

	System_State.file_dialog_sem = sdl.CreateSemaphore(0)
	if System_State.file_dialog_sem == nil {
		lua.pushnil(L)
		lua.pushfstring(L, "system.open_folder_dialog: failed to create semaphore: %s", sdl.GetError())
		return 2
	}

	props := sdl.CreateProperties()
	if props == sdl.PropertiesID(0) {
		return fail_file_dialog_setup(L, props, "system.open_folder_dialog", "failed to create dialog properties")
	}

	if Window != nil && !sdl.SetPointerProperty(props, sdl.PROP_FILE_DIALOG_WINDOW_POINTER, rawptr(Window)) {
		return fail_file_dialog_setup(L, props, "system.open_folder_dialog", "failed to set dialog window")
	}

	if title != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_TITLE_STRING, title) {
		return fail_file_dialog_setup(L, props, "system.open_folder_dialog", "failed to set dialog title")
	}

	if location != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_LOCATION_STRING, location) {
		return fail_file_dialog_setup(L, props, "system.open_folder_dialog", "failed to set dialog location")
	}

	if accept != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_ACCEPT_STRING, accept) {
		return fail_file_dialog_setup(L, props, "system.open_folder_dialog", "failed to set dialog accept label")
	}

	if cancel != nil && !sdl.SetStringProperty(props, sdl.PROP_FILE_DIALOG_CANCEL_STRING, cancel) {
		return fail_file_dialog_setup(L, props, "system.open_folder_dialog", "failed to set dialog cancel label")
	}

	if multiple && !sdl.SetBooleanProperty(props, sdl.PROP_FILE_DIALOG_MANY_BOOLEAN, true) {
		return fail_file_dialog_setup(L, props, "system.open_folder_dialog", "failed to set multi-select option")
	}

	sdl.ShowFileDialogWithProperties(.OPENFOLDER, file_dialog_callback, nil, props)

	for !sdl.TryWaitSemaphore(System_State.file_dialog_sem) {
		sdl.PumpEvents()
		sdl.Delay(10)
	}

	sdl.DestroyProperties(props)
	destroy_file_dialog_semaphore()

	return push_file_dialog_result(L, "system.open_folder_dialog", multiple)
}

// == Clipboard ==

// system.has_clipboard_text() -> bool
lua_system_has_clipboard_text :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) != 0 {
		lua.L_error(L, "system.has_clipboard_text: expected 0 arguments")
		return 0
	}

	lua.pushboolean(L, cast(b32)sdl.HasClipboardText())
	return 1
}

// system.get_clipboard_text() -> string
// Must free the SDL buffer via sdl.free (SDL_free).
lua_system_get_clipboard_text :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) != 0 {
		lua.L_error(L, "system.get_clipboard_text: expected 0 arguments")
		return 0
	}

	p := sdl.GetClipboardText()
	if p == nil {
		lua.L_error(L, "system.get_clipboard_text: failed to get clipboard text: %s", sdl.GetError())
		return 0
	}

	// Lua copies the C string into its own string object.
	lua.pushstring(L, cast(cstring)(p))

	// SDL owns this allocation.
	sdl.free(cast(rawptr)(p))

	return 1
}

// system.set_clipboard_text(text)
lua_system_set_clipboard_text :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) != 1 {
		lua.L_error(L, "system.set_clipboard_text: expected 1 argument: text")
		return 0
	}

	p := lua_check_cstring(L, 1, "system.set_clipboard_text", "text")

	if !sdl.SetClipboardText(cast(cstring)(p)) {
		lua.L_error(L, "system.set_clipboard_text: failed to set clipboard text: %s", sdl.GetError())
		return 0
	}

	return 0
}

// == System Info ==

// system.get_os() -> os_name
lua_system_get_os :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) != 0 {
		lua.L_error(L, "system.get_os: expected 0 arguments")
		return 0
	}

	os_name := ODIN_OS_STRING
	lua.pushlstring(L, cstring(raw_data(os_name)), c.size_t(len(os_name)))
	return 1
}

// system.get_arch() -> arch_name
lua_system_get_arch :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) != 0 {
		lua.L_error(L, "system.get_arch: expected 0 arguments")
		return 0
	}

	arch := ODIN_ARCH_STRING
	lua.pushlstring(L, cstring(raw_data(arch)), c.size_t(len(arch)))
	return 1
}

// system.get_cores() -> count
lua_system_get_cores :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) != 0 {
		lua.L_error(L, "system.get_cores: expected 0 arguments")
		return 0
	}

	lua.pushinteger(L, lua.Integer(sdl.GetNumLogicalCPUCores()))
	return 1
}

// system.get_ram_mb() -> megabytes
lua_system_get_ram_mb :: proc "c" (L: ^lua.State) -> c.int {
	if lua.gettop(L) != 0 {
		lua.L_error(L, "system.get_ram_mb: expected 0 arguments")
		return 0
	}

	lua.pushinteger(L, lua.Integer(sdl.GetSystemRAM()))
	return 1
}

// == Lua Registration ==

register_system_api :: proc() {
	lua.newtable(Lua)

	// Shell
	lua_bind_function(lua_system_open_url, "open_url")

	// Message Boxes
	lua_bind_function(lua_system_show_message_box, "show_message_box")
	lua_bind_function(lua_system_show_choice_box, "show_choice_box")

	// File Dialogs
	lua_bind_function(lua_system_open_file_dialog, "open_file_dialog")
	lua_bind_function(lua_system_save_file_dialog, "save_file_dialog")
	lua_bind_function(lua_system_open_folder_dialog, "open_folder_dialog")

	// Clipboard
	lua_bind_function(lua_system_has_clipboard_text, "has_clipboard_text")
	lua_bind_function(lua_system_get_clipboard_text, "get_clipboard_text")
	lua_bind_function(lua_system_set_clipboard_text, "set_clipboard_text")

	// System Info
	lua_bind_function(lua_system_get_os, "get_os")
	lua_bind_function(lua_system_get_arch, "get_arch")
	lua_bind_function(lua_system_get_cores, "get_cores")
	lua_bind_function(lua_system_get_ram_mb, "get_ram_mb")

	lua.setglobal(Lua, "system")
}
