import Foundation

// The photos and videos the app saved to the library, remembered across launches. PhotoKit can't list the assets
// one app created, so the app keeps their identifiers itself, in a JSON file this list reads and writes.

/// What a saved asset came from. The raw values match the app's capture result kinds, so a result converts by raw
/// value; `edit` marks a copy saved from the editor.
public enum CapturedAssetKind: String, Codable, Sendable, CaseIterable {
    case photo, raw, bracket, stack, video, edit

    // A kind written by a later version reads as a photo, so the row stays listed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = CapturedAssetKind(rawValue: try container.decode(String.self)) ?? .photo
    }
}

/// One saved asset, as the gallery lists it before PhotoKit is asked about it.
public struct CapturedAsset: Codable, Hashable, Sendable, Identifiable {
    /// PHAsset.localIdentifier.
    public var id: String
    /// When it was taken. The list sorts by it.
    public var date: Date
    public var kind: CapturedAssetKind
    /// "1/250 · ISO 100 · ƒ/1.8", empty when unknown.
    public var summary: String

    public init(id: String, date: Date, kind: CapturedAssetKind, summary: String = "") {
        self.id = id
        self.date = date
        self.kind = kind
        self.summary = summary
    }

    enum CodingKeys: String, CodingKey { case id, date, kind, summary }

    // Without an identifier a row can't find its asset, so it fails and the list skips it. Anything else that is
    // missing falls back: an unreadable date sorts the row last, where the cap drops it first.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Empty asset identifier")
        }
        self.init(id: id,
                  date: c.value(.date, default: .distantPast),
                  kind: c.value(.kind, default: .photo),
                  summary: c.value(.summary, default: ""))
    }
}

/// The app's saved assets: newest first by date, each identifier once, at most `limit` rows.
public struct CapturedAssetList: Codable, Hashable, Sendable {
    /// About 120 bytes a row, so the file stays near 2 MB. Old rows are never pruned otherwise: an asset in Recently
    /// Deleted comes back with the same identifier, and outside a limited selection "missing" doesn't mean deleted.
    public static let limit = 20_000

    public private(set) var assets: [CapturedAsset]

    public init() {
        assets = []
    }

    /// Adds `new` in the order it was saved. A row whose identifier is already listed replaces the old one, a row
    /// with an empty identifier is skipped, and among equal dates the later record comes first. The oldest rows past
    /// `limit` drop off, even when they are the ones just recorded.
    public mutating func record(_ new: [CapturedAsset]) {
        var latest: [String: Int] = [:]
        for (offset, asset) in new.enumerated() where !asset.id.isEmpty {
            latest[asset.id] = offset
        }
        guard !latest.isEmpty else { return }
        let incoming = new.enumerated()
            .filter { latest[$0.element.id] == $0.offset }
            .sorted { a, b in
                let (keyA, keyB) = (Self.sortKey(a.element.date), Self.sortKey(b.element.date))
                return keyA != keyB ? keyA > keyB : a.offset > b.offset
            }
            .map(\.element)
        let kept = assets.filter { latest[$0.id] == nil }
        assets = Self.merged(incoming, kept)
        trimToLimit()
    }

    /// Removes these identifiers; the rest keep their order.
    public mutating func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        assets.removeAll { ids.contains($0.id) }
    }

    /// In list order, for PHAsset.fetchAssets(withLocalIdentifiers:options:).
    public var identifiers: [String] {
        assets.map(\.id)
    }

    /// Each asset by identifier, for a lookup per grid cell. Built on every call, so keep the result while the list
    /// stays the same.
    public var assetsByID: [String: CapturedAsset] {
        Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    enum CodingKeys: String, CodingKey { case assets }

    // Row by row, so one damaged row costs only itself, and the rules of `record` hold again afterwards whatever the
    // file says. A valid list comes back unchanged: equal dates keep their order in the file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rows = c.value(.assets, default: [LossyRow]()).compactMap(\.asset)
        var seen = Set<String>()
        assets = rows.enumerated()
            .sorted { a, b in
                let (keyA, keyB) = (Self.sortKey(a.element.date), Self.sortKey(b.element.date))
                return keyA != keyB ? keyA > keyB : a.offset < b.offset
            }
            .map(\.element)
            .filter { seen.insert($0.id).inserted }
        trimToLimit()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Never throws: data that isn't a list at all gives an empty list.
    public static func decoded(from data: Data) -> CapturedAssetList {
        (try? JSONDecoder().decode(CapturedAssetList.self, from: data)) ?? CapturedAssetList()
    }

    // MARK: - Helpers

    // Decoding never fails here, so the array keeps reading past a bad row instead of stopping at it.
    private struct LossyRow: Decodable {
        let asset: CapturedAsset?

        init(from decoder: Decoder) throws {
            asset = try? CapturedAsset(from: decoder)
        }
    }

    // A NaN date would make the ordering inconsistent, so it sorts as the oldest possible.
    private static func sortKey(_ date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        return seconds.isNaN ? -.infinity : seconds
    }

    // Both inputs are newest first. On equal dates the new rows go first, as the later record.
    private static func merged(_ newer: [CapturedAsset], _ older: [CapturedAsset]) -> [CapturedAsset] {
        var result: [CapturedAsset] = []
        result.reserveCapacity(newer.count + older.count)
        var i = 0
        var j = 0
        while i < newer.count, j < older.count {
            if sortKey(older[j].date) > sortKey(newer[i].date) {
                result.append(older[j])
                j += 1
            } else {
                result.append(newer[i])
                i += 1
            }
        }
        result.append(contentsOf: newer[i...])
        result.append(contentsOf: older[j...])
        return result
    }

    private mutating func trimToLimit() {
        if assets.count > Self.limit {
            assets.removeLast(assets.count - Self.limit)
        }
    }
}
