# Third-Party Notices

Swift Package Manager resolves Swift Argument Parser 1.3.1 from
https://github.com/apple/swift-argument-parser. Its Apache-2.0 license with
Swift Runtime Library Exception is preserved in
`Resources/Licenses/swift-argument-parser.txt`.

The LibArchive 0.1.1 Swift package is resolved from
https://github.com/Lakr233/libarchive.xcframework. Its static XCFramework is
linked into icli; no separate libarchive executable or dynamic framework is
shipped. The package's MIT license and notices for libarchive, xz, zstd, and
lz4 are preserved in `Resources/Licenses/libarchive.txt`.

The AX numeric attribute mapping, HID protocol references and unified-log API
integration were informed by witchan/ios-mcp, commit
8f46b68ae6d9cb783cfa55d7a38e6b0afeccf5dd (MIT).
The copyright and license are preserved in `Resources/Licenses/ios-mcp.txt`.
Source: https://github.com/witchan/ios-mcp

Runtime bootstrap API contracts are documented by opa334/libroot and
roothide/libroothide. icli resolves device-provided implementations at runtime.
OCR uses Apple's system Vision framework.

The project license and these dependency notices are included in both DEB packages.
