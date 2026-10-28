# Script the Device

`icli probe` runs a JavaScriptCore script in the icli process. A script reaches any Objective-C class through a reflection bridge, reads and writes files, prints, and calls icli's own capabilities through `api()`.

```sh
icli probe -e "ObjC.use('NSProcessInfo').processInfo().processName()"
icli probe -e "api('svc.list').count"
echo "var m = ObjC.use('NSFileManager').defaultManager(); m.fileExistsAtPath_('/')" | icli probe -
icli probe script.js
icli probe repl
```

A class method, then an instance method on what it returns: `ObjC.use('NSProcessInfo')` (or `ObjC.classes.NSProcessInfo`) gives a class, and a selector becomes a method call with underscores for its colons (`stringWithUTF8String_`) or the selector written out (`obj['setValue:forKey:'](v, k)`); a leading underscore stays part of a private method's name (`_isDeallocating`). A struct, a non-null pointer or a block is refused with an error rather than passed, since a bad one would take icli down. A string, number, boolean or date comes back as a JavaScript value, and `NSNull` as `null`; anything else, collections included, comes back as a handle whose `$value` converts it, `$class` names its class and `$isClass` says whether it is one. `fs.ls/read/write/stat` use icli's own file access, `console.log`/`print` and `sleep(ms)` do output and waiting, and `api(method, params)` calls an icli capability in process (`env.info`, `device.info`, `screen.info`, `passcode.status`, `svc.list`, `svc.status`, `app.list`, `proc.list`); `params` is an object, encoded as `JSON.stringify` encodes it.

`-e`, a file, or `-` (stdin) prints one JSON line `{ok, result | error, output}`: stdout carries only that line and everything the script printed is collected into `output`. A thrown script is an answer with `ok: false` and a nonzero exit, not a crash. `repl` (or no argument) opens an interactive shell whose output appears as it happens; `.help` lists what is available and `.exit` leaves. ^C abandons a half-finished statement; while a statement runs, ^C ends icli, since nothing inline could stop it otherwise.

The script runs **inline**, in the icli process, with icli's memory, file access and entitlements. There is no `--detach`: a script that crashes or hangs takes icli down with it. A caller that needs to survive a bad script spawns `icli probe` as its own process and reads its JSON line. `proc.run` and `exit()` are deliberately not provided: `exit()` would end the caller, and running other programs belongs to the host that spawns `icli probe`, which adds it through its own `api()` handler. On a platform without JavaScriptCore the command answers `ok: false` with the error `This platform has no JavaScriptCore`; icli's binary gains no process-launch import, so `env info` stays `spawns_processes: false`.
