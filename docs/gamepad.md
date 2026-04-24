# gamepad

The `gamepad` module provides controller queries, button input, stick and trigger input, and rumble effects.

Pads are 1-based. When `pad` is omitted or `nil`, pad `1` is used. New gamepads fill the first empty slot. Removed gamepads clear their slot; later slots do not shift.

Functions in this module error on wrong arity, wrong argument types, and invalid input. Disconnected pads behave like inactive input.

Stick values are returned in `-1..1`. Trigger values are returned in `0..1`.

## Button Tokens

Button tokens describe standard gamepad positions, not physical labels.

| Group | Tokens |
|---|---|
| Face Buttons | `"south"`, `"east"`, `"west"`, `"north"` |
| D-pad | `"up"`, `"down"`, `"left"`, `"right"` |
| Menu Buttons | `"back"`, `"guide"`, `"start"` |
| Stick Buttons | `"left_stick"`, `"right_stick"` |
| Shoulder Buttons | `"left_shoulder"`, `"right_shoulder"` |

Use `gamepad.get_button_label` to query the physical label printed on a face button.

## Functions

**Queries**
* [`get_count`](#get_count)
* [`is_connected`](#is_connected)
* [`get_name`](#get_name)
* [`get_type`](#get_type)
* [`get_button_label`](#get_button_label)

**Button Input**
* [`down`](#down)
* [`pressed`](#pressed)
* [`released`](#released)

**Stick and Trigger Input**
* [`stick`](#stick)
* [`trigger`](#trigger)

**Trigger Edge Input**
* [`trigger_down`](#trigger_down)
* [`trigger_pressed`](#trigger_pressed)
* [`trigger_released`](#trigger_released)

**Rumble**
* [`start_rumble`](#start_rumble)
* [`stop_rumble`](#stop_rumble)

## Queries

These functions return connected controller information.

### get_count

Returns the number of currently connected gamepads.

```lua
gamepad.get_count() -> count
```

#### Returns

- The number of connected gamepads.

---

### is_connected

Returns whether a pad slot is currently connected.

```lua
gamepad.is_connected(pad?) -> connected
```

#### Returns

- `true` if the pad slot is connected.
- `false` if the pad slot is not connected.

---

### get_name

Returns the gamepad name.

```lua
gamepad.get_name(pad?) -> name | nil
```

#### Returns

- The gamepad name.
- `nil` if the pad is not connected.
- `nil` if no name is available.

---

### get_type

Returns the gamepad type.

```lua
gamepad.get_type(pad?) -> type | nil
```

#### Returns

- The gamepad type string.
- `nil` if the pad is not connected.

---

### get_button_label

Returns the physical label printed on a button.

Button labels are controller-specific. For example, the `"south"` button may be labeled `"a"` on one controller and `"cross"` on another.

```lua
gamepad.get_button_label(button, pad?) -> label | nil
```

#### Returns

- `"a"`, `"b"`, `"x"`, or `"y"` for lettered button labels.
- `"cross"`, `"circle"`, `"square"`, or `"triangle"` for PlayStation-style button labels.
- `nil` if the pad is not connected.
- `nil` if no label is known for that button.

## Button Input

These functions check standard gamepad buttons.

### down

Returns whether a button is currently held.

```lua
gamepad.down(button, pad?) -> down
```

#### Returns

- `true` if the button is currently held.
- `false` otherwise.
- `false` if the pad is not connected.

---

### pressed

Returns whether a button was pressed during the current frame.

```lua
gamepad.pressed(button, pad?) -> pressed
```

#### Returns

- `true` if the button was pressed during the current frame.
- `false` otherwise.
- `false` if the pad is not connected.

---

### released

Returns whether a button was released during the current frame.

```lua
gamepad.released(button, pad?) -> released
```

#### Returns

- `true` if the button was released during the current frame.
- `false` otherwise.
- `false` if the pad is not connected.

## Stick and Trigger Input

These functions return current stick and trigger values.

`side` must be `"left"` or `"right"`.

### stick

Returns the current stick position.

```lua
gamepad.stick(side, pad?) -> x, y
```

#### Returns

- `x, y`, each in `-1..1`.
- `0, 0` if the pad is not connected.

---

### trigger

Returns the current trigger value.

```lua
gamepad.trigger(side, pad?) -> value
```

#### Returns

- The trigger value in `0..1`.
- `0` if the pad is not connected.

## Trigger Edge Input

These functions check whether triggers pass the set threshold during the current frame.

`side` must be `"left"` or `"right"`.

When `threshold` is omitted, the default trigger threshold is used.

### trigger_down

Returns whether a trigger is currently held past the set threshold.

```lua
gamepad.trigger_down(side, threshold?, pad?) -> down
```

#### Returns

- `true` if the trigger is at or above `threshold`.
- `false` otherwise.
- `false` if the pad is not connected.

---

### trigger_pressed

Returns whether a trigger passed above the set threshold during the current frame.

```lua
gamepad.trigger_pressed(side, threshold?, pad?) -> pressed
```

#### Returns

- `true` if the trigger passed above `threshold` during the current frame.
- `false` otherwise.
- `false` if the pad is not connected.

---

### trigger_released

Returns whether a trigger passed below the set threshold during the current frame.

```lua
gamepad.trigger_released(side, threshold?, pad?) -> released
```

#### Returns

- `true` if the trigger passed below `threshold` during the current frame.
- `false` otherwise.
- `false` if the pad is not connected.

## Rumble

Rumble support depends on the controller and backend. If rumble cannot be played, these functions no-op.

Rumble strength values are in `0..1`. `0` means no rumble and `1` means full rumble.

`duration` is in seconds and must be non-negative.

### start_rumble

Starts rumble on a pad.

`low` controls the low-frequency rumble motor. `high` controls the high-frequency rumble motor.

```lua
gamepad.start_rumble(low, high, duration, pad?)
```

---

### stop_rumble

Stops rumble on a pad.

```lua
gamepad.stop_rumble(pad?)
```