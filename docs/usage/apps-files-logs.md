# Apps, Files, and Logs

Use `app list` to find an app's bundle identifier. Replace `example.bundle.id` with an app you installed; file paths refer to the device:

```sh
icli app list
icli app info example.bundle.id
icli app launch example.bundle.id
icli fs write /tmp/example.txt 'Hello from icli'
icli fs read /tmp/example.txt
icli log syslog --seconds 3 --level error
icli log syslog --seconds 10 --subsystem com.example.tweak --message-contains 'loaded' --max-lines 20
icli log crashes --bundle-id example.bundle.id
icli log crash /var/mobile/Library/Logs/CrashReporter/example.ips --max-bytes 65536
```

`log syslog` filters by process name (`--process`, a case-insensitive substring), `--pid`, `--subsystem` (with its dotted children), `--category` (exact), `--message-contains` (case-sensitive) and minimum `--level` (`all`, `debug`, `info`, `default`, `error`, `fault`). Every filter runs before `--max-lines`, so unrelated lines on a busy device never use up the cap; `truncated` says more lines matched than were kept. `log crash --max-bytes` reads at most that many bytes of a report, cut back to a whole character, and reports `truncated` and the whole file's `size`.

Upload a package before installing it:

```sh
sudo icli app install /tmp/example.deb
sudo icli app install /tmp/example.ipa
sudo icli app install /tmp/example.ipa --container
```

DEB operations read archives and update the bootstrap's dpkg database directly. IPA installation validates archive paths and app metadata, preserves the app's signature, and requires the bootstrap to support running it. This IPA installation path does not overwrite apps installed outside icli. With `--container`, the app is installed into its own app container under `/var/containers/Bundle/Application`, with a data container, and registered as a User app (`--registration system` for a System app); reinstalling upgrades it in place and `app uninstall --force` removes both containers. icli does not re-sign apps, so the IPA must already carry a signature the device accepts; on custom firmware with a stock kernel, CoreTrust rejects ad-hoc signatures for apps in a container. Use `icli app uninstall --help` for removal options.

`sudo icli pkg install /tmp/example.deb` installs a local archive and checks architecture and installed dependencies; installing the same version reinstalls it. Package identifiers and repository downloads are not supported. `pkg info`, `pkg extract`, `pkg status`, and `pkg compare` expose metadata, extraction, installed state, and Debian version comparison. `pkg remove` keeps configuration files unless `--purge` is supplied. `pkg repos` and `pkg add-repo` inspect and edit repository source files.

Maintainer scripts and package triggers are not executed. Transactions report skipped scripts in `scripts_not_run` and register installed app bundles through LaunchServices. Packages that require script-driven setup need that setup handled separately; icli is not a complete dpkg or APT replacement.
