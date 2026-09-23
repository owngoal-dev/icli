# Interaction: screen, ui, input, button, clipboard

Coordinates are UI points in the orientation shown on screen (see `icli screen info`). Every command here except `screen shot`, `screen info` and `button wake` exits with code 2 while the device is locked or its screen is off.

## screen

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `screen info` | Width, height, scale, orientation (degrees), `locked`, `screen_off` | | no | any |
| `screen tap <x> <y>` | Tap one point | | no | unlocked |
| `screen double-tap <x> <y>` | Two taps | `--interval 0.1` | no | unlocked |
| `screen long-press <x> <y>` | Press and hold | `--seconds 0.6` | no | unlocked |
| `screen swipe` | Straight swipe | `--from-x --from-y --to-x --to-y` (all required), `--seconds 0.25`, `--steps 20` | no | unlocked |
| `screen drag` | Press, hold, then move along a path | four endpoint options **or** `--points '<JSON [{x,y},…]>'`, `--hold 0.5`, `--seconds 0.3`, `--steps 20` | no | unlocked |
| `screen touch <down\|move\|up> <x> <y>` | One raw finger event; a gesture can span several calls | `--normalized` | no | unlocked |
| `screen touch-sequence` | Several finger events from one process, with exact timing | `--events '<JSON [{phase,x,y,delay_ms},…]>'` (required), `--normalized` | no | unlocked |
| `screen shot` | JPEG screenshot, upright | `--output <path>` (default: temporary file), `--base64`, `--native-resolution` | no | any |
| `screen ocr` | Vision text recognition of the current screen | `--lang <code>` (repeatable; default zh-Hans and en-US), `--min-confidence 0.3` | no | unlocked |
| `screen describe` | Screenshot (base64), OCR and accessibility elements from one call | | no | unlocked |

- `screen touch` and `touch-sequence` take UI points like `screen tap`. With `--normalized`, x and y are 0–1 in the fixed portrait digitizer space, which differs from the UI in landscape; `screen touch` reports the converted point as `digitizer_x`/`digitizer_y`. The touch state is kept by the system, so `touch down` in one call and `touch up` in a later call make one tap, drag or long press. Always finish with `up`. In `touch-sequence`, `delay_ms` (0–60000, default 0) is the pause after that event; `finger_down` in the result is true when the sequence did not end with `up`.
- `screen shot` has one image pixel per point by default. With `--native-resolution` the result includes `coordinate_scale`, which converts pixels to points.
- In `screen ocr`, `blocks` holds each recognized text with its confidence and point frame. On a device without text recognition the command fails with `unavailable`.
- `screen describe` returns `frontmost`, `screen`, `screenshot`, `ocr` and `elements`. Each component can carry its own `error`. If `context_changed` is true, the foreground app changed during the call, so do not combine its parts.

## ui (accessibility of the frontmost app)

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `ui tree` | Elements with `label`, `identifier`, `value`, `role`, `frame`, `clickable`, `visible` | `--max-elements 250` (1–2000), `--limit N`, `--include-offscreen`, `--clickable-only` | no | unlocked |
| `ui at <x> <y>` | Element at a point | | no | unlocked |
| `ui tap [<text>]` | Find an element and tap its centre | `--identifier <id>`, `--role <role>`, `--match contains\|exact`, `--index 0` | no | unlocked |
| `ui wait [<text>]` | Poll until the element appears | same selectors, `--timeout 10`, `--interval 0.3` | no | unlocked |
| `ui wait-gone [<text>]` | Poll until the element disappears | same as `ui wait` | no | unlocked |

Selectors: `<text>` matches an element's label, identifier or value. Matching ignores case and defaults to `contains`. `--identifier` matches an exact identifier or label and takes precedence over `<text>`. One of the two is required. `ui tap` fails with exit 1 when nothing matches.

## input (to the focused text field)

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `input paste <text>` | Send the whole string as Unicode key events. Does not touch the clipboard | | no | unlocked |
| `input type <text>` | Send one grapheme at a time | `--delay-ms 30` | no | unlocked |
| `input key <name>` | One key or chord | | no | unlocked |
| `input hid <page> <usage>` | Raw HID usage: press (down, 100 ms, up), or only one edge | `--down`, `--up` | no | unlocked |

`input hid` takes decimal or `0x` hex, both 1–0xFFFF. Page 7 is the keyboard (`7 4` is `a`, `7 0xE1` is left shift) and page 12 (`0x0C`) is consumer controls (`0x0C 0xE9` volume up, `0x0C 0xEA` volume down). A key sent with `--down` stays down across calls until the matching `--up`, so `input hid 7 0xE1 --down`, `input hid 7 5`, `input hid 7 0xE1 --up` types `B`.

Key names: `return`/`enter`, `delete`/`backspace`, `tab`, `escape`, `space`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, and the letters `a`–`z`. Modifiers are joined with `+`: `cmd`/`command`, `ctrl`/`control`, `shift`, `alt`/`option`. Examples: `cmd+a`, `cmd+v`, `shift+tab`.

## button

| Command | Purpose | Root | Screen |
| --- | --- | --- | --- |
| `button home` | Home button: go to the home screen | no | unlocked |
| `button power` | Side button: turns the screen off (locks) | no | unlocked |
| `button wake` | Turn the screen on; does not enter a passcode | no | any |
| `button volume-up` / `button volume-down` | Hardware volume event, with a fallback to the audio controller | no | unlocked |
| `button mute` | Toggle mute of the active audio category | no | unlocked |

After `button power`, only lock-exempt commands work until `button wake`. If the device has a passcode, a person has to unlock it.

## clipboard

| Command | Purpose | Root | Screen |
| --- | --- | --- | --- |
| `clipboard get` | Read the general pasteboard's text | no | unlocked |
| `clipboard set <text>` | Replace the pasteboard text | no | unlocked |
