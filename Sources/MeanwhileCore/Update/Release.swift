import CryptoKit
import Foundation

/// A release version, `MAJOR.MINOR.PATCH` with an optional `-prerelease` suffix.
/// Tags carry a leading `v` (`v0.2.0`); it is accepted and dropped.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2])
        else { return nil }
        if parts.count == 2 && parts[1].isEmpty { return nil }
        (self.major, self.minor, self.patch) = (major, minor, patch)
        prerelease = parts.count == 2 ? String(parts[1]) : nil
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    /// A prerelease sorts before its release (`0.2.0-beta < 0.2.0`).
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }
}

/// Where a release's files are and how to check them. The release workflow
/// (.github/workflows/release.yml) and install.sh use the same names.
public struct ReleaseSource: Sendable {
    /// Replaces `https://github.com/<repository>/releases/download` for testing. Files are then
    /// at `<base>/v<version>/<file>`, and the latest release is read from `<base>/latest`.
    public static let baseURLVariable = "MEANWHILE_BASE_URL"

    public let repository: String
    public let baseURL: URL?

    public init(repository: String = Meanwhile.repository, baseURL: URL? = nil) {
        self.repository = repository
        self.baseURL = baseURL
    }

    public init(environment: [String: String], repository: String = Meanwhile.repository) {
        let base = environment[Self.baseURLVariable].flatMap { $0.isEmpty ? nil : URL(string: $0) }
        self.init(repository: repository, baseURL: base)
    }

    /// GitHub's "latest release" endpoint, or `<base>/latest` (same JSON shape) when overridden.
    public var latestURL: URL {
        baseURL?.appendingPathComponent("latest")
            ?? URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public static func tarballName(_ version: SemanticVersion) -> String { "meanwhile-\(version)-macos.tar.gz" }
    public static let checksumsName = "SHA256SUMS"

    /// The folder at the top of the tarball.
    public static func folderName(_ version: SemanticVersion) -> String { "meanwhile-\(version)-macos" }

    public func tarballURL(_ version: SemanticVersion) -> URL { downloadDirectory(version).appendingPathComponent(Self.tarballName(version)) }
    public func checksumsURL(_ version: SemanticVersion) -> URL { downloadDirectory(version).appendingPathComponent(Self.checksumsName) }

    private func downloadDirectory(_ version: SemanticVersion) -> URL {
        (baseURL ?? URL(string: "https://github.com/\(repository)/releases/download")!)
            .appendingPathComponent("v\(version)")
    }

    /// The version in a `releases/latest` response (`{"tag_name": "v0.2.0", ...}`).
    public static func latestVersion(fromJSON data: Data) throws -> SemanticVersion {
        struct Latest: Decodable { let tag_name: String }
        let tag: String
        do { tag = try JSONDecoder().decode(Latest.self, from: data).tag_name } catch {
            throw ReleaseError.unreadableLatest
        }
        guard let version = SemanticVersion(tag) else { throw ReleaseError.badTag(tag) }
        return version
    }
}

public enum ReleaseError: Error, CustomStringConvertible, Equatable {
    case unreadableLatest
    case badTag(String)
    case missingChecksum(String)
    case checksumMismatch(file: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .unreadableLatest: "Couldn't read the latest release from GitHub."
        case let .badTag(tag): "The latest release tag '\(tag)' isn't a version like v1.2.3."
        case let .missingChecksum(file): "SHA256SUMS has no line for \(file)."
        case let .checksumMismatch(file, expected, actual):
            "\(file) is damaged or was changed: SHA-256 is \(actual), expected \(expected)."
        }
    }
}

/// The `SHA256SUMS` file written by `shasum -a 256`: `<hex>  <name>` per line
/// (`<hex> *<name>` in binary mode).
public struct Checksums: Sendable {
    public let byName: [String: String]

    public init(_ text: String) {
        var byName: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[0].count == 64, fields[0].allSatisfy(\.isHexDigit) else { continue }
            var name = fields[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            byName[name] = fields[0].lowercased()
        }
        self.byName = byName
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Throws unless `data` matches the line for `name`.
    public func verify(_ data: Data, name: String) throws {
        guard let expected = byName[name] else { throw ReleaseError.missingChecksum(name) }
        let actual = Self.sha256(data)
        guard actual == expected else { throw ReleaseError.checksumMismatch(file: name, expected: expected, actual: actual) }
    }
}
