# Entitlements and execution requirements

[Resources/icli.entitlements](../Resources/icli.entitlements) is the authoritative signing profile for the shipped CLI. This inventory covers all 62 keys and their exact configured values. The complete profile is tested together on the rootless vphone; individual keys have **not** been tested by removing them one at a time. Descriptions below explain each capability's intended role, not a claim that every key is necessary on every iOS release. Private capabilities depend on the OS and bootstrap.

When linking **IcliKit**, entitlements must be granted to the final calling executable or app. SwiftPM does not apply this file to consumers or sign them. Use your own `application-identifier` and `com.apple.application-identifier`; the `com.icli.icli` values identify the CLI. Integrate only the feature groups your host needs using its existing signing process. Ordinary provisioning cannot grant this private platform profile.

Entitlements do not make a process root. Package installation/removal, account password changes, reboots, and privileged filesystem/service operations require the appropriate effective UID. No command elevates itself or launches sudo. Keychain, app data, screenshots, and interaction remain subject to the system's actual access decisions; the library does not promise access to protected content.

## Identity and process environment

| Key | CLI value | Intended role |
| --- | --- | --- |
| `platform-application` | `true` | Platform identity used by privileged system service clients; `environmentReport()` checks actual platform status separately. |
| `application-identifier` | `com.icli.icli` | CLI application identity; replace with the consumer's own identifier. |
| `com.apple.application-identifier` | `com.icli.icli` | Companion platform application identity; replace with the consumer's own identifier. |
| `com.apple.private.security.no-sandbox` | `true` | CLI process environment for device-wide filesystem and system service operations. |
| `com.apple.private.security.container-required` | `false` | CLI does not require an application container. |
| `com.apple.private.security.no-container` | `true` | Companion container policy for a standalone executable. |
| `com.apple.private.skip-library-validation` | `true` | Bootstrap/private-library loading profile; not itself a library dependency or a guarantee of load permission. |

## Applications and containers

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.private.security.storage.AppBundles` | `true` | App bundle storage used for inspection and registration. |
| `com.apple.private.security.storage.AppDataContainers` | `true` | App data container inspection. |
| `com.apple.backboardd.launchapplications` | `true` | BackBoard app launch client capability. |
| `com.apple.springboard.launchapplications` | `true` | SpringBoard app launch client capability. |
| `com.apple.frontboard.launchapplications` | `true` | FrontBoard launch/relaunch actions. |
| `com.apple.frontboard.shutdown` | `true` | FrontBoard shutdown/relaunch action used by respring. |
| `com.apple.springboard.opensensitiveurl` | `true` | SpringBoard URL opening profile; URL handling still depends on the OS. |
| `com.apple.private.mobileinstall.allowedSPI` | `Browse`, `Lookup`, `Install`, `Uninstall`, `InstallForLaunchServices`, `UninstallForLaunchServices`, `CopyInstalledAppsForLaunchServices` | Allowed MobileInstallation SPI names: discovery, installation/removal, and LaunchServices-specific registration bookkeeping. |
| `com.apple.private.coreservices.canmaplsdatabase` | `true` | LaunchServices database mapping for app/proxy queries. |
| `com.apple.lsapplicationworkspace.rebuildappdatabases` | `true` | Workspace app database maintenance profile. |
| `com.apple.private.coreservices.can-perform-rebuild-registration` | `true` | Registration maintenance/rebuild profile. |
| `com.apple.private.coreservices.lsaw` | `true` | LSApplicationWorkspace operations. |
| `com.apple.private.coreservices.can-register-install-results` | `true` | Register installation results with LaunchServices. |
| `com.apple.private.coreservices.can-send-install-notifications` | `true` | Installation/removal notification capability. |
| `com.apple.private.coreservices.canforcedatabasegc` | `true` | Database cleanup capability retained in the registration profile; no explicit GC command is exposed. |
| `com.apple.private.coreservices.canmapbundleidtouuid` | `true` | Bundle identifier/container mapping capability. |
| `com.apple.private.installcoordinationd.daemon` | `true` | Installation coordination profile retained for app maintenance. |
| `com.apple.private.MobileContainerManager.allowed` | `true` | MobileContainerManager operations associated with app installation/removal. |
| `com.apple.private.MobileContainerManager.delete` | `true` | Container deletion associated with app removal. |
| `com.apple.private.security.container-manager` | `true` | Companion container manager capability. |

## Input, accessibility, display, and clipboard

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.private.hid.client.event-dispatch` | `true` | Touch, keyboard, and button HID dispatch. |
| `com.apple.private.hid.client.event-monitor` | `true` | HID client profile; independent necessity is unverified. |
| `com.apple.hid.manager.user-access-device` | `true` | HID device client access. |
| `com.apple.private.hid.client.event-filter` | `true` | HID client profile; independent necessity is unverified. |
| `com.apple.backboard.client` | `true` | BackBoard display/input state client. |
| `com.apple.springboard.orientationlock` | `true` | Orientation lock inspection and updates. |
| `com.apple.private.accessibility.inspection` | `true` | AX element inspection and hit testing. |
| `com.apple.accessibility.api` | `true` | Accessibility API client profile. |
| `com.apple.private.accessibility.look-me-up-setup` | `true` | Accessibility client setup profile. |
| `com.apple.private.webkit.pasteboard` | `true` | Pasteboard service client profile for direct CLI clipboard access. |
| `com.apple.private.pasteboard.check-pasteboard` | `true` | Pasteboard service checks. |
| `com.apple.Pasteboard.background-access` | `true` | Clipboard access without a foreground app. |
| `com.apple.Pasteboard.paste-unchecked` | `true` | CLI pasteboard access profile; receiving apps still have their own paste permission behavior. |
| `com.apple.backboard.displaybrightness` | `true` | Brightness access through BackBoard. |
| `com.apple.private.allow-explicit-graphics-priority` | `true` | Graphics client profile used for direct display capture. |
| `com.apple.private.IOSurface.protected-access` | `true` | IOSurface capture profile; protected-content capture is not an acceptance guarantee. |
| `com.apple.QuartzCore.displayable-context` | `true` | QuartzCore display context profile. |
| `com.apple.QuartzCore.global-capture` | `true` | Device display capture client profile. |
| `com.apple.QuartzCore.secure-mode` | `true` | QuartzCore capture profile; no protected-content guarantee. |
| `com.apple.security.iokit-user-client-class` | `IOHIDLibUserClient`, `IOHIDEventServiceFastPathUserClient`, `IOSurfaceRootUserClient`, `IOSurfaceAcceleratorClient`, `IOMobileFramebufferUserClient`, `AppleJPEGDriverUserClient`, `IOHIDUserDevice` | IOKit client class allowlist: HID input/events, IOSurface/display capture, image acceleration, and HID user devices. |

OCR uses Vision and the captured image; there is no separate OCR entitlement in this profile. A host's normal UIKit presentation, privacy strings, and user permission flows remain the host's responsibility.

## Services, logs, and system inspection

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.private.xpc.launchd.per-user-lookup` | `true` | Query services in the foreground user's launchd domain. |
| `com.apple.private.xpc.launchd.userspace-reboot` | `true` | Userspace reboot request capability; root is also required. |
| `com.apple.private.logging.stream` | `true` | Unified log streaming. |
| `com.apple.diagnosticd.stream` | `true` | Diagnostic service log stream access. |
| `com.apple.private.logging.diagnostic` | `true` | Diagnostic logging client profile. |
| `task_for_pid-allow` | `true` | Retained process inspection capability; current process listing uses sysctl/proc APIs rather than task_for_pid. |
| `proc_info-allow` | `true` | Process metadata/executable path inspection. |
| `com.apple.system-task-ports.read` | `true` | Retained system task inspection profile; no public task-port API is exposed by IcliKit. |
| `com.apple.private.kernel.get-kext-info` | `true` | Retained kernel inspection profile; current IORegistry traversal does not expose a kext query API. |
| `com.apple.private.network.statistics` | `true` | Retained network inspection profile; packet capture uses BPF and requires device access/root. |
| `com.apple.private.security.storage.DiagnosticReports.read-write` | `true` | Diagnostic report storage access; crash commands read reports. |
| `com.apple.CommCenter.fine-grained` | `spi`, `data-allowed-write` | CoreTelephony policy query SPI and per-app data-policy write capability. |

## Keychain

| Key | CLI value | Intended role |
| --- | --- | --- |
| `keychain-access-groups` | `icli.test` | Access group used for self-created test credentials. |
| `com.apple.keystore.access-keychain-keys` | `true` | Retained Keychain client capability; independent necessity is unverified. |
| `com.apple.private.security.system-keychain` | `true` | Retained system Keychain capability; acceptance only operates on fixture items in `icli.test`. |

The shipped CLI's access-group entitlement lists only `icli.test`. The library accepts a `group` argument and relies on the host's granted entitlements and system Keychain checks. A consumer's own identity/signing configuration does not automatically grant `icli.test`. Keep real credentials out of the acceptance fixture namespace and logs. This profile and test suite do not certify access to other apps' credentials.

## Verification and scope

`make all` signs the CLI with the authoritative file. `scripts/check-packages.sh` extracts the signed entitlements using `ldid -e`, compares the entire plist with that file, and verifies both DEB layouts contain the same executable. [The acceptance report](rootless-acceptance.md) identifies the tested binary and device; RootHide runtime remains unverified.

`scripts/check-entitlements.py` checks that this inventory includes every key and exact configured value, so additions or changes require a documentation update. A matching inventory is not proof that a platform will grant an entitlement or that an entry is individually required.
