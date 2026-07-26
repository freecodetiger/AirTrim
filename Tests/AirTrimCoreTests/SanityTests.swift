import Testing
@testable import AirTrimCore

@Test func versionIsSemver() {
    let parts = AirTrimCore.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
