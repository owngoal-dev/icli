# Interaction and Screen Capture

Run these commands on the device or in its SSH session. Unlock the device and keep the screen on before interacting with an app.

## Inspect and Interact

Read the foreground app's accessibility tree, then use its text or identifiers in your commands. Replace the sample identifiers and text below with elements in your app:

```sh
icli app frontmost
icli app running
icli ui tree
icli ui tap --identifier counter.increment
icli ui wait 'Ready element' --timeout 5
icli ui wait-gone 'Loading' --timeout 10
```

`app frontmost` marks a bundle ID `verified: true` only when RunningBoard has one non-widget focal app. A SpringBoard-query fallback is marked `verified: false`; UI commands stop if they cannot verify the target. `app running` reports its `source` as `runningboard` or `processes`.

For coordinate input, read the screen dimensions first. Coordinates are **points** in the orientation shown on screen, including those returned by accessibility and OCR. On an iPad held in landscape, `screen info` reports a landscape width and height:

```sh
icli screen info
icli screen tap 100 245
icli screen swipe --from-x 200 --from-y 600 --to-x 200 --to-y 200
icli screen drag --points '[{"x":54,"y":500},{"x":140,"y":480},{"x":240,"y":500}]'
```

Focus a text field before entering text:

```sh
icli input paste '中文 and emoji 🌱'
icli input key cmd+a
icli input type 'Hello!' --delay-ms 30
```

For input that needs exact control, send one event at a time. A finger that goes down stays down until an `up`, even across separate icli runs. `--normalized` takes 0…1 coordinates in the digitizer's fixed portrait space instead of points. `input hid` sends a raw HID usage: page 7 is the keyboard page, 12 the consumer page.

```sh
icli screen touch down 100 245
icli screen touch move 160 245
icli screen touch up 160 245
icli screen touch-sequence --events '[{"phase":"down","x":100,"y":245,"delay_ms":800},{"phase":"up","x":100,"y":245}]'
icli input hid 7 0xE1 --down
icli input hid 7 4
icli input hid 7 0xE1 --up
```

On an iPad, `screen click` and `screen scroll` use a virtual pointer, as a trackpad does. A click is a pointer click rather than a touch, and a scroll moves the view under the pointer by exactly the deltas given, with no momentum. `--button secondary` opens the context menu under the pointer, and `--hover 0.5` rests the pointer on the point before it clicks, so hover effects show first. `--normalized` takes 0…1 of the interface as it is shown. The pointer exists only while the command runs. iOS on an iPhone uses it only through AssistiveTouch's pointer devices.

```sh
icli screen click 100 245
icli screen click 100 245 --button secondary
icli screen scroll 400 500 --dy 300
```

`input paste` sends Unicode keyboard events; it does not read the clipboard. `input type` sends one grapheme at a time. Use `icli clipboard get` and `icli clipboard set 'shared text'` for clipboard text. `clipboard get` also reports the pasteboard types, change count and any image; `--image-output /tmp/clip.png` saves the image, and `clipboard set --image /tmp/photo.png` copies one. icli reads and writes the system pasteboard without a prompt. When another app later reads that text programmatically, iOS may show its standard paste permission prompt for that app; user-initiated pastes such as `icli input key cmd+v` are not prompted.

## Capture the Screen

```sh
icli screen shot --output /tmp/screen.jpg
icli screen shot --base64
icli screen ocr
icli screen describe
```

Screenshot paths are on the device. Default screenshots have one image pixel per point. Add `--native-resolution` for native pixel dimensions; the result includes a `coordinate_scale` to relate pixels to points.

`screen describe` uses one capture for its JPEG and OCR results and collects accessibility elements separately. Check its component errors and `context_changed` before combining the results.

OCR uses Apple's Vision framework. If system text recognition is unavailable, the command returns an `unavailable` error; that includes a process with no Metal device, such as one started over SSH on iOS 15, where Vision would otherwise crash. A successful scan with no recognized text returns an empty result.
