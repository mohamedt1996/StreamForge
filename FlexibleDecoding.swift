import Foundation

/// IPTV and addon APIs are loose with JSON types ("1" vs 1 vs null vs ""), so every
/// model decodes through these tolerant helpers instead of strict Codable.
extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s.isEmpty ? nil : s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) {
            return d.rounded() == d ? String(Int(d)) : String(d)
        }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? "1" : "0" }
        return nil
    }

    func flexInt(_ key: Key) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            if let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
            if let d = Double(s) { return Int(d) }
        }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b ? 1 : 0 }
        return nil
    }

    func flexDouble(_ key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func flexBool(_ key: Key) -> Bool {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = flexInt(key) { return i != 0 }
        return false
    }

    func flexStringArray(_ key: Key) -> [String] {
        if let a = try? decodeIfPresent([String?].self, forKey: key) { return a.compactMap { $0 }.filter { !$0.isEmpty } }
        if let s = try? decodeIfPresent(String.self, forKey: key), !s.isEmpty { return [s] }
        return []
    }

    func flexURL(_ key: Key) -> URL? {
        guard let s = flexString(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let u = URL(string: s), u.scheme != nil { return u }
        return URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)
    }

    func decodeLossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}

/// Decodes an array, silently skipping elements that fail to decode.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                result.append(value)
            } else {
                _ = try? container.decode(AnyDecodable.self)
            }
        }
        elements = result
    }
}

struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

/// Generic dynamic key for dictionaries with unknown keys.
struct DynamicKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

extension String {
    var base64Decoded: String {
        guard let data = Data(base64Encoded: self, options: .ignoreUnknownCharacters),
              let s = String(data: data, encoding: .utf8) else { return self }
        return s
    }

    var nilIfEmpty: String? { isEmpty ? nil : self }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
