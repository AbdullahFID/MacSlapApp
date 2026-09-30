import Testing
@testable import SlapCore

@Suite("VersionComparison")
struct VersionComparisonTests {
    @Test("Parses tags with prefixes and suffixes")
    func parsing() {
        #expect(VersionComparison.components("v2.00") == [2, 0])
        #expect(VersionComparison.components("3.0.0") == [3, 0, 0])
        #expect(VersionComparison.components("V3.1-beta.2") == [3, 1])
        #expect(VersionComparison.components("dev") == nil)
        #expect(VersionComparison.components("") == nil)
        #expect(VersionComparison.components("3..1") == nil)
    }

    @Test("Newer versions win, equal and garbage don't")
    func ordering() {
        #expect(VersionComparison.isNewer("v3.0.0", than: "2.00"))
        #expect(VersionComparison.isNewer("3.0.1", than: "3.0.0"))
        #expect(VersionComparison.isNewer("v3.10", than: "3.9.9"))
        #expect(!VersionComparison.isNewer("v2.00", than: "3.0.0"))
        #expect(!VersionComparison.isNewer("3.0", than: "3.0.0"))
        #expect(!VersionComparison.isNewer("v3.0.0", than: "dev"))
        #expect(!VersionComparison.isNewer("latest", than: "3.0.0"))
    }
}
