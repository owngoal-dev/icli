# System: svc, prefs, account, env, proc, sec, net, probe, tests

## svc (launchd)

Label commands take the plist's `Label` value without a domain prefix, for example `com.example.service`. Path commands take one or more plist files or directories. Mutating commands need root and the launchd privileges that the custom firmware grants. Without them they fail with `requires root (launchd status …)`. Every svc command also runs while the device is locked.

On RootHide, `bootstrap` and `load` rewrite each plist in place before handing it to launchd, as RootHide's `launchctl` does: the program (`Program` or `ProgramArguments[0]`) and the other paths launchd itself opens get the jbroot in front, `/rootfs/x` becomes the system's `/x`, an earlier `.jbroot-…` is replaced with the current one, and `__Patched` is set. Plists outside the jbroot, a program under `/rootfs/`, and a plist already patched for the current root are left alone. `bootout` and `unload` never rewrite, and rootless and rootful use plists as written. Check a plist with `svc paths` before loading it.

| Command | Purpose | Key flags | Root |
| --- | --- | --- | --- |
| `svc list [<label>]` | All visible services with PID and last exit status, or one service's status; launchd's full list carries no program path, so only the one-label form reports `program` | | no |
| `svc status <label>` | Enabled, loaded, running, PID | | no |
| `svc print <label>` | launchd's full description | | no |
| `svc print-disabled` | Persistent disabled overrides | | no |
| `svc dump` | Every service with its description in one document; refusals go under `errors` | | no |
| `svc paths <paths…>` | Every path launchd reads from each plist (program, directories, standard streams, `WatchPaths`, `QueueDirectories`, path environment variables, `KeepAlive.PathState`, socket and fsevents paths): `written`, `launchd` (as launchd opens it on this bootstrap), `exists`, and a `hint`/`suggested` spelling when only the other side of the jbroot exists. On RootHide also `system_job` and `load_rewrites`. Reads only | | no |
| `svc bootstrap <paths…>` | Load (modern name). On RootHide, rewrites each plist first; the result lists them under `patched` | | required |
| `svc bootout <paths…>` | Unload (modern name) | | required |
| `svc load <paths…>` | Load (legacy name); rewrites on RootHide like `bootstrap` | `--enable` (like `launchctl load -w`) | required |
| `svc unload <paths…>` | Unload (legacy name) | `--disable` (like `launchctl unload -w`) | required |
| `svc enable <label>` / `svc disable <label>` | Persistent override; does not start or stop the service | | required |
| `svc start <label>` / `svc stop <label>` | Request a start or stop; check `svc status` afterwards (KeepAlive can restart it) | | required |
| `svc kickstart <label>` | Spawn the job now (`launchctl kickstart`); a running instance is left alone unless `-k`, which kills it and waits for it to exit so the new process runs the binary on disk now. `pid` is the new process | `-k`/`--kill` (like `launchctl kickstart -k`) | required |
| `svc kill <signal> <label>` | Send a signal (1–31, or a name such as `TERM`) | | required |
| `svc remove <label>` | Remove a loaded service | | required |
| `svc getenv <key>` | Read a launchd environment variable | | no |
| `svc setenv <key> <value>` / `svc unsetenv <key>` | Change it and verify | | required |

## prefs (cfprefsd, like `defaults`)

`<domain>` is a preference domain such as `com.apple.springboard`, or an absolute physical path ending in `.plist`. Every prefs command runs while the device is locked. `--user` picks whose preferences: `mobile` (default, also under sudo; what apps and Settings use), `root`, `current` (the caller) or `any` (`/var/preferences`; writing it needs root).

| Command | Purpose | Key flags | Root |
| --- | --- | --- | --- |
| `prefs read <domain> [<key>]` | One key as `value`, `type`, `exists`, or the whole domain as `values: {key: {value, type}}` and `count` | `--user` | no |
| `prefs write <domain> <key> <value>` | Write through cfprefsd, synchronize, return the value read back | `--type string\|int\|float\|bool\|date\|data\|json`, `--user`, `--notify <darwin-notification>` | no |
| `prefs delete <domain> <key>` | Remove the key and confirm it is gone; `removed` is false if it was not set | `--user`, `--notify` | no |

Types on read are `string`, `int`, `float`, `bool`, `date` (ISO-8601), `data` (Base64), `array` and `dictionary`. On write, `date` takes ISO-8601 or epoch seconds, `data` takes Base64, `json` takes an array or object (no nulls). Put `--` before a negative number: `icli prefs write --type int <domain> <key> -- -7`. cfprefsd writes the plist to disk a few seconds after the command returns. On RootHide, the non-Apple domains of a process running inside the bootstrap are kept in the jbroot (the shell's `/var/mobile/Library/Preferences`), while `com.apple.*` domains use the system's own file.

## account, env, proc

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `account set-password [<user>]` | Set the bootstrap account's password. The password is the first line of stdin, never an argument | user defaults to `mobile` | required | any |
| `env info` | `layout` (`rootless`/`roothide`/`rootful`), `jbroot`, `rootfs_prefix`, `basebin_version`, `euid`, `spawns_processes: false` | | no | any |
| `env basebin` | Installed BaseBin version, optionally compared with a bundled archive | `--bundled <basebin.tar>` | no | any |
| `proc list` | Processes with PID, name, path | `--filter <text>` | no | unlocked |

Example: `printf '%s\n' "$NEWPASS" | sudo icli account set-password mobile`.

## probe

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `probe [-e <src> \| <file> \| -]` | Evaluate a JavaScriptCore script in-process and print one JSON line `{ok, result \| error, output}` | `-e/--eval <src>`; `-` reads stdin | no | any |
| `probe repl` | Interactive shell; `.help` lists what is available, `.exit` leaves; ^C abandons a half-finished statement, and ends icli while one runs | | no | any |

A script reaches Objective-C classes through `ObjC.use('NSProcessInfo')` / `ObjC.classes.NSProcessInfo` and calls methods by name (`stringWithUTF8String_`, `_privateMethod`, or `obj['setValue:forKey:'](v, k)`); structs, non-null pointers and blocks are refused; a string, number, boolean or date comes back as a JavaScript value and `NSNull` as `null`, anything else as a handle with `$value`, `$class`, `$isClass`. `fs.ls/read/write/stat`, `console.log`/`print`, `sleep(ms)`, and `api(method, params)` (icli capabilities in process: `env.info`, `device.info`, `screen.info`, `svc.list`, `svc.status`, `app.list`, `proc.list`) are the prelude. Scripts run **inline** in the icli process — a crash or hang takes icli down, so isolate one by spawning `icli probe` as its own process. There is no `--detach`, no `proc.run` and no `exit()`. A thrown script is `ok: false` with a nonzero exit, not a crash. On a platform without JavaScriptCore the command answers `ok: false` with the error `This platform has no JavaScriptCore`; the binary gains no process-launch import.

## sec

Security.framework Keychain commands use the calling process's access groups (`icli.test` is the default `--group` for writes). The separate `database` command can read protected metadata across groups when the process can read the system Keychain database. It never returns item values or encrypted blobs.

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `sec keychain list` | Matching items (metadata) | `--class generic_password\|internet_password\|certificate\|key\|identity`, `--service`, `--account`, `--server`, `--group` | no | any; Security.framework may deny locked items |
| `sec keychain database` | Protected database metadata, with source and per-table counts | `--class genp\|inet\|cert\|keys` | filesystem access (usually root) | any |
| `sec keychain get` | One item, including its data | same filters (class defaults to generic_password) | no | any; Security.framework enforces access |
| `sec keychain add` | Add an item | `--account` and `--data` required, `--service`, `--server`, `--label`, `--group icli.test` | no | any; Security.framework enforces access |
| `sec keychain update` | Replace an item's data | `--account` and `--data` required | no | any; Security.framework enforces access |
| `sec keychain delete` | Delete matching items | `--force` required | no | any; Security.framework enforces access |
| `sec ssl-killswitch` | Look for SSL Kill Switch files | | no | unlocked |

## net

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `net capture` | BPF packet capture to a pcap file | `--seconds 5`, `--interface en0`, `--filter '[tcp\|udp\|icmp] [src\|dst] port N [src\|dst] host A'` (terms joined with `and`), `--output <file.pcap>` | required (BPF device) | any |

## tests

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `tests` | On-device self-tests: device info, paths, processes, LaunchServices, files, Debian versions, screenshot, accessibility, OCR, a temporary Keychain item | `--expect-layout rootless\|roothide\|rootful` (stops on mismatch), `--registration-fixture <SelfTestFixture.app>` | no | any (screen tests need the device unlocked) |

The report has pass, fail and skip counts plus `complete`. A failed test exits nonzero. The tests do not reboot the device or change its settings.
