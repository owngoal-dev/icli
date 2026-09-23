# System: svc, prefs, account, env, proc, sec, net, tests

## svc (launchd)

Label commands take the plist's `Label` value without a domain prefix, for example `com.example.service`. Path commands take one or more plist files or directories. Mutating commands need root and the launchd privileges the jailbreak grants. Without them they fail with `requires root (launchd status …)`. Every svc command also runs while the device is locked.

| Command | Purpose | Key flags | Root |
| --- | --- | --- | --- |
| `svc list [<label>]` | All visible services, or one service's status | | no |
| `svc status <label>` | Enabled, loaded, running, PID | | no |
| `svc print <label>` | launchd's full description | | no |
| `svc print-disabled` | Persistent disabled overrides | | no |
| `svc dump` | Every service with its description in one document; refusals go under `errors` | | no |
| `svc bootstrap <paths…>` | Load (modern name) | | required |
| `svc bootout <paths…>` | Unload (modern name) | | required |
| `svc load <paths…>` | Load (legacy name) | `--enable` (like `launchctl load -w`) | required |
| `svc unload <paths…>` | Unload (legacy name) | `--disable` (like `launchctl unload -w`) | required |
| `svc enable <label>` / `svc disable <label>` | Persistent override; does not start or stop the service | | required |
| `svc start <label>` / `svc stop <label>` | Request a start or stop; check `svc status` afterwards (KeepAlive can restart it) | | required |
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

Types on read are `string`, `int`, `float`, `bool`, `date` (ISO-8601), `data` (Base64), `array` and `dictionary`. On write, `date` takes ISO-8601 or epoch seconds, `data` takes Base64, `json` takes an array or object (no nulls). Put `--` before a negative number: `icli prefs write --type int <domain> <key> -- -7`. cfprefsd writes the plist to disk a few seconds after the command returns. On RootHide, a jailbroken process's non-Apple domains are kept in the jbroot (the shell's `/var/mobile/Library/Preferences`), while `com.apple.*` domains use the system's own file.

## account, env, proc

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `account set-password [<user>]` | Set the bootstrap account's password. The password is the first line of stdin, never an argument | user defaults to `mobile` | required | any |
| `env info` | `layout` (`rootless`/`roothide`/`rootful`), `jbroot`, `rootfs_prefix`, `basebin_version`, `euid`, `spawns_processes: false` | | no | any |
| `env basebin` | Installed BaseBin version, optionally compared with a bundled archive | `--bundled <basebin.tar>` | no | any |
| `proc list` | Processes with PID, name, path | `--filter <text>` | no | unlocked |

Example: `printf '%s\n' "$NEWPASS" | sudo icli account set-password mobile`.

## sec

Keychain commands only operate on items in the `icli.test` access group (the default `--group` for writes). They cannot read other apps' items.

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `sec keychain list` | Matching items (metadata) | `--class generic_password\|internet_password\|certificate\|key\|identity`, `--service`, `--account`, `--server`, `--group` | no | unlocked |
| `sec keychain get` | One item, including its data | same filters (class defaults to generic_password) | no | unlocked |
| `sec keychain add` | Add an item | `--account` and `--data` required, `--service`, `--server`, `--label`, `--group icli.test` | no | unlocked |
| `sec keychain update` | Replace an item's data | `--account` and `--data` required | no | unlocked |
| `sec keychain delete` | Delete matching items | `--force` required | no | unlocked |
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
