/// Recognizes the Unix-epoch timestamp `diff -N` writes for a missing file,
/// as `git apply`'s `has_epoch_timestamp` does.
enum EpochTimestamp {
    /// Whether the text after the payload's last tab is an epoch timestamp
    /// in any time zone: `1970-01-01 hh:mm:00[.0…] ±zone` east of UTC or
    /// `1969-12-31 …` west of it, where the local time minus the zone
    /// offset is midnight. A fraction other than zeros can't be the epoch.
    static func ends(_ payload: ArraySlice<UInt8>) -> Bool {
        guard let tab = payload.lastIndex(of: UInt8(ascii: "\t")) else { return false }
        let stamp = payload[payload.index(after: tab)...]
        let epochHour: Int
        let rest: ArraySlice<UInt8>
        if let time = stamp.dropping(prefix: westOfUTC) {
            epochHour = 24
            rest = time
        } else if let time = stamp.dropping(prefix: eastOfUTC) {
            epochHour = 0
            rest = time
        } else {
            return false
        }
        guard let minutes = minutesSinceMidnight(rest) else { return false }
        return minutes == epochHour * 60
    }

    private static let westOfUTC = Array("1969-12-31 ".utf8)
    private static let eastOfUTC = Array("1970-01-01 ".utf8)

    /// `hh:mm:00[.0…] ±hh[:]mm` to the end, as UTC minutes since local
    /// midnight; nil if it doesn't match git's pattern.
    private static func minutesSinceMidnight(_ text: ArraySlice<UInt8>) -> Int? {
        var cursor = text
        guard let hour = cursor.digits(firstAtMost: 2),
              cursor.take(UInt8(ascii: ":")),
              let minute = cursor.digits(firstAtMost: 5),
              cursor.take(UInt8(ascii: ":")),
              cursor.digits(firstAtMost: 0) == 0
        else { return nil }
        if cursor.take(UInt8(ascii: ".")) {
            let zeros = cursor.prefix { $0 == UInt8(ascii: "0") }.count
            guard zeros > 0 else { return nil }
            cursor = cursor.dropFirst(zeros)
        }
        guard cursor.take(UInt8(ascii: " ")), let sign = cursor.popFirst(),
              sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-"),
              let zoneHours = cursor.digits(firstAtMost: 2)
        else { return nil }
        _ = cursor.take(UInt8(ascii: ":"))
        guard let zoneMinutes = cursor.digits(firstAtMost: 5), cursor.isEmpty else { return nil }
        let zone = (zoneHours * 60 + zoneMinutes) * (sign == UInt8(ascii: "-") ? -1 : 1)
        return hour * 60 + minute - zone
    }
}

extension ArraySlice<UInt8> {
    /// Takes `byte` off the front if it's there.
    fileprivate mutating func take(_ byte: UInt8) -> Bool {
        guard first == byte else { return false }
        removeFirst()
        return true
    }

    /// Takes a two-digit number whose first digit is at most `limit`.
    fileprivate mutating func digits(firstAtMost limit: UInt8) -> Int? {
        let zero = UInt8(ascii: "0")
        guard count >= 2, (zero...(zero + limit)).contains(self[startIndex]),
              (zero...UInt8(ascii: "9")).contains(self[startIndex + 1])
        else { return nil }
        let value = Int(self[startIndex] - zero) * 10 + Int(self[startIndex + 1] - zero)
        removeFirst(2)
        return value
    }
}
