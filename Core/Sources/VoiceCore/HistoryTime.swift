import Foundation

/// How History shows the time of a line: the wall clock it was spoken at, or the seconds
/// since the recording began.
public enum HistoryTimeMode: String, Sendable, CaseIterable, Identifiable {
    case clock
    case elapsed

    public var id: String { rawValue }

    /// The UserDefaults key the setting and History's toolbar share.
    public static let defaultsKey = "historyTimes"
    public static let standard = HistoryTimeMode.clock

    public var title: String {
        switch self {
        case .clock: "Clock time"
        case .elapsed: "Elapsed time"
        }
    }
}

/// Recording times as they were on the wall where the recording was made. A recording keeps
/// its start as an instant and the IANA zone it was made in; the zone is nil for rows from
/// before it was kept, which show in the zone the Mac is in now.
public enum HistoryTime {
    /// The recording's zone, or the current one when it is unknown or no longer exists.
    public static func zone(_ identifier: String?, current: TimeZone = .current) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? current
    }

    /// The time of a line `offset` seconds into a recording that began at `start`.
    public static func line(start: Date, offset: Double, zone identifier: String?, mode: HistoryTimeMode,
                            current: TimeZone = .current) -> String {
        switch mode {
        case .clock:
            wallClock(start.addingTimeInterval(offset.rounded(.down)), in: zone(identifier, current: current))
        case .elapsed:
            elapsed(offset)
        }
    }

    /// "Wed 12 Nov, 14:32": the start on the clock it was made on, in the person's language
    /// for the day and month and on a 24 hour clock.
    public static func title(start: Date, zone identifier: String?, current: TimeZone = .current,
                             locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone(identifier, current: current)
        formatter.dateFormat = "EEE d MMM"
        let day = formatter.string(from: start)
        return day + ", " + String(wallClock(start, in: formatter.timeZone).dropLast(3))
    }

    /// 21:20:04, on a 24 hour clock whatever the Mac's locale.
    public static func wallClock(_ instant: Date, in zone: TimeZone) -> String {
        let seconds = Int(instant.timeIntervalSince1970.rounded(.down)) + zone.secondsFromGMT(for: instant)
        let day = ((seconds % 86_400) + 86_400) % 86_400
        return String(format: "%02d:%02d:%02d", day / 3600, day / 60 % 60, day % 60)
    }

    /// 0:09 or 1:02:03.
    public static func elapsed(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Where the recording was made, such as "IST", only when its clock differs from the
    /// current zone's at that moment. Nil when the zone is unknown or reads the same.
    public static func originalZoneLabel(at instant: Date, zone identifier: String?,
                                         current: TimeZone = .current) -> String? {
        guard let identifier, let recorded = TimeZone(identifier: identifier),
              recorded.secondsFromGMT(for: instant) != current.secondsFromGMT(for: instant) else { return nil }
        return abbreviation(recorded, at: instant)
    }

    static func abbreviation(_ zone: TimeZone, at instant: Date) -> String {
        let name = zone.abbreviation(for: instant) ?? zone.identifier
        // Foundation only knows an abbreviation for the zones of the US and a few others and
        // gives "GMT+5:30" for the rest, which these readers know by name.
        guard name.hasPrefix("GMT"), name.count > 3 else { return name }
        let fixed = ["Asia/Kolkata": "IST", "Asia/Calcutta": "IST", "Asia/Tokyo": "JST", "Asia/Seoul": "KST",
                     "Asia/Singapore": "SGT"]
        if let short = fixed[zone.identifier] { return short }
        let central: Set = ["Amsterdam", "Berlin", "Brussels", "Copenhagen", "Madrid", "Oslo", "Paris", "Prague",
                            "Rome", "Stockholm", "Vienna", "Warsaw", "Zurich"]
        if zone.identifier.hasPrefix("Europe/"), central.contains(String(zone.identifier.dropFirst(7))) {
            return zone.isDaylightSavingTime(for: instant) ? "CEST" : "CET"
        }
        return name
    }

    /// A file name for a saved recording: its start on the clock it was made on, then what it
    /// is. No colons, which Finder shows as slashes.
    public static func fileName(start: Date, zone identifier: String?, kind: HistoryEntry.Kind,
                                current: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone(identifier, current: current)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start)
        return String(format: "%04d-%02d-%02d %02d.%02d.%02d %@", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, kind == .call ? "Call" : "Dictation")
    }
}

extension HistoryEntry {
    /// The clock the entry was recorded on: its own zone, or the current one when unknown.
    public var zone: TimeZone { HistoryTime.zone(timeZone) }

    /// "IST" when it was recorded on a different clock than this Mac's now; nil otherwise.
    public var originalZoneLabel: String? { HistoryTime.originalZoneLabel(at: at, zone: timeZone) }

    /// The recording, when its file is still there to save.
    public var audioFile: URL? {
        audioPath.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// What Save As offers: the start on the clock it was made on and what it is, in the
    /// format the recording is stored in (m4a for a finished call, wav for a dictation).
    public var suggestedAudioName: String? {
        audioFile.map {
            HistoryTime.fileName(start: at, zone: timeZone, kind: kind) + "." + $0.pathExtension.lowercased()
        }
    }

    /// Copies the stored recording as it is, replacing what the destination holds (the save
    /// panel has already asked about that).
    public func saveAudio(to destination: URL) throws {
        guard let source = audioFile else { throw VoiceError.audio("The recording is gone.") }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: try stagedCopy(of: source, beside: destination))
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    /// A copy next to the destination, so replacing it is one rename and a failed copy
    /// leaves the old file alone.
    private func stagedCopy(of source: URL, beside destination: URL) throws -> URL {
        let staged = destination.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).\(destination.pathExtension)")
        try FileManager.default.copyItem(at: source, to: staged)
        return staged
    }
}
