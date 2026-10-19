import Foundation

/// Keeps secrets out of anything sent to a model (task 2.5). Two layers: files that hold
/// secrets are never read at all, and every other text has known secret shapes masked.
public enum Redactor {
    public static let mask = "[REDACTED]"

    /// Files never read into an evidence pack; only their path may be mentioned.
    public static func isSecretFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return !name.hasSuffix(".example") && !name.hasSuffix(".sample") }
        if ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", ".netrc", ".npmrc", ".pypirc", "credentials", ".htpasswd"].contains(name) { return true }
        return ["pem", "key", "p12", "pfx", "keystore", "jks", "mobileprovision", "p8"].contains((name as NSString).pathExtension)
    }

    /// Masked wholesale. Kept as strings: `Regex` isn't `Sendable`, so it can't be a stored static.
    private static let patterns: [String] = [
        // Private key blocks.
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        // Provider keys with known prefixes.
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b"#,
        #"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#,
        #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#,
        #"\bsk-(?:proj-)?[A-Za-z0-9_\-]{20,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,
        // JSON Web Tokens.
        #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
    ]

    /// scheme://user:password@host → scheme://[REDACTED]@host. (Swift regex has no lookbehind.)
    private static let urlCredentials = #"://[^/\s:@]+:[^/\s@]+@"#

    /// `password = "..."`, `API_KEY: ...`, `"client_secret": "..."`: the value is masked.
    private static let assignment =
        #"(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|auth)[A-Za-z0-9_\-]*["']?\s*[:=]\s*["']?)([^\s"',;]{6,})"#

    public static func redact(_ text: String) -> String {
        // try!: the patterns are constants, and one that fails to compile must fail the tests
        // rather than silently stop redacting (an unsupported lookbehind once did).
        var result = text
        for pattern in patterns {
            result = result.replacing(try! Regex(pattern), with: mask)
        }
        result = result.replacing(try! Regex(urlCredentials), with: "://\(mask)@")
        result = result.replacing(try! Regex(assignment)) { match in
            (match.output[1].substring ?? "") + mask
        }
        return result
    }
}
