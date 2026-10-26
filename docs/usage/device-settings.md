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
