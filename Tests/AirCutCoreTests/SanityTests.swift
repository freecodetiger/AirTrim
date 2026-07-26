import Testing
@testable import AirCutCore

@Test func versionIsSemver() {
    let parts = AirCutCore.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
