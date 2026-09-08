import ArgumentParser
import IcliKit

struct Tests: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Run self-tests on this device; report failures and untested capabilities",
        discussion: "Uses temporary files and a dedicated Keychain item. Unlock the device for screen tests. Supply the signed SelfTestFixture.app to test app registration. Does not reboot or change device settings."
    )
    @OptionGroup var output: OutputOptions
    @Option(help: "Require this bootstrap layout: rootless, roothide, or rootful") var expectLayout: String?
    @Option(help: "Path to the signed SelfTestFixture.app from scripts/build-install-fixtures.sh") var registrationFixture: String?

    func validate() throws {
        if let expectLayout, !["rootless", "roothide", "rootful"].contains(expectLayout) {
            throw ValidationError("Expected layout must be rootless, roothide, or rootful.")
        }
    }

    func run() {
        emit(allowWhenLocked: true, output) {
            try runSelfTests(expectedLayout: expectLayout, registrationFixture: registrationFixture)
        }
    }
}
