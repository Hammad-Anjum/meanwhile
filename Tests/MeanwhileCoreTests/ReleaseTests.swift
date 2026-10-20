import Foundation
@testable import MeanwhileCore
import Testing

@Test func parsesVersionsAndTags() throws {
    let version = try #require(SemanticVersion("v0.2.10"))
    #expect(version.major == 0 && version.minor == 2 && version.patch == 10 && version.prerelease == nil)
    #expect(SemanticVersion("1.0.0-beta.2")?.prerelease == "beta.2")
    #expect(SemanticVersion(Meanwhile.version) != nil)
    for bad in ["", "1.2", "1.2.3.4", "v1.x.0", "1..0", "1.2.3-", "latest", "１.2.3"] {
        #expect(SemanticVersion(bad) == nil, "\(bad)")
    }
}

@Test func comparesVersions() throws {
    func v(_ text: String) throws -> SemanticVersion { try #require(SemanticVersion(text)) }
    #expect(try v("0.1.0") < v("0.2.0"))
    #expect(try v("0.9.0") < v("0.10.0"))
    #expect(try v("1.2.3") < v("2.0.0"))
    #expect(try v("0.2.0-beta") < v("0.2.0"))
    #expect(try v("0.2.0-beta.2") < v("0.2.0-beta.10"))
    #expect(try v("v0.2.0") == v("0.2.0"))
    #expect(try !(v("0.2.0") < v("0.2.0")))
}

@Test func buildsAssetURLs() throws {
    let version = try #require(SemanticVersion("v0.2.0"))
    let github = ReleaseSource(repository: "someone/meanwhile")
    #expect(github.latestURL.absoluteString == "https://api.github.com/repos/someone/meanwhile/releases/latest")
    #expect(github.tarballURL(version).absoluteString
        == "https://github.com/someone/meanwhile/releases/download/v0.2.0/meanwhile-0.2.0-macos.tar.gz")
    #expect(github.checksumsURL(version).absoluteString
        == "https://github.com/someone/meanwhile/releases/download/v0.2.0/SHA256SUMS")
    #expect(ReleaseSource.folderName(version) == "meanwhile-0.2.0-macos")

    let local = ReleaseSource(environment: ["MEANWHILE_BASE_URL": "http://127.0.0.1:8000/releases"])
    #expect(local.latestURL.absoluteString == "http://127.0.0.1:8000/releases/latest")
    #expect(local.tarballURL(version).absoluteString == "http://127.0.0.1:8000/releases/v0.2.0/meanwhile-0.2.0-macos.tar.gz")
    #expect(ReleaseSource(environment: ["MEANWHILE_BASE_URL": ""]).baseURL == nil)
}

@Test func readsLatestRelease() throws {
    let json = Data(#"{"tag_name": "v1.4.0", "name": "Meanwhile 1.4.0", "assets": []}"#.utf8)
    #expect(try ReleaseSource.latestVersion(fromJSON: json).description == "1.4.0")
    #expect(throws: ReleaseError.badTag("nightly")) {
        try ReleaseSource.latestVersion(fromJSON: Data(#"{"tag_name": "nightly"}"#.utf8))
    }
    #expect(throws: ReleaseError.unreadableLatest) {
        try ReleaseSource.latestVersion(fromJSON: Data(#"{"message": "Not Found"}"#.utf8))
    }
}

@Test func verifiesChecksums() throws {
    let tarball = Data("pretend tarball".utf8)
    let hash = Checksums.sha256(tarball)
    #expect(hash.count == 64)
    #expect(Checksums.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

    let sums = Checksums("\(hash)  meanwhile-0.2.0-macos.tar.gz\n\(String(repeating: "A", count: 64)) *other.bin\nnot a line\n")
    #expect(sums.byName["other.bin"] == String(repeating: "a", count: 64))
    try sums.verify(tarball, name: "meanwhile-0.2.0-macos.tar.gz")
    #expect(throws: ReleaseError.self) { try sums.verify(Data("tampered".utf8), name: "meanwhile-0.2.0-macos.tar.gz") }
    #expect(throws: ReleaseError.missingChecksum("missing.tar.gz")) { try sums.verify(tarball, name: "missing.tar.gz") }
}
