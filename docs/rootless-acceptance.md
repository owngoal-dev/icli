# icli 0.3.0 rootless 验收

本报告由 `scripts/assemble-release.py` 根据 `acceptance.json` 与 `package-verification.json` 生成，不含手工填写的结果。
测试时间：2026-09-07T06:40:16.087052+00:00。用例 44/44 通过；命令入口 105/105 被实际执行。
PASS 只表示所列用例在下述设备上通过，不代表其他 iOS 版本、参数组合或物理硬件已经认证。

## 交付与身份

- 版本 `0.3.0`，签名 arm64 Mach-O SHA-256：`0f94537e5acd1a7974b11e68e2cf8b62f49c4c653e3528df0373bc4ed91d2cac`。
- 本机构建、设备上执行的文件和两个 DEB 中的文件哈希一致；架构、部署目标、entitlements、系统依赖、属主和仅含 CLI 的包内容由 `package-verification.json` 记录。
- 单二进制自包含：DEB 仅依赖 iOS firmware，第三方归档库静态链接；构建和包检查未发现进程启动导入符号，`environment_report` 用例检查 `spawns_processes: false` 与空的 `external_tools_used`。符号检查覆盖直接链接调用。
- 测试设备：iPhone99,11，iOS 26.6.1，rootless 布局（`/var/jb`）。
- 设备快照、每条命令的参数、退出码、耗时和有界输出记录在 `acceptance.json`。
- `IcliKit` 库已由独立 Swift Package 使用精确版本依赖构建，并在设备上完成环境查询、版本比较与包状态读取；证据见 `package-consumer-verification.json`。完整 entitlements 说明见 `docs/entitlements.md`。

| 布局 | 包 | SHA-256 |
| --- | --- | --- |
| rootless | `com.icli.icli_0.3.0_iphoneos-arm64.deb` | `1ffae52296a07bf5d326feb53db11e2d8a38b53907c58347f9e8546d8dc52862` |
| roothide | `com.icli.icli_0.3.0_iphoneos-arm64e.deb` | `1bd0cc05a86cf7666a4def10c7814582753008112624e8d3895c89b61dbd57d3` |

## 用例结果

| 用例 | 结果 | 秒 | 错误 |
| --- | --- | --- | --- |
| `device_snapshot` | PASS | 0.2 |  |
| `file_roundtrip` | PASS | 0.9 |  |
| `ax_tree_and_tap` | PASS | 2.4 |  |
| `ax_identifier` | PASS | 1.5 |  |
| `ax_hit_test` | PASS | 1.2 |  |
| `ax_waits` | PASS | 4.3 |  |
| `touch_tap` | PASS | 1.3 |  |
| `touch_double_and_long` | PASS | 2.5 |  |
| `touch_swipe` | PASS | 1.9 |  |
| `touch_drag_path` | PASS | 2.6 |  |
| `unicode_input` | PASS | 3.6 |  |
| `clipboard_roundtrip` | PASS | 6.2 |  |
| `app_lifecycle_and_metadata` | PASS | 7.7 |  |
| `brightness_and_volume` | PASS | 4.6 |  |
| `install_remove_deb` | PASS | 0.6 |  |
| `install_remove_ipa` | PASS | 2.9 |  |
| `crash_report_roundtrip` | PASS | 3.6 |  |
| `home_power_wake` | PASS | 4.3 |  |
| `audio_buttons` | PASS | 3.8 |  |
| `screenshot_coordinates` | PASS | 1.2 |  |
| `raster_ocr_and_description` | PASS | 1.7 |  |
| `invalid_gesture_parameters` | PASS | 0.6 |  |
| `unified_log_events` | PASS | 4.1 |  |
| `extended_files` | PASS | 0.3 |  |
| `filesystem_maintenance` | PASS | 4.4 |  |
| `extended_app_metadata` | PASS | 2.2 |  |
| `rotation_and_lock` | PASS | 5.6 |  |
| `package_commands` | PASS | 1.5 |  |
| `package_metadata_native` | PASS | 1.3 |  |
| `launchd_services` | PASS | 5.2 |  |
| `app_registration_refresh` | PASS | 4.0 |  |
| `app_network_policy` | PASS | 1.5 |  |
| `system_apps_visibility` | PASS | 7.3 |  |
| `account_password` | PASS | 0.8 |  |
| `environment_report` | PASS | 0.7 |  |
| `boot_logo_render` | PASS | 1.1 |  |
| `repository_configuration` | PASS | 0.6 |  |
| `keychain_fixture` | PASS | 1.0 |  |
| `system_inspection` | PASS | 0.3 |  |
| `icon_cache` | PASS | 1.2 |  |
| `loopback_packet_capture` | PASS | 4.7 |  |
| `springboard_restart` | PASS | 14.4 |  |
| `userspace_reboot` | PASS | 26.4 |  |
| `device_reboot` | PASS | 34.8 |  |

## 命令覆盖

状态来自实际执行记录：某命令被任一失败用例执行过即标记 FAIL，没有用例执行过即 UNTESTED。

| 命令 | 状态 | 用例 |
| --- | --- | --- |
| `device info` | PASS | `device_reboot`, `device_snapshot`, `userspace_reboot` |
| `device brightness get` | PASS | `brightness_and_volume` |
| `device brightness set` | PASS | `brightness_and_volume` |
| `device volume get` | PASS | `audio_buttons`, `brightness_and_volume` |
| `device volume set` | PASS | `audio_buttons`, `brightness_and_volume` |
| `device rotation get` | PASS | `rotation_and_lock` |
| `device rotation set` | PASS | `rotation_and_lock` |
| `device rotation lock get` | PASS | `rotation_and_lock` |
| `device rotation lock set` | PASS | `rotation_and_lock` |
| `device network` | PASS | `system_inspection` |
| `device ioreg` | PASS | `system_inspection` |
| `device reboot` | PASS | `device_reboot`, `userspace_reboot` |
| `device bootlogo` | PASS | `boot_logo_render` |
| `screen tap` | PASS | `home_power_wake`, `invalid_gesture_parameters`, `touch_tap` |
| `screen swipe` | PASS | `invalid_gesture_parameters`, `touch_swipe` |
| `screen long-press` | PASS | `invalid_gesture_parameters`, `touch_double_and_long` |
| `screen double-tap` | PASS | `invalid_gesture_parameters`, `touch_double_and_long` |
| `screen drag` | PASS | `invalid_gesture_parameters`, `touch_drag_path` |
| `screen shot` | PASS | `boot_logo_render`, `home_power_wake`, `screenshot_coordinates` |
| `screen info` | PASS | `boot_logo_render`, `device_reboot`, `device_snapshot`, `home_power_wake`, `screenshot_coordinates`, `springboard_restart`, `userspace_reboot` |
| `screen ocr` | PASS | `raster_ocr_and_description` |
| `screen describe` | PASS | `raster_ocr_and_description` |
| `button home` | PASS | `home_power_wake` |
| `button power` | PASS | `home_power_wake` |
| `button volume-up` | PASS | `audio_buttons` |
| `button volume-down` | PASS | `audio_buttons` |
| `button mute` | PASS | `audio_buttons` |
| `button wake` | PASS | `device_reboot`, `home_power_wake`, `springboard_restart`, `userspace_reboot` |
| `input paste` | PASS | `unicode_input` |
| `input type` | PASS | `unicode_input` |
| `input key` | PASS | `clipboard_roundtrip`, `unicode_input` |
| `app list` | PASS | `app_lifecycle_and_metadata` |
| `app search` | PASS | `extended_app_metadata` |
| `app running` | PASS | `app_lifecycle_and_metadata` |
| `app frontmost` | PASS | `app_lifecycle_and_metadata`, `brightness_and_volume`, `clipboard_roundtrip`, `home_power_wake`, `icon_cache`, `userspace_reboot` |
| `app info` | PASS | `app_lifecycle_and_metadata`, `app_registration_refresh`, `install_remove_ipa` |
| `app launch` | PASS | `app_lifecycle_and_metadata`, `app_network_policy`, `app_registration_refresh`, `audio_buttons`, `ax_hit_test`, `ax_identifier`, `ax_tree_and_tap`, `ax_waits`, `brightness_and_volume`, `clipboard_roundtrip`, `crash_report_roundtrip`, `extended_app_metadata`, `home_power_wake`, `icon_cache`, `install_remove_ipa`, `loopback_packet_capture`, `raster_ocr_and_description`, `rotation_and_lock`, `screenshot_coordinates`, `touch_double_and_long`, `touch_drag_path`, `touch_swipe`, `touch_tap`, `unicode_input`, `unified_log_events`, `userspace_reboot` |
| `app open` | PASS | `extended_app_metadata` |
| `app kill` | PASS | `app_lifecycle_and_metadata` |
| `app install` | PASS | `install_remove_deb`, `install_remove_ipa` |
| `app uninstall` | PASS | `install_remove_deb`, `install_remove_ipa` |
| `app register` | PASS | `app_registration_refresh` |
| `app unregister` | PASS | `app_registration_refresh` |
| `app refresh` | PASS | `app_registration_refresh` |
| `app unregister-dir` | PASS | `app_registration_refresh` |
| `app network get` | PASS | `app_network_policy` |
| `app network repair` | PASS | `app_network_policy` |
| `app handlers` | PASS | `app_registration_refresh`, `extended_app_metadata` |
| `app schemes` | PASS | `extended_app_metadata` |
| `app binary` | PASS | `extended_app_metadata` |
| `app data` | PASS | `extended_app_metadata` |
| `ui tree` | PASS | `ax_tree_and_tap` |
| `ui at` | PASS | `ax_hit_test` |
| `ui tap` | PASS | `ax_identifier`, `ax_tree_and_tap` |
| `ui wait` | PASS | `ax_waits` |
| `ui wait-gone` | PASS | `ax_waits` |
| `clipboard get` | PASS | `clipboard_roundtrip` |
| `clipboard set` | PASS | `clipboard_roundtrip` |
| `fs ls` | PASS | `file_roundtrip` |
| `fs read` | PASS | `boot_logo_render`, `device_reboot`, `file_roundtrip`, `filesystem_maintenance`, `install_remove_deb`, `package_commands`, `package_metadata_native` |
| `fs write` | PASS | `device_reboot`, `extended_files`, `file_roundtrip`, `filesystem_maintenance`, `launchd_services` |
| `fs find` | PASS | `extended_files` |
| `fs plist` | PASS | `extended_files`, `system_apps_visibility` |
| `fs plist-set` | PASS | `filesystem_maintenance` |
| `fs mkdir` | PASS | `filesystem_maintenance` |
| `fs rm` | PASS | `filesystem_maintenance` |
| `fs link` | PASS | `filesystem_maintenance` |
| `fs chmod` | PASS | `filesystem_maintenance` |
| `fs chown` | PASS | `filesystem_maintenance` |
| `fs copy` | PASS | `filesystem_maintenance` |
| `fs move` | PASS | `filesystem_maintenance` |
| `log syslog` | PASS | `unified_log_events` |
| `log crashes` | PASS | `crash_report_roundtrip` |
| `log crash` | PASS | `crash_report_roundtrip` |
| `url open` | PASS | `app_lifecycle_and_metadata`, `app_network_policy`, `app_registration_refresh`, `audio_buttons`, `ax_hit_test`, `ax_identifier`, `ax_tree_and_tap`, `ax_waits`, `brightness_and_volume`, `clipboard_roundtrip`, `crash_report_roundtrip`, `extended_app_metadata`, `home_power_wake`, `icon_cache`, `install_remove_ipa`, `loopback_packet_capture`, `raster_ocr_and_description`, `rotation_and_lock`, `screenshot_coordinates`, `touch_double_and_long`, `touch_drag_path`, `touch_swipe`, `touch_tap`, `unicode_input`, `unified_log_events`, `userspace_reboot` |
| `pkg list` | PASS | `package_commands` |
| `pkg install` | PASS | `package_commands` |
| `pkg remove` | PASS | `package_commands` |
| `pkg info` | PASS | `package_metadata_native` |
| `pkg extract` | PASS | `package_metadata_native` |
| `pkg status` | PASS | `package_commands` |
| `pkg compare` | PASS | `package_metadata_native` |
| `pkg repos` | PASS | `repository_configuration` |
| `pkg add-repo` | PASS | `repository_configuration` |
| `pkg tweaks` | PASS | `package_commands` |
| `sb uicache` | PASS | `app_registration_refresh`, `icon_cache` |
| `sb respring` | PASS | `springboard_restart` |
| `sb system-apps get` | PASS | `system_apps_visibility` |
| `sb system-apps set` | PASS | `system_apps_visibility` |
| `svc load` | PASS | `launchd_services` |
| `svc unload` | PASS | `launchd_services` |
| `svc enable` | PASS | `launchd_services` |
| `svc disable` | PASS | `launchd_services` |
| `svc status` | PASS | `device_reboot`, `launchd_services` |
| `account set-password` | PASS | `account_password` |
| `env info` | PASS | `environment_report` |
| `env basebin` | PASS | `environment_report` |
| `proc list` | PASS | `extended_app_metadata`, `launchd_services`, `springboard_restart`, `userspace_reboot` |
| `sec keychain list` | PASS | `keychain_fixture` |
| `sec keychain get` | PASS | `keychain_fixture` |
| `sec keychain add` | PASS | `keychain_fixture` |
| `sec keychain update` | PASS | `keychain_fixture` |
| `sec keychain delete` | PASS | `keychain_fixture` |
| `sec ssl-killswitch` | PASS | `system_inspection` |
| `net capture` | PASS | `loopback_packet_capture` |

## 观察

- `raster_ocr_and_description`: System Vision OCR is unavailable; direct OCR and screen description report it explicitly, independently confirmed by TestHost.
- `account_password`: The new password is read from stdin and never appears in argv or the trace; the rootfs account database is untouched, so the stock system password remains valid for iOS itself.
- `environment_report`: This vphone has no BaseBin (no /var/jb/basebin/.version); the installed side of the comparison reports installed_present=false.
- `userspace_reboot`: SSH disconnected during the reboot call before a JSON response; completion is checked after reconnecting, not inferred from the disconnect.
- `userspace_reboot`: Userspace restart replaced system and UI services: {'SpringBoard': 1623, 'notifyd': 36, 'logd': 32} -> {'notifyd': 1666, 'logd': 1662, 'SpringBoard': 1669}; kernel boot time and boot session UUID remained unchanged.
- `device_reboot`: SSH disconnected during the reboot call before a JSON response; completion is checked after reconnecting, not inferred from the disconnect.
- `device_reboot`: A full reboot clears /tmp, so the install fixtures and TestHost must be uploaded again before rerunning other groups.

## 已知边界

- RootHide 运行未验收：experimental-roothide 中的 DEB 只完成了包检查和同二进制检查。
- 剪贴板、亮度、旋转和 Keychain 由 CLI 直接执行，不启动 App、不切换前台。其他 App 程序化读取 icli 写入的剪贴板文本时，iOS 可能弹出系统粘贴许可提示；用户发起的粘贴（如快捷键）不会。
- Keychain 命令只在 `icli.test` 访问组内操作自建条目，不读取其他 App 的凭据。
- 音量按键在 HID 不生效时使用系统音频控制接口；虚拟机没有可用于验收的实体响铃开关。
- IPA 保留原签名并依赖 bootstrap 的执行能力；不提供签名绕过。
- DEB 在进程内解包并维护 dpkg 数据库；维护者脚本与 triggers 不执行，需要脚本配置的包不属于完整安装兼容承诺。仅支持本地 DEB，不提供 APT 下载与依赖解析安装。
- 重启可能在 JSON 返回前切断 SSH，断连本身不代表完成；用户态重启通过系统与 UI 服务进程更换且内核启动信息不变验证，完整重启通过 kernel boot time 与 boot session UUID 变化验证。完整重启清空 `/tmp`。

## 重跑

```sh
make all CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
./scripts/check-packages.sh
./scripts/build-testhost.sh
./scripts/build-install-fixtures.sh
python3 scripts/acceptance.py --install --report .build/acceptance-release.json
python3 scripts/check-package-consumer.py --device
python3 scripts/assemble-release.py
```

先在设备上安装 `test-fixtures` 中的 TestHost DEB，并把 IPA/DEB 夹具上传到设备 `/tmp`。SSH 密码由 `ICLI_SSH_PASSWORD` 或 SSH key 提供，不写入报告。
