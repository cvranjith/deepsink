//
//  BuildInfo.swift
//  DeepSink
//

import Foundation

// Which commit this running build came from, and when it was actually
// installed — shown on the Update App screen. Ported from yt-run's
// BuildInfo verbatim except for the key names: install_to_deepsink_device.sh
// stamps these straight into Info.plist as plain strings right before
// each build (see that script), since neither the app bundle's nor its
// container's filesystem dates survive install/repackaging intact.
enum BuildInfo {
    static var commitHash: String? {
        Bundle.main.infoDictionary?["DSBuildCommitHash"] as? String
    }

    static var commitDate: Date? {
        date(fromInfoKey: "DSBuildCommitDate")
    }

    static var installDate: Date? {
        date(fromInfoKey: "DSBuildInstallDate")
    }

    private static func date(fromInfoKey key: String) -> Date? {
        guard let string = Bundle.main.infoDictionary?[key] as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}
