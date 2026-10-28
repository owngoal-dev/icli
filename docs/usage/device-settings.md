# Location, Power, and Preferences

```sh
icli location set 37.3349 -122.0090
icli location get
icli location clear
icli device low-power set on
icli device timezone set Asia/Shanghai
icli notify post com.apple.springboard.lockcomplete
icli notify get com.apple.springboard.lockstate
icli device devmode get
icli prefs read com.apple.springboard SBShowBatteryPercentage
icli prefs write example.domain Enabled true --type bool
icli prefs delete example.domain Enabled
```

A simulated location applies to every app and stays on after icli exits, until `location clear`. `notify post` posts a Darwin notification to every observer, optionally storing a `--state` value first; names that notifyd reserves, such as those under `com.apple.system.`, need root. `device devmode enable` asks the system to turn Developer Mode on after the next restart and does nothing when it is already on. `device timezone set` turns Set Automatically off and switches the system time zone; running apps follow at once, and `device timezone automatic on` hands it back to the system. `prefs` commands use mobile's preferences by default, including under `sudo`; `--user root`, `current` or `any` choose another set, and a `.plist` path works as a domain. Writes go through cfprefsd, so running apps see them.

## Unlock with a Passcode

For test automation, `device passcode unlock` unlocks the keybag with a passcode you supply. icli never guesses, generates or iterates passcodes, and it refuses an attempt that could lock the device out. See [the design notes](../development/passcode-unlock.md) for the rationale and what is still unverified.

```sh
icli device passcode status
printf '%s\n' "$PASSCODE" | icli device passcode unlock --passcode-stdin
icli device passcode unlock --passcode-file ~/.icli-passcode   # chmod 600
icli device passcode unlock                                    # prompts on a terminal, no echo
icli device passcode unlock --passcode-stdin --check < ~/.icli-passcode
icli device passcode forget --force
```

The passcode never goes in argv. `--passcode-file` refuses a file that is not regular, not owned by you or root, or open to group or others. Nothing reaches the keybag when it is already unlocked, when the same passcode was rejected before, when the larger of icli's recorded failures and the keybag's failed-attempt counter has reached `--max-failures` (default 3, at most 4, so icli never makes the fifth attempt that starts iOS's delays), or while the keybag backs off. Every answer carries `attempts_remaining` and a `hint`.

icli records a salted PBKDF2 digest of each rejected passcode in `/var/mobile/Library/Caches/com.icli.icli/passcode-ledger.json` (0600), and empties it when an unlock succeeds. After the device passcode changes, a passcode recorded as wrong may now be right: run `forget --force`. The exit status is 0 unlocked, 3 rejected now, 4 rejected before and not retried, 5 refused by a guard, 6 a keybag error that did not count as an attempt.

Unlocking the keybag does not dismiss the lock screen; `lock_screen` in the answer shows whether it is still up.
