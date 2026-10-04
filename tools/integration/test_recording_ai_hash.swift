import Foundation
import CryptoKit

// Host-only draft vectors. Neither the app's codec nor a strict raw JSON decoder.
@main
struct CheckCanonicalHash {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2, "expected vector path")
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let vectors = try JSONSerialization.jsonObject(with: data) as? NSArray else {
            preconditionFailure("expected vector array")
        }
        var positive = 0
        var negative = 0
        for raw in vectors {
            guard let vector = raw as? NSDictionary, let name = vector["name"] as? String else {
                preconditionFailure("malformed vector")
            }
            let value = fixtureValue(vector)
            if let expected = vector["errorCode"] as? String {
                do {
                    _ = try RecordingAICanonicalReference.encode(value)
                    preconditionFailure("unexpectedly accepted: \(name)")
                } catch let error as RecordingAICanonicalReference.Failure {
                    precondition(error.rawValue == expected, "wrong error \(error.rawValue): \(name)")
                }
                negative += 1
            } else {
                let bytes = try RecordingAICanonicalReference.encode(value)
                guard let canonical = vector["canonicalUTF8"] as? String, let expectedHash = vector["sha256"] as? String else {
                    preconditionFailure("missing canonical/hash: \(name)")
                }
                precondition(bytes == Data(canonical.utf8), "canonical bytes differ: \(name)")
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                precondition(hash == expectedHash, "SHA-256 differs: \(name)")
                positive += 1
            }
        }
        print("PASS: Swift scalar canonical/CryptoKit \(positive) positive, \(negative) negative draft vectors")
    }

    private static func fixtureValue(_ vector: NSDictionary) -> Any {
        if let raw = vector["valueUTF16"] as? NSArray {
            let units = raw.map { value -> unichar in
                guard let number = value as? NSNumber, let unit = UInt16(number.stringValue) else {
                    preconditionFailure("malformed UTF16 fixture")
                }
                return unit
            }
            // Do not bridge to Swift String: it repairs malformed UTF16.
            return NSString(characters: units, length: units.count)
        }
        if let number = vector["valueNumber"] as? String {
            switch number {
            case "nan": return NSNumber(value: Double.nan)
            case "positiveInfinity": return NSNumber(value: Double.infinity)
            case "negativeInfinity": return NSNumber(value: -Double.infinity)
            default: preconditionFailure("unknown number fixture")
            }
        }
        if let decimal = vector["integerDecimal"] as? String {
            return NSDecimalNumber(string: decimal)
        }
        guard let value = vector["value"] else { preconditionFailure("missing fixture value") }
        // Retain NSDictionary/NSString identity; no [String: Any] bridge here.
        return value
    }
}
