# system

The `system` module provides access to host operating system features such as external links, native dialogs, clipboard, and system information.
Unless noted otherwise, functions in this module throw on wrong arity or wrong argument types.

## Functions

**External Links**
* [`open_url`](#open_url)

**Native Dialogs**
* [`show_message_box`](#show_message_box)
* [`show_choice_box`](#show_choice_box)
* [`open_file_dialog`](#open_file_dialog)
* [`save_file_dialog`](#save_file_dialog)
* [`open_folder_dialog`](#open_folder_dialog)

**Clipboard**
* [`has_clipboard_text`](#has_clipboard_text)
* [`get_clipboard_text`](#get_clipboard_text)
* [`set_clipboard_text`](#set_clipboard_text)

**System Info**
* [`get_os`](#get_os)
* [`get_arch`](#get_arch)
* [`get_cores`](#get_cores)
* [`get_ram_mb`](#get_ram_mb)

## External Links

### open_url

Opens a URL with the operating system's default handler.

```lua
system.open_url(url) -> true | nil, err
```

#### Error Cases

- Returns `nil, err` if the operating system fails to open the URL.

## Native Dialogs

Message box `options` may include:

- `type`: `"info"`, `"warning"`, or `"error"`.

### show_message_box

Shows a simple native message box.

```lua
system.show_message_box(title, message, options?) -> true | nil, err
```

#### Error Cases

- Returns `nil, err` if the message box could not be shown.
- Throws if `options.type` is not `"info"`, `"warning"`, or `"error"`.

---

### show_choice_box

Shows a native message box with custom buttons.

```lua
system.show_choice_box(title, message, buttons, options?) -> button_index | nil, err
```

#### Arguments

`buttons` is an array of button text.

Additional `options` fields:

- `default`: 1-based button index activated by Enter.
- `escape`: 1-based button index activated by Escape.

#### Returns

`button_index` is the 1-based index of the selected button.

#### Error Cases

- Returns `nil, err` if the choice box could not be shown.
- Throws if `buttons` is empty.
- Throws if `buttons` has more than 8 entries.
- Throws if `options.type` is not `"info"`, `"warning"`, or `"error"`.
- Throws if `options.default` or `options.escape` is outside the button range.

Native file dialogs block until the user chooses a path, cancels, or the operating system reports an error.

Common `options` fields:

- `title`: Dialog title.
- `location`: Initial folder or file path.
- `accept`: Accept button label.
- `cancel`: Cancel button label.

File dialogs that support filters use:

- `filters`: Array of `{ name = "...", pattern = "..." }` entries.

Filter patterns are semicolon-separated extensions, such as `"png;jpg;jpeg"`, or `"*"` for all files.
Newt accepts up to 16 filters and up to 256 selected paths.

### open_file_dialog

Shows a native open-file dialog.

```lua
system.open_file_dialog(options?) -> path | paths | nil, err
```

Additional `options` fields:

- `multiple`: If true, allows selecting more than one file.

#### Returns

Returns a path string on success. If `multiple` is true, returns an array of path strings.
Returns `nil` when canceled.

#### Error Cases

- Returns `nil, err` if the dialog fails.
- Returns `nil, err` if more than 256 paths are selected.
- Throws if `options.filters` has more than 16 entries.

---

### save_file_dialog

Shows a native save-file dialog.

```lua
system.save_file_dialog(options?) -> path | nil, err
```

#### Returns

Returns a path string on success.
Returns `nil` when canceled.

#### Error Cases

- Returns `nil, err` if the dialog fails.
- Throws if `options.filters` has more than 16 entries.

---

### open_folder_dialog

Shows a native open-folder dialog.

```lua
system.open_folder_dialog(options?) -> path | paths | nil, err
```

Additional `options` fields:

- `multiple`: If true, allows selecting more than one folder.

#### Returns

Returns a path string on success. If `multiple` is true, returns an array of path strings.
Returns `nil` when canceled.

#### Error Cases

- Returns `nil, err` if the dialog fails.
- Returns `nil, err` if more than 256 paths are selected.

## Clipboard

### has_clipboard_text

Returns whether text is currently available on the clipboard.

```lua
system.has_clipboard_text() -> bool
```

---

### get_clipboard_text

Returns the current clipboard text.

```lua
system.get_clipboard_text() -> text
```

#### Error Cases

- Throws if the operating system fails to read clipboard text.

---

### set_clipboard_text

Sets the clipboard text.

```lua
system.set_clipboard_text(text)
```

#### Error Cases

- Throws if the operating system fails to set clipboard text.

## System Info

### get_os

Returns the target operating system name.

```lua
system.get_os() -> os_name
```

---

### get_arch

Returns the target CPU architecture name.

```lua
system.get_arch() -> arch_name
```

---

### get_cores

Returns the number of logical CPU cores.

```lua
system.get_cores() -> count
```

---

### get_ram_mb

Returns the amount of system RAM in megabytes.

```lua
system.get_ram_mb() -> megabytes
```
