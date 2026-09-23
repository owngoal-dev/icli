# pkg (Debian packages)

icli reads `.deb` archives and updates the bootstrap's dpkg database itself. It never runs maintainer scripts or triggers; a transaction lists them in `scripts_not_run`. It does not download from repositories.

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `pkg list` | Installed packages | `--filter <text>` | no | any |
| `pkg status <name>` | Installed state and version from dpkg's database | | no | any |
| `pkg info <file.deb>` | Control fields, scripts and file list | | no | any |
| `pkg extract <file.deb> <empty-dir>` | Unpack `DEBIAN/` and the payload | | no | any |
| `pkg install <file.deb>` | Install a local archive; checks architecture and dependencies. The same version reinstalls | `--ignore-depends` | required | any |
| `pkg remove <name>` | Remove an installed package; keeps configuration files | `--purge` | required | any |
| `pkg compare <left> <right>` | Compare two Debian version strings | | no | any |
| `pkg repos` | Configured repository sources | | no | any |
| `pkg add-repo <url>` | Add a repository source file entry (`added: false` if it is already present) | | usually | any |
| `pkg tweaks` | Tweak dylibs in the bootstrap's MobileSubstrate/TweakInject directories | | no | any |

`sudo icli app install <file.deb>` is the same as `pkg install`. `sudo icli app uninstall <name> --package --force` is the same as `pkg remove`.
