import Foundation
import CoreFoundation

// Host-only C00 proposal. This encodes objects; it is not a raw JSON decoder.
enum RecordingAICanonicalReference {
    enum Failure: String, Error {
        case unsupportedCanonicalType
        case integerOutsideInt64
        case invalidUnicode
    }

    static func encode(_ value: Any) throws -> Data {
        var bytes = Data()
        try append(value, to: &bytes)
        return bytes
    }

    private static func scalars(_ string: NSString) throws -> [UInt32] {
        var result: [UInt32] = []
        var index = 0
        while index < string.length {
            let first = UInt32(string.character(at: index))
            if (0xd800...0xdbff).contains(first) {
                guard index + 1 < string.length else { throw Failure.invalidUnicode }
                let second = UInt32(string.character(at: index + 1))
                guard (0xdc00...0xdfff).contains(second) else { throw Failure.invalidUnicode }
                result.append(0x10000 + ((first - 0xd800) << 10) + second - 0xdc00)
                index += 2
            } else {
                guard !(0xdc00...0xdfff).contains(first) else { throw Failure.invalidUnicode }
                result.append(first)
                index += 1
            }
        }
        return result
    }

    private static func string(_ scalars: [UInt32], to bytes: inout Data) {
        bytes.append(0x22)
        for scalar in scalars {
            let escaped: String
            switch scalar {
            case 0x22: escaped = "\\\""
            case 0x5c: escaped = "\\\\"
            case 0x08: escaped = "\\b"
            case 0x09: escaped = "\\t"
            case 0x0a: escaped = "\\n"
            case 0x0c: escaped = "\\f"
            case 0x0d: escaped = "\\r"
            case 0x00...0x1f:
                let hex = String(scalar, radix: 16)
                escaped = "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                escaped = String(UnicodeScalar(scalar)!)
            }
            bytes.append(contentsOf: escaped.utf8)
        }
        bytes.append(0x22)
    }

    private static func append(_ value: Any, to bytes: inout Data) throws {
        if value is NSNull {
            bytes.append(contentsOf: "null".utf8)
        } else if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                bytes.append(contentsOf: (number.boolValue ? "true" : "false").utf8)
                return
            }
            let type = String(cString: number.objCType)
            if type == "f" || type == "d" {
                // Foundation uses NSDecimalNumber for JSON integer overflow.
                let decimal = number.stringValue
                if number is NSDecimalNumber,
                   decimal.range(of: "^-?[0-9]+$", options: .regularExpression) != nil,
                   Int64(decimal) == nil {
                    throw Failure.integerOutsideInt64
                }
                throw Failure.unsupportedCanonicalType
            }
            guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else {
                throw Failure.unsupportedCanonicalType
            }
            guard let integer = Int64(number.stringValue) else { throw Failure.integerOutsideInt64 }
            bytes.append(contentsOf: String(integer).utf8)
        } else if let text = value as? NSString {
            string(try scalars(text), to: &bytes)
        } else if let array = value as? NSArray {
            bytes.append(0x5b)
            for index in 0..<array.count {
                if index != 0 { bytes.append(0x2c) }
                try append(array[index], to: &bytes)
            }
            bytes.append(0x5d)
        } else if let dictionary = value as? NSDictionary {
            // Keep original NSString keys: Swift Dictionary equality folds NFC/NFD.
            let keys = try dictionary.allKeys.map { key -> (NSString, [UInt32]) in
                guard let text = key as? NSString else { throw Failure.unsupportedCanonicalType }
                return (text, try scalars(text))
            }.sorted { $0.1.lexicographicallyPrecedes($1.1) }
            bytes.append(0x7b)
            for (index, key) in keys.enumerated() {
                if index != 0 { bytes.append(0x2c) }
                string(key.1, to: &bytes)
                bytes.append(0x3a)
                guard let child = dictionary.object(forKey: key.0) else { throw Failure.unsupportedCanonicalType }
                try append(child, to: &bytes)
            }
            bytes.append(0x7d)
        } else {
            throw Failure.unsupportedCanonicalType
        }
    }
}
