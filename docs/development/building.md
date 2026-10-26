# Build from Source

Requires macOS with Xcode and its iPhoneOS SDK, Swift, Clang, Make, `ldid`, `dpkg-deb`, and Python 3. Make these tools available on your `PATH`.

```sh
git clone https://github.com/owngoal-dev/icli.git
cd icli
make all CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
make deb-rootless
make deb-roothide
make tvos
./scripts/check-packages.sh
```

Swift Package Manager resolves Argument Parser and the static [ArchiveKit package](https://github.com/Lakr233/libarchive.xcframework) using the versions pinned in `Package.resolved`. Dependency checkouts and binary artifacts stay under `.build/swiftpm/`; no library sources or headers are vendored. Use `make resolve` after changing dependency versions.

| Output | Location |
| --- | --- |
| Signed executable | `.build/icli` |
| Rootless package | `.build/com.icli.icli_<version>_iphoneos-arm64.deb` |
| Experimental RootHide package | `.build/com.icli.icli_<version>_iphoneos-arm64e.deb` |
| Signed tvOS executable | `.build/icli-tvos` |
| tvOS package | `.build/com.icli.icli_<version>_appletvos-arm64.deb` |
| Package verification report | `.build/package-verification.json` |

The version comes from `Resources/Info.plist`. `make deb` builds the rootless package. Every build checks for forbidden process-launch imports. Package checks repeat that check and verify architecture, deployment target, entitlements, system-only linked libraries, a firmware-only DEB dependency, ownership, and identical executable contents across the two iOS layouts and in the tvOS package. `check-packages.sh` needs both `make all` and `make tvos` first. Import checks detect direct linked calls; runtime acceptance also checks the environment report.

The **DEB Release** GitHub Actions workflow builds both iOS layouts and the tvOS package and publishes the DEBs, `icli-tvos`, `SHA256SUMS`, and `package-verification.json`. It runs for version tags or can be dispatched with an existing tag. CI artifacts have their own hashes and package checks; device acceptance applies to the specific binary recorded in its report. Repository changes use ordinary incremental commits; published version tags remain fixed.

`make` runs the SwiftPM iOS build, copies the executable to `.build/icli`, and signs it with `ldid` using the repository's entitlements. `make tvos` does the same for tvOS; the AppleTVOS SDK has no IOKit.framework, so `scripts/tvos-iokit-stub.sh` first borrows the iPhoneOS SDK's IOKit headers and stub, retargeted to tvOS, into `.build/tvos-stubs`. It does not require an Apple development certificate. To compile without signing, use `swift build -c release --triple arm64-apple-ios15.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --scratch-path .build/swiftpm --product icli --force-resolved-versions`.
