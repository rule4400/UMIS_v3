import Foundation
import ImageIO

struct MediaCaptureDateResolution: Hashable, Sendable {
    let date: Date
    let source: MediaCaptureDateSource
    let assumedTimeZoneIdentifier: String?
}

/// Metadata-only capture-date extraction shared by the ImageIO and AVFoundation
/// adapters. Parsing is deliberately strict: a malformed embedded value is never
/// silently normalized into a different date.
enum MediaCaptureDateExtractor {
    static func image(
        properties: [CFString: Any],
        assumedTimeZone: TimeZone
    ) -> MediaCaptureDateResolution? {
        let exif = dictionary(properties[kCGImagePropertyExifDictionary])
        if let original = string(exif?[kCGImagePropertyExifDateTimeOriginal]) {
            let offset = string(exif?[kCGImagePropertyExifOffsetTimeOriginal])
            if let parsed = parseCameraWallClock(
                original,
                explicitOffset: offset,
                assumedTimeZone: assumedTimeZone
            ) {
                return MediaCaptureDateResolution(
                    date: parsed.date,
                    source: .imageIOExifDateTimeOriginal,
                    assumedTimeZoneIdentifier: parsed.usedAssumedTimeZone
                        ? assumedTimeZone.identifier
                        : nil
                )
            }
        }

        let tiff = dictionary(properties[kCGImagePropertyTIFFDictionary])
        if let original = string(tiff?[kCGImagePropertyTIFFDateTime]),
           let parsed = parseCameraWallClock(
               original,
               explicitOffset: nil,
               assumedTimeZone: assumedTimeZone
           ) {
            return MediaCaptureDateResolution(
                date: parsed.date,
                source: .imageIOTIFFDateTime,
                assumedTimeZoneIdentifier: assumedTimeZone.identifier
            )
        }
        return nil
    }

    static func quickTime(
        dateValue: Date?,
        stringValue: String?,
        assumedTimeZone: TimeZone
    ) -> MediaCaptureDateResolution? {
        // Prefer the original text when AVFoundation exposes both representations:
        // `dateValue` may already have applied an undocumented default zone to a
        // zone-less QuickTime string, while the caller's frozen policy must win.
        if let stringValue {
            if let absolute = parseISO8601Absolute(stringValue) {
                return MediaCaptureDateResolution(
                    date: absolute,
                    source: .quickTimeCreationDate,
                    assumedTimeZoneIdentifier: nil
                )
            }
            if let wallClock = parseISOWallClock(stringValue, timeZone: assumedTimeZone) {
                return MediaCaptureDateResolution(
                    date: wallClock,
                    source: .quickTimeCreationDate,
                    assumedTimeZoneIdentifier: assumedTimeZone.identifier
                )
            }
        }
        guard let dateValue else { return nil }
        return MediaCaptureDateResolution(
            date: dateValue,
            source: .quickTimeCreationDate,
            assumedTimeZoneIdentifier: nil
        )
    }

    static func fileModificationDate(for url: URL) -> MediaCaptureDateResolution? {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else {
            return nil
        }
        return MediaCaptureDateResolution(
            date: date,
            source: .fileModificationDate,
            assumedTimeZoneIdentifier: nil
        )
    }

    private static func parseCameraWallClock(
        _ value: String,
        explicitOffset: String?,
        assumedTimeZone: TimeZone
    ) -> (date: Date, usedAssumedTimeZone: Bool)? {
        let timeZone: TimeZone
        let usedAssumedTimeZone: Bool
        if let explicitOffset,
           !explicitOffset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsedOffset = parseOffset(explicitOffset) else { return nil }
            timeZone = parsedOffset
            usedAssumedTimeZone = false
        } else {
            timeZone = assumedTimeZone
            usedAssumedTimeZone = true
        }
        guard let components = cameraComponents(value),
              let date = strictDate(from: components, timeZone: timeZone) else {
            return nil
        }
        return (date, usedAssumedTimeZone)
    }

    private static func cameraComponents(_ rawValue: String) -> DateComponents? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count == 19 else { return nil }
        let bytes = Array(value.utf8)
        guard bytes[4] == 58, bytes[7] == 58, bytes[10] == 32,
              bytes[13] == 58, bytes[16] == 58,
              let year = decimal(bytes, 0..<4),
              let month = decimal(bytes, 5..<7),
              let day = decimal(bytes, 8..<10),
              let hour = decimal(bytes, 11..<13),
              let minute = decimal(bytes, 14..<16),
              let second = decimal(bytes, 17..<19) else {
            return nil
        }
        return DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
    }

    private static func parseISO8601Absolute(_ rawValue: String) -> Date? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 128, hasExplicitISOOffset(value) else { return nil }
        if let range = value.range(
            of: #"[+-][0-9]{4}$"#,
            options: .regularExpression
        ) {
            let compact = value[range]
            value.replaceSubrange(
                range,
                with: String(compact.prefix(3)) + ":" + String(compact.suffix(2))
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func parseISOWallClock(_ rawValue: String, timeZone: TimeZone) -> Date? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 128, !hasExplicitISOOffset(trimmed) else { return nil }
        let value = String(trimmed.prefix(19))
        let suffix = trimmed.dropFirst(19)
        let validFraction = suffix.first == "."
            && !suffix.dropFirst().isEmpty
            && suffix.dropFirst().allSatisfy(\.isNumber)
        guard suffix.isEmpty || validFraction,
              value.utf8.count == 19 else {
            return nil
        }
        let bytes = Array(value.utf8)
        guard bytes[4] == 45, bytes[7] == 45,
              bytes[10] == 84 || bytes[10] == 32,
              bytes[13] == 58, bytes[16] == 58,
              let year = decimal(bytes, 0..<4),
              let month = decimal(bytes, 5..<7),
              let day = decimal(bytes, 8..<10),
              let hour = decimal(bytes, 11..<13),
              let minute = decimal(bytes, 14..<16),
              let second = decimal(bytes, 17..<19) else {
            return nil
        }
        return strictDate(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            ),
            timeZone: timeZone
        )
    }

    private static func strictDate(from input: DateComponents, timeZone: TimeZone) -> Date? {
        guard let year = input.year, year > 0,
              let month = input.month, (1...12).contains(month),
              let day = input.day, (1...31).contains(day),
              let hour = input.hour, (0...23).contains(hour),
              let minute = input.minute, (0...59).contains(minute),
              let second = input.second, (0...59).contains(second) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        var components = input
        components.calendar = calendar
        components.timeZone = timeZone
        guard let date = calendar.date(from: components) else { return nil }
        let resolved = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard resolved.year == year,
              resolved.month == month,
              resolved.day == day,
              resolved.hour == hour,
              resolved.minute == minute,
              resolved.second == second else {
            return nil
        }
        return date
    }

    private static func parseOffset(_ rawValue: String) -> TimeZone? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "Z" || value == "z" { return TimeZone(secondsFromGMT: 0) }
        let bytes = Array(value.utf8)
        guard bytes.count == 6,
              bytes[0] == 43 || bytes[0] == 45,
              bytes[3] == 58,
              let hours = decimal(bytes, 1..<3),
              let minutes = decimal(bytes, 4..<6),
              (0...14).contains(hours),
              (0...59).contains(minutes),
              hours < 14 || minutes == 0 else {
            return nil
        }
        let magnitude = hours * 3_600 + minutes * 60
        let seconds = bytes[0] == 45 ? -magnitude : magnitude
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func hasExplicitISOOffset(_ value: String) -> Bool {
        value.range(of: #"(?:Z|z|[+-][0-9]{2}:?[0-9]{2})$"#, options: .regularExpression) != nil
    }

    private static func decimal(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var result = 0
        for index in range {
            let byte = bytes[index]
            guard (48...57).contains(byte) else { return nil }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }

    private static func dictionary(_ value: Any?) -> [CFString: Any]? {
        if let value = value as? [CFString: Any] { return value }
        guard let value = value as? NSDictionary else { return nil }
        var result: [CFString: Any] = [:]
        for (key, item) in value {
            guard let key = key as? String else { continue }
            result[key as CFString] = item
        }
        return result
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSString: value as String
        default: nil
        }
    }
}
