import Foundation
import MobileCoreServices

/// The filter values shown in the log viewer's segmented controls.
///
/// The first entry of each is the "no filter" option, which is why the indices
/// line up with the control's `selectedSegmentIndex`.
enum LogFilter {
    static let networkResponses = ["Any", "Success", "No Data", "Error"]
    static let endResults = ["Any", "Blocked", "Pushed"]

    static func networkResponse(at index: Int) -> String? {
        guard index > 0, index < networkResponses.count else { return nil }
        return networkResponses[index]
    }

    static func endResult(at index: Int) -> String? {
        guard index > 0, index < endResults.count else { return nil }
        return endResults[index]
    }
}

/// Formatting and filtering for the log viewer.
///
/// Kept apart from the controller so the display logic can be reasoned about
/// without a table view: given a stored log section, what is its title, and does
/// it survive the current filters.
enum LogFormatter {
    /// A display title for one stored log section: the app's name, the
    /// timestamp, and the service prefix when the section came from the combined
    /// (all-services) view.
    static func sectionTitle(forSection section: Prefs) -> String {
        var name = section.string("name")
        if name == nil {
            let appID = section.string("appID")
            var appName = "Unknown App".localized
            if let appID {
                appName = LSApplicationProxy.applicationProxy(forIdentifier: appID)?.localizedName
                    ?? appName
            }

            if let timestamp = section["timestamp"] as? Date {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .medium
                name = "\(appName): \(formatter.string(from: timestamp))"
            } else {
                name = "\(appName): \(section["timestamp"] ?? "")"
            }
        }

        guard let service = section.string("service") else { return name ?? "" }
        if service.isEmpty {
            return String(format: "{GLOBAL} %@".localized, name ?? "")
        }
        return String(format: "[%@] %@".localized, Localization.serviceDisplayName(service), name ?? "")
    }

    /// Whether a section's log lines pass the network-response and end-result
    /// filters.
    ///
    /// The end-result filter matches the literal "Pushed"/"Blocked" markers the
    /// pipeline writes, so a section that never got that far is excluded.
    static func shouldInclude(
        logs: [String],
        networkResponse: String?,
        endResult: String?
    ) -> Bool {
        if let networkResponse {
            let marker = "Network Response: \(networkResponse)"
            guard logs.contains(where: { $0.contains(marker) }) else { return false }
        }

        if let endResult {
            // "Pushed" is a marker line of its own; "Blocked" is implied by the
            // absence of one, which is why only that case compares literally.
            let shouldContainPushed = endResult == LogFilter.endResults[2]
            let containsPushed = logs.contains(LogFilter.endResults[2])
            guard shouldContainPushed == containsPushed else { return false }
        }
        return true
    }
}
