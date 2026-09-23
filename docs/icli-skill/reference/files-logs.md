# Files and logs: fs, log

All paths are physical device paths. On RootHide, the SSH shell's `/` is the jailbreak root. See the RootHide note in [SKILL.md](../SKILL.md).

## fs

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `fs ls <path>` | Directory entries with name, path, directory and symlink flags, size, modified time | | no | unlocked |
| `fs read <path>` | File content as UTF-8, or as Base64 when the content is binary | `--binary` (always Base64), `--limit <bytes>` (default 524288, max 64 MiB); `truncated` is reported | no | unlocked |
| `fs write <path> <content>` | Write a file, creating parent directories | `--encoding utf8\|base64` | no | unlocked |
| `fs find <root> <pattern>` | Recursive search for relative paths containing `<pattern>` (ignores case, at most 500 results) | | no | unlocked |
| `fs plist <path>` | Property list as JSON | | no | unlocked |
| `fs plist-set <path> <key> [<json-value>]` | Set one top-level key to a JSON value, or remove it | `--remove` | no | any |
| `fs mkdir <path>` | Create a directory, including parents | `--mode 755` | no | any |
| `fs rm <path>` | Remove a file or directory | `--force` required, `--recursive` | no | any |
| `fs link <target> <link>` | Create a symbolic link | `--replace` | no | any |
| `fs chmod <path> <mode>` | Set octal permissions | | no | any |
| `fs chown <path> <owner>` | Set `uid:gid`, as numbers or names | | usually | any |
| `fs copy <src> <dst>` | Copy a file or directory | | no | any |
| `fs move <src> <dst>` | Move or rename | | no | any |

"Root: no" means icli does not demand root. The file's own permissions still apply, so use `sudo` for system locations.

## log

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `log syslog` | Capture the live unified log for a period | `--seconds 3` (0.1–60), `--process <name>`, `--level all\|error\|fault`, `--max-lines 500` (1–5000) | no | any |
| `log crashes` | List crash report paths | `--bundle-id <id>` | no | unlocked |
| `log crash <path>` | Read one crash report | | no | unlocked |
