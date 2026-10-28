# Passcode Unlock Design

`icli device passcode unlock` lets test automation, including AI agents, unlock a passcode-protected device with a passcode a person supplied. The constraints, in order of priority:

1. **Never lock the device out.** iOS delays passcode entry from the fifth consecutive failure (1 min, 5 min, 15 min, 1 h…) and can disable or wipe the device after ten. A caller that loops on a wrong passcode must not reach that.
2. **No brute force.** icli only forwards a passcode it was given. It has no option to generate, iterate or vary one.
3. **The passcode stays out of argv, logs and disk.** It is read from stdin, a private file or a no-echo terminal prompt, and wiped from memory after the attempt. Only digests of *wrong* passcodes are stored.
4. **Tell the caller what happened and what is left.** Every answer carries `result`, `attempts_remaining` and a `hint` an agent can act on, and a distinct exit status.

## Commands

| Command | Does |
| --- | --- |
| `device passcode status` | Keybag `lock_state`, `failed_attempts`, `backoff_seconds`, `permanently_blocked`, the ledger count, `attempts_remaining`, and SpringBoard's `lock_screen`. Also `api('passcode.status')` in `icli probe`. |
| `device passcode unlock` | `--passcode-stdin`, `--passcode-file <path>`, or a TTY prompt. `--max-failures N` (1–4, default 3). `--check` runs every guard and stops before the attempt. |
| `device passcode forget --force` | Empties the ledger, even an unreadable one. Needed after the device passcode changes. |

`result` is `unlocked`, `check_passed`, `rejected`, `rejected_cached`, `refused` or `system_error`. Exit status: 0 unlocked (or already unlocked, or `--check` passed), 3 rejected now, 4 rejected before and not retried, 5 refused by a guard, 6 keybag error that did not count.

## Flow

```
read passcode (stdin | 0600 file | TTY)      argv never
  └─ flock ledger  ── concurrent icli runs take turns
       ├─ keybag already unlocked / no passcode → 0, no attempt
       ├─ digest in ledger                      → 4, no attempt   (fast reject)
       ├─ keybag backing off / blocked          → 5, no attempt
       ├─ max(ledger, keybag counter) ≥ limit   → 5, no attempt
       ├─ --check                               → 0, no attempt
       └─ MKBUnlockDevice
            ├─ 0                         → clear ledger, 0
            ├─ counter rose / unreadable → record digest, 3
            └─ counter unchanged         → 6, not recorded (e.g. missing entitlement)
```

## The ledger

`/var/mobile/Library/Caches/com.icli.icli/passcode-ledger.json`, 0600 in a 0700 directory, owned by mobile even when root wrote it, so `sudo icli` and `icli` share one budget.

```json
{"version":1,"iterations":200000,"salt":"<16 random bytes>","rejected":[{"digest":"<PBKDF2-HMAC-SHA256>","at":1793000000}]}
```

- **Fast reject.** The same wrong passcode costs at most one real attempt, however many times an agent retries it.
- **Local budget.** The number of digests is a failure count that survives a keybag counter icli cannot read. The guard uses the larger of the two.
- **Salted and slow.** A per-ledger random salt and 200 000 PBKDF2 rounds. A 4–6 digit passcode can still be recovered offline by someone who can read the file, which is why it is private and holds only wrong passcodes, and is emptied on success.
- **Fails closed.** An unparsable ledger blocks attempts until `forget --force`.
- **Uncounted errors are not recorded.** If the keybag's counter is readable and did not rise, the failure was not about the passcode (no entitlement, keybag busy), so the passcode stays eligible. If the counter is unreadable, the failure is recorded anyway: holding back a correct passcode costs a `forget`, retrying a wrong one costs device lockout time.
- **Stale after a passcode change.** A passcode recorded as wrong may become right. icli cannot detect the change, so the caller runs `forget --force`; the `hint` on a fast reject says so.

## Keybag SPI

From `MobileKeyBag.framework`, all resolved with `dlsym`:

| Symbol | Use |
| --- | --- |
| `MKBGetDeviceLockState(NULL)` | 0 unlocked, 2 locked with the screen off (seen on iOS 17.3.1 two seconds after `button power`), 3 no passcode; 1 is the other locked value. Anything but 0 and 3 is treated as locked. |
| `MKBGetDeviceLockStateInfo(NULL)` | Dictionary keyed by `kMKBInfoFailedAttempts` (`fa`), `kMKBInfoBackOff` (`boff`), `kMKBInfoPermanentlyBlocked` (`pb`), `kMKBInfoShouldWipe` (`sw`), `kMKBInfoRecoveryCountdown` (`countdown`), `kMKBInfoLockState` (`ls`). Key names read on macOS 27; an unsigned macOS tool reads `{boff=0, fa=0, ls=0, state=…}`. |
| `MKBUnlockDevice(CFDataRef passcode, NULL)` | The attempt. 0 is success; a wrong passcode returned -3 on iOS 17.3.1. |

`MKBVerifyPasswordWithContext` exists but is not used: it would also spend an attempt, and verifying without unlocking adds nothing here.

## Entitlement

`com.apple.keystore.device` is added to `Resources/icli.entitlements`. Evidence from an iOS 27.0.1 vphone, by grepping signed entitlements and imports of system binaries:

| Binary | keystore entitlements | MKB imports |
| --- | --- | --- |
| SpringBoard | `keystore.device`, `keystore.device.verify`, `keystore.lockassertion`, `keystore.stash.access`, `keystore.bak`, `mkb.usersession.*` | (through its frameworks) |
| `/usr/libexec/demod` | `keystore.device`, `keystore.lockassertion` | `MKBUnlockDeviceWithACM`, `MKBGetDeviceLockState`, `MKBDeviceLockAssertion` |
| `/usr/libexec/sharingd` | `keystore.device`, `keystore.device.remote-session`, `keystore.device.uuid`, `keystore.lockassertion`, … | — |

demod is the narrowest caller that unlocks, and it holds only `keystore.device` and `keystore.lockassertion`, so `keystore.device` is the candidate. `keystore.device.verify` (SpringBoard only) likely gates the verify-only call and is not added.

## Device results

Run on 2026-10-28 on a physical iPhone 15 Pro (`iPhone16,1`), iOS 17.3.1 `21D61`, RootHide, as mobile, with the signed release build of this branch:

| Step | Result |
| --- | --- |
| `status` and `api('passcode.status')`, unlocked | `lock_state` 0, `failed_attempts` 0, `backoff_seconds` 0 |
| `--passcode-file` at 0644 | refused before reading |
| `unlock` while unlocked | `already_unlocked`, no attempt |
| `button power`, then `status` | `lock_state` 2 within 2 s, `lock_screen.locked` true |
| wrong passcode | attempted, `keybag_result` -3, `failed_attempts` 0 → 1, recorded, exit status 3 |
| same wrong passcode again | `rejected_cached`, not attempted, `failed_attempts` stays 1 |
| right passcode with `--check` | `check_passed`, not attempted |
| right passcode | `keybag_result` 0, `lock_state` 0, `failed_attempts` back to 0, ledger empty |
| `button wake`, `button home` | the keybag stays unlocked, but SpringBoard's lock screen stays up |

So `com.apple.keystore.device` is enough for mobile to unlock, and the counter-based classification works.

## Open

- Dismissing SpringBoard's lock screen after a keybag unlock: `button home` does not, on a Face ID iPhone. A later `--dismiss` could swipe up or ask SpringBoard directly.
- The uncounted-error path (exit status 6) was not provoked; it needs a build without the entitlement.
- iOS 26 and 27, root, and tvOS are untested. Whether `MKBGetDeviceLockStateInfo` follows the Create rule is unknown, so its result is never released.
