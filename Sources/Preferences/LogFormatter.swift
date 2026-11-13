import Foundation
import MobileCoreServices

/// The filter values shown in the log viewer's segmented controls.
///
/// The first entry of each is the "no filter" option, which is why the indices
/// line up with the control's `selectedSegmentIndex`.
enum LogFilter {
    static let networkResponses = ["Any", "Success", "No Data", "Error"]
    static let endResults = ["Any", "Blocked", "Pushed"]

    /// Lines the pipeline writes as markers rather than content.
    ///
    /// "Pushed" says only that a request was handed to the transport, which the
    /// URL, headers and network response right below it already say in full. It
    /// stays in the stored log because the end-result filter reads it; it is
    /// skipped when the log is drawn.
    static let markers: Set<String> = ["Pushed"]

    /// A log line as it should be shown.
    ///
    /// Lines are written by the pipeline in English — that is what a bug report
    /// should quote, and what the log file holds — and translated here, at the
    /// point of drawing. Translating on the way in would put this device's language
    /// into a file that is meant to be readable anywhere, and would make every
    /// stored line wrong the moment somebody switches language.
    ///
    /// Only the label before the first colon is a message; everything after it is
    /// the user's own content — an app name, a body, a URL — and is passed through
    /// untouched.
    static func translated(_ line: String) -> String {
        // A line with no colon is looked up whole, which covers `Pushed` and
        // `Sent`. `Processing <bundle id>` is the one that carries a value and no
        // colon — the id is printed after a space, so the whole line never
        // matches. Its prefix is what is translated.
        guard line.contains(": ") else {
            let whole = line.localizedIfKnown()
            if whole != line { return whole }
            for (prefix, replacement) in prefixes where line.hasPrefix(prefix) {
                return replacement + line.dropFirst(prefix.count)
            }
            // A line whose value sits in brackets at the end: the action names are
            // translated, the words around them are part of the sentence.
            for (open, close) in bracketed {
                guard let start = line.range(of: open),
                      line.hasSuffix(close)
                else { continue }
                let head = String(line[..<start.lowerBound])
                let inside = String(line[start.upperBound..<line.index(line.endIndex, offsetBy: -close.count)])
                let translatedHead = head.localizedIfKnown()
                let translatedInside = inside.localizedIfKnown()
                guard translatedHead != head || translatedInside != inside else { continue }
                return (translatedHead == head ? head : translatedHead)
                    + open + (translatedInside == inside ? inside : translatedInside) + close
            }
            return line
        }

        // The longest prefix that has a translation wins.
        //
        // Not just the text before the first colon: `Network Response: Success` is
        // stored as one label and printed as `Network Response: Success: OK`, so
        // cutting at the first colon leaves `Success` — a word with no entry — as
        // an untranslated remainder. Trying the whole line first and shortening
        // finds the stored label wherever the colons happen to fall.
        let parts = line.components(separatedBy: ": ")
        for count in stride(from: parts.count, through: 1, by: -1) {
            let candidate = parts[0..<count].joined(separator: ": ")
            let translated = candidate.localizedIfKnown()
            guard translated != candidate else { continue }
            let rest = parts[count...].joined(separator: ": ")
            return rest.isEmpty ? translated : "\(translated): \(value(of: rest))"
        }
        return line
    }

    /// Prefixes that are translated even though they carry a value after a space.
    private static let prefixes: [(String, String)] = [
        ("Processing ", "处理 "),
    ]

    /// A trailing value in brackets, with the words before it a sentence.
    ///
    /// `Filtered by a rule (Hide and do not forward)` is one message with one
    /// translated part inside it, so neither the whole line nor the text before
    /// the bracket is a key.
    private static let bracketed: [(String, String)] = [
        (" (", ")"),
    ]

    /// Words that lead a value and are part of the sentence, not of the data.
    ///
    /// `slot 1` names a card slot; the number after it is the value. The stored
    /// line has to stay language-neutral, so the word is translated here rather
    /// than written translated.
    private static let valuePrefixes: [(String, String)] = [
        ("slot ", "卡槽 "),
    ]

    private static func value(of text: String) -> String {
        for (prefix, replacement) in valuePrefixes where text.hasPrefix(prefix) {
            return replacement + text.dropFirst(prefix.count)
        }
        return text
    }

    /// A stored log section with its marker lines removed, for display.
    static func visible(_ logs: [String]) -> [String] {
        logs.filter { !markers.contains($0.trimmingCharacters(in: .whitespaces)) }
    }

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
