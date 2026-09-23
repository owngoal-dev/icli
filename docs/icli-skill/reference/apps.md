# Apps: app, url, sb

## app

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `app list` | Installed apps with bundle ID, name, version, path | | no | unlocked |
| `app search <query>` | Apps whose name or bundle ID matches | | no | unlocked |
| `app running` | Running apps with PIDs | | no | unlocked |
| `app frontmost` | Bundle ID and PID of the foreground app (`com.apple.springboard` on the home screen) | | no | unlocked |
| `app info <bundle-id>` | LaunchServices record: bundle path, executable, version, entitlements | | no | unlocked |
| `app launch <bundle-id>` | Launch and wait up to 5 s for the app to be frontmost | | no | unlocked |
| `app open <url>` | Open a URL, optionally in a specific app | `--bundle <bundle-id>` | no | unlocked |
| `app kill <bundle-id>` | SIGTERM the app's processes and wait for them to exit | `--force` required | no | unlocked |
| `app install <path>` | `.deb` → native package install; `.ipa` → install into the bootstrap and register; `.app` → register | | required for .deb and .ipa | unlocked |
| `app uninstall <bundle-id>` | Remove an app that icli installed from an IPA | `--force`; `--package` treats the argument as a Debian package name (needs `--force`) | required | unlocked |
| `app register <path.app>` | Register one bundle with LaunchServices and read the record back | | usually | any |
| `app unregister <path.app>` | Unregister one bundle | `--force` required | usually | any |
| `app refresh` | Register new, moved or updated apps and drop stale ones | `--directory <dir>` (default: the bootstrap's /Applications) | usually | any |
| `app unregister-dir <dir>` | Unregister every app directly inside a directory | `--force` required | usually | any |
| `app network get <bundle-id>` | Wi-Fi and cellular data policy | | no | any |
| `app network repair <bundle-id>` | Set both policies to always-allow and read them back | | usually | any |
| `app handlers <url-or-scheme>` | Apps that handle a URL or scheme | | no | unlocked |
| `app schemes` | Every registered URL scheme | | no | unlocked |
| `app binary <bundle-id>` | Main executable: path, SDK, minimum OS, encryption, signing error | | no | unlocked |
| `app data <bundle-id>` | Data container path | | no | unlocked |

## url

| Command | Purpose | Root | Screen |
| --- | --- | --- | --- |
| `url open <url>` | Open a URL in its registered app | no | unlocked |

## sb (SpringBoard)

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `sb uicache` | `app refresh` for the bootstrap's /Applications | | usually | any |
| `sb respring` | Restart SpringBoard and wait for the new process | | no | any |
| `sb system-apps get` | Whether non-default system apps are visible | | no | any |
| `sb system-apps set <on\|off>` | Show or hide them; the result says whether a respring is needed | | usually | any |
