import XCTest
@testable import MyMan

final class KeychainTests: XCTestCase {
    private let service = "com.muckstack.myman.tests.keychain"
    private let account = "api-key"

    override func tearDown() {
        Keychain.delete(service: service, account: account)
    }

    func testRoundTripUpdateAndDelete() throws {
        Keychain.delete(service: service, account: account)
        XCTAssertNil(Keychain.read(service: service, account: account))
        do {
            try Keychain.save("first-value", service: service, account: account)
        } catch let error as Keychain.SaveFailed where error.status == errSecNotAvailable || error.status == errSecInteractionNotAllowed {
            throw XCTSkip("Keychain unavailable in this environment (\(error.status))")
        }
        XCTAssertEqual(Keychain.read(service: service, account: account), "first-value")
        try Keychain.save("second-value", service: service, account: account)
        XCTAssertEqual(Keychain.read(service: service, account: account), "second-value")
        Keychain.delete(service: service, account: account)
        XCTAssertNil(Keychain.read(service: service, account: account))
    }

    func testVendorServicesAreDistinct() {
        XCTAssertNotEqual(WritingVendor.claude.keychainService, WritingVendor.openai.keychainService)
        XCTAssertEqual(WritingVendor.keychainAccount, "api-key")
    }
}
