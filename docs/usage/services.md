# Services and System Maintenance

```sh
icli env info
icli env basebin --bundled /tmp/basebin.tar
icli svc status example.service
icli svc list
icli svc print example.service
icli svc dump
icli device jetsam
icli svc paths /var/jb/Library/LaunchDaemons/example.service.plist
sudo icli svc load /var/jb/Library/LaunchDaemons/example.service.plist
sudo icli svc kill TERM example.service
sudo icli svc kickstart -k example.service
sudo icli svc unload /var/jb/Library/LaunchDaemons/example.service.plist
icli app refresh
icli sb system-apps get
```

`app refresh` and `sb uicache` work like `uicache -a` on the selected Applications directory. Each app bundle directly inside it is registered when LaunchServices does not list it there, or lists less than uicache registers for it now: another build or version, other entitlements, plug-ins, group containers or containerization, a missing data container or settings-bundle mark, including a record an earlier registration left incomplete. A matching record is left alone, since registering an app stops it, and records of bundles that are gone are removed. Apple's apps and apps the App Store or another installer installed are listed under `skipped` and neither registered nor removed. The result separates `registered`, `unchanged`, `unregistered`, `skipped`, `failed` and `unverified` paths, and fails with `refresh_incomplete` when a registration failed or LaunchServices' record still differs afterwards.

Registration (`app register`, `app refresh` and installs) builds the record uicache from uikittools-ng builds, roothide's fork for apps of a roothide bootstrap and Procursus' otherwise: the executable's entitlements and the containerization they ask for, a data container (roothide makes one only for a containerized bundle), application and system group containers, HOME and TMPDIR, and each bundle in `PlugIns` with its own data container. It also marks an app that has a `Settings.bundle` (`HasSettingsBundle`), which uicache leaves out and without which the Settings app shows no page for it, and then reads the record back and fails when LaunchServices did not keep part of it. icli registers only apps of the bootstrap and apps it installed in a container, which keep the type they were registered with; it refuses a bundle in Apple's system locations or in another installer's container, and a bundle whose identifier another installer's app already has.

On iOS 27 LaunchServices no longer registers from an Info.plist dictionary: the call only logs that it is deprecated. icli then registers the same record through LaunchServices' containerized interface, with each plug-in as a dictionary of its own. lsd accepts that interface only from callers its embedded-registration check lets through, which the vphone firmware patches to allow; elsewhere the registration fails. `uicache` from uikittools 2.1.8 and earlier does not use this interface, so it cannot register apps on iOS 27. Unregistering is unchanged and passes the same lsd check.

`svc bootstrap`/`svc bootout` expose the modern launchctl names; `svc load`/`svc unload` retain the legacy names and their persistent `--enable`/`--disable` overrides. Path commands accept multiple plists or directories. On RootHide, `bootstrap` and `load` first rewrite the paths launchd reads into the jbroot, in place, as RootHide's `launchctl` does (`/rootfs/x` names the system's `/x`) and list the rewritten plists under `patched`; unloading never rewrites, and rootless and rootful plists are used as written. `svc paths` reports each path launchd reads from a plist as written, as launchd will open it, and whether it exists, with a hint when only the other spelling does. Label commands include `list`, `status`, `print`, `enable`, `disable`, `start`, `stop`, `kill`, and `remove`; `print-disabled` reports persistent overrides. `svc dump` returns every visible service with its status and launchd's description in one document and lists the labels launchd refused to describe under `errors`. `device jetsam` reports every process's jetsam band and memory limit, the OS's `com.apple.jetsamproperties.*` property lists, and the memory pressure sysctls; the band list needs root or `com.apple.private.memorystatus` and is replaced by `priorities_error` otherwise. `getenv`, `setenv`, and `unsetenv` operate on launchd's domain environment. Mutating service and environment commands require launchd permission and normally root. `account set-password <user>` reads the new password from stdin and requires root; keep passwords out of command arguments and shell history.

`sudo icli device reboot --force` requests a full reboot; add `--userspace` for a userspace restart. SSH may disconnect before a JSON response arrives; a disconnect alone does not prove success. Verify completion after reconnecting: a userspace restart replaces system and UI service processes while kernel boot time and boot session UUID remain unchanged; a full reboot changes the kernel boot time and session UUID. The acceptance runner records these before/after values.
