import Testing
@testable import MeanwhileCore

@Test func versionIsSet() {
    #expect(!Meanwhile.version.isEmpty)
}
