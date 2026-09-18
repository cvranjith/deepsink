//
//  ProvisioningProfile.swift
//  DeepSink
//

import Foundation

// Ported from yt-run verbatim — a personal (free Apple Developer
// account) install expires (7 days typically), silently turning into an
// app that just won't launch until reinstalled. This reads that
// expiration date straight out of the app's own embedded provisioning
// profile, so a view can show a reminder before that happens.
enum ProvisioningProfile {
    static let expirationDate: Date? = readExpirationDate()

    private static func readExpirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        guard let start = content.range(of: "<?xml"),
              let end = content.range(of: "</plist>") else {
            return nil
        }
        let plistString = content[start.lowerBound..<end.upperBound]
        guard let plistData = String(plistString).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["ExpirationDate"] as? Date
    }

    static func daysRemaining(from now: Date = Date()) -> Int? {
        guard let expirationDate else { return nil }
        let seconds = expirationDate.timeIntervalSince(now)
        return Int((seconds / 86400).rounded(.up))
    }
}
