// Whether a staged copy of the bundled WDA source is current for this app build.
// The stage records the app's CFBundleVersion in a marker file; it is re-staged
// when the app updates. Pure so the freshness rule is unit-testable.

import Foundation

public enum StageMarker {
    /// True only when `marker` is present and equals the current app build.
    public static func isCurrent(marker: String?, appBuild: String) -> Bool {
        marker == appBuild
    }
}
