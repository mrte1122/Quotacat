import Foundation

enum IconStyle: String, CaseIterable, Identifiable {
    case progressBar, battery, percentage, textOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .progressBar: return "Progress Bar"
        case .battery: return "Battery"
        case .percentage: return "Percentage"
        case .textOnly: return "Text Only"
        }
    }
}

enum SettingsKey {
    static let refreshInterval = "refreshInterval"        // seconds, 10...300
    static let iconStyle = "iconStyle"
    static let monochrome = "monochrome"
    static let showRemaining = "showRemaining"
    static let showLabels = "showLabels"
    static let showCountdown = "showCountdown"
    static let paceColoring = "paceColoring"
    static let showTimeMarker = "showTimeMarker"
    static let notificationsEnabled = "notificationsEnabled"
    static let actionsQuota = "actionsQuota"
    static let copilotQuota = "copilotQuota"
    static let preferPAT = "preferPAT"
    static let sentNotifications = "sentNotifications"
    static let autoUpdateCheck = "autoUpdateCheck"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let notifiedUpdateVersion = "notifiedUpdateVersion"

    static func menuBar(_ kind: MetricKind) -> String { "menuBar.\(kind.rawValue)" }

    static func registerDefaults() {
        var d: [String: Any] = [
            refreshInterval: 60.0,
            iconStyle: IconStyle.progressBar.rawValue,
            monochrome: false,
            showRemaining: false,
            showLabels: true,
            showCountdown: false,
            paceColoring: true,
            showTimeMarker: true,
            notificationsEnabled: true,
            actionsQuota: 2000.0,   // GitHub Free; Pro is 3000
            copilotQuota: 300.0,    // Copilot Pro; Free is 50, Pro+ is 1500
            preferPAT: false,
            autoUpdateCheck: true,
        ]
        for k in MetricKind.allCases {
            d[menuBar(k)] = (k == .core || k == .actions || k == .copilot)
        }
        UserDefaults.standard.register(defaults: d)
    }
}

enum Links {
    static let tip = URL(string: "https://ko-fi.com/mrte90")!
    static let repo = URL(string: "https://github.com/mrte1122/Quotacat")!
    static let billing = URL(string: "https://github.com/settings/billing")!
}
