import CryptoKit
import Foundation

public enum UMISNetworkValidationError: Error, Equatable, Sendable {
    case invalidHex
    case invalidDigestLength(actual: Int)
    case invalidPublicKeyLength(actual: Int)
    case invalidPrivateKeyLength(actual: Int)
    case catalogKeyIDMismatch
    case invalidTimestamp(String)
    case valueOutOfRange(String)
}

/// A SHA-256 value with a length invariant. Codable representation is lowercase hexadecimal.
public struct SHA256Value: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let byteCount = 32
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw UMISNetworkValidationError.invalidDigestLength(actual: bytes.count)
        }
        self.bytes = bytes
    }

    public init(hex: String) throws {
        guard let decoded = Data(lowercaseHex: hex), decoded.count == Self.byteCount else {
            throw UMISNetworkValidationError.invalidHex
        }
        self.bytes = decoded
    }

    public static func hash(_ data: Data) -> Self {
        Self(uncheckedBytes: Data(SHA256.hash(data: data)))
    }

    public var hex: String { bytes.lowercaseHex }
    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(hex: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private init(uncheckedBytes: Data) {
        precondition(uncheckedBytes.count == Self.byteCount)
        self.bytes = uncheckedBytes
    }
}

/// UTC timestamp used in signed and durable records.
///
/// The canonical spelling has seconds precision and a trailing `Z`, for example
/// `2026-01-01T00:00:00Z`. Keeping this as a validated value prevents locale or
/// encoder settings from changing signed bytes.
public struct CanonicalTimestamp: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw UMISNetworkValidationError.invalidTimestamp(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(date: Date) {
        self.rawValue = Self.format(date)
    }

    public static var now: Self { Self(date: Date()) }
    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        guard value.utf8.count == 20,
              value.utf8.allSatisfy({ $0 < 128 }),
              value.hasSuffix("Z") else {
            return false
        }
        let bytes = Array(value.utf8)
        guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
              bytes[13] == 58, bytes[16] == 58 else {
            return false
        }
        let digitOffsets = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        guard digitOffsets.allSatisfy({ (48...57).contains(bytes[$0]) }) else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

enum CanonicalJSONValue: Sendable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case integer(Int64)
    case unsigned(UInt64)
    case bool(Bool)
    case null
}

enum CanonicalJSON {
    static func encode(_ value: CanonicalJSONValue) -> Data {
        var result = Data()
        append(value, to: &result)
        return result
    }

    private static func append(_ value: CanonicalJSONValue, to data: inout Data) {
        switch value {
        case .object(let members):
            data.appendASCII("{")
            var isFirst = true
            // JCS sorts member names lexicographically by UTF-16 code units. All
            // protocol keys are ASCII, so Swift's ordering is identical here.
            for key in members.keys.sorted() {
                if !isFirst { data.appendASCII(",") }
                appendString(key, to: &data)
                data.appendASCII(":")
                append(members[key]!, to: &data)
                isFirst = false
            }
            data.appendASCII("}")
        case .array(let elements):
            data.appendASCII("[")
            for index in elements.indices {
                if index != elements.startIndex { data.appendASCII(",") }
                append(elements[index], to: &data)
            }
            data.appendASCII("]")
        case .string(let string):
            appendString(string, to: &data)
        case .integer(let number):
            data.append(contentsOf: String(number).utf8)
        case .unsigned(let number):
            data.append(contentsOf: String(number).utf8)
        case .bool(let value):
            data.appendASCII(value ? "true" : "false")
        case .null:
            data.appendASCII("null")
        }
    }

    private static func appendString(_ value: String, to data: inout Data) {
        data.appendASCII("\"")
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: data.appendASCII("\\b")
            case 0x09: data.appendASCII("\\t")
            case 0x0A: data.appendASCII("\\n")
            case 0x0C: data.appendASCII("\\f")
            case 0x0D: data.appendASCII("\\r")
            case 0x22: data.appendASCII("\\\"")
            case 0x5C: data.appendASCII("\\\\")
            case 0x00...0x1F:
                let escape = String(format: "\\u%04x", scalar.value)
                data.append(contentsOf: escape.utf8)
            default:
                data.append(contentsOf: String(scalar).utf8)
            }
        }
        data.appendASCII("\"")
    }
}

extension Data {
    init?(lowercaseHex string: String) {
        guard string.count.isMultiple(of: 2),
              string.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else {
            return nil
        }
        var result = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value >> 56))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUUID(_ value: UUID) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { append(contentsOf: $0) }
    }
}
