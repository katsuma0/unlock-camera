import Foundation

/// How frames of a stacked capture combine.
public enum StackBlend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Light adds up like a real long exposure: N frames of t seconds look like one exposure of N*t.
    case additive
    /// Frames average: motion blurs but brightness stays at one frame. Works like an ND filter.
    case average
    /// Brightest value wins per pixel: light trails and star trails over a single-frame background.
    case lighten

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .additive: return "Real"
        case .average: return "Blur"
        case .lighten: return "Trails"
        }
    }

    public var detail: String {
        switch self {
        case .additive: return "Adds light like a real long exposure. Use a tripod."
        case .average: return "Blurs motion without brightening, like an ND filter."
        case .lighten: return "Keeps the brightest pixels. Light trails, star trails."
        }
    }
}
