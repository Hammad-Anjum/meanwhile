import Foundation
import MeanwhileIPC

public enum Meanwhile {
    /// The version for local builds. The release workflow rewrites it from the tag
    /// (scripts/set-version.sh: `v0.2.0` → `0.2.0`) before building.
    public static let version = "0.1.0"

    /// The GitHub repo releases come from (`meanwhile update`, install.sh).
    /// The one place to change if the repo moves (install.sh has its own REPOSITORY line).
    public static let repository = "Hammad-Anjum/meanwhile"
}
