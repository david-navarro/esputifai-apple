import Foundation

/// Read-only navigation over a parsed JSON document. YouTube's responses are deep and change
/// shape often, so every step is optional: a missing key just yields `.null` instead of throwing,
/// and the caller decides what is required.
public struct JSON {
    public let raw: Any?

    public init(_ raw: Any?) { self.raw = raw }

    public init(data: Data) throws {
        raw = try JSONSerialization.jsonObject(with: data)
    }

    public subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> JSON {
        guard let a = raw as? [Any], a.indices.contains(index) else { return JSON(nil) }
        return JSON(a[index])
    }

    /// Follows a dotted path: `json.path("a.b.c")`.
    public func path(_ dotted: String) -> JSON {
        dotted.split(separator: ".").reduce(self) { $0[String($1)] }
    }

    public var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    public var string: String? { raw as? String }
    public var int: Int? { (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap { Int($0) } }
    public var isNull: Bool { raw == nil || raw is NSNull }
    public var keys: [String] { (raw as? [String: Any]).map { Array($0.keys) } ?? [] }

    /// The text of a `{"runs":[{"text":…}]}` or `{"simpleText":…}` object.
    public var text: String? {
        if let s = self["simpleText"].string { return s }
        let runs = self["runs"].array.compactMap { $0["text"].string }
        return runs.isEmpty ? nil : runs.joined()
    }
}
