import ColorSync
import CoreGraphics
import Foundation

// Display geometry uses Core Graphics global coordinates: the main display's
// top-left corner is (0, 0) and y grows downwards.

/// A side of the game display.
nonisolated enum Edge: String, CaseIterable, Sendable {
    case left, right, top, bottom

    var title: String { rawValue.capitalized }
}

/// Where every display sits, keyed by display UUID. The main display is always at (0, 0).
nonisolated struct Arrangement: Codable, Equatable, Sendable {
    var mainUUID: String
    var origins: [String: [Int32]]

    init(mainUUID: String, origins: [String: [Int32]]) {
        self.mainUUID = mainUUID
        self.origins = origins
    }

    init(mainUUID: String, frames: [String: CGRect]) {
        self.mainUUID = mainUUID
        origins = frames.mapValues { [Int32($0.minX.rounded()), Int32($0.minY.rounded())] }
    }

    /// Frames of the displays that are both in this arrangement and in `sizes`.
    func frames(sizes: [String: CGSize]) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for (uuid, size) in sizes {
            guard let origin = origins[uuid], origin.count == 2 else { continue }
            frames[uuid] = CGRect(x: CGFloat(origin[0]), y: CGFloat(origin[1]), width: size.width, height: size.height)
        }
        return frames
    }
}

/// A stretch of the game display's border that another display touches:
/// the cursor can leave the game display there.
nonisolated struct OpenEdge: Equatable, Sendable {
    let edge: Edge
    let displayUUID: String
    /// The shared segment, in global coordinates.
    let from: CGPoint
    let to: CGPoint
}

nonisolated enum Geometry {
    /// Touching edges shorter than this don't count (a shared corner is a single point).
    static let tolerance: CGFloat = 0.5

    /// The part of `game`'s border that `other` shares, if any.
    static func openEdge(of game: CGRect, with other: CGRect, uuid: String) -> OpenEdge? {
        let overlapY = (max(game.minY, other.minY), min(game.maxY, other.maxY))
        let overlapX = (max(game.minX, other.minX), min(game.maxX, other.maxX))
        let sharesRows = overlapY.1 - overlapY.0 > tolerance
        let sharesColumns = overlapX.1 - overlapX.0 > tolerance
        if sharesRows, abs(other.maxX - game.minX) <= tolerance {
            return OpenEdge(edge: .left, displayUUID: uuid,
                            from: CGPoint(x: game.minX, y: overlapY.0), to: CGPoint(x: game.minX, y: overlapY.1))
        }
        if sharesRows, abs(other.minX - game.maxX) <= tolerance {
            return OpenEdge(edge: .right, displayUUID: uuid,
                            from: CGPoint(x: game.maxX, y: overlapY.0), to: CGPoint(x: game.maxX, y: overlapY.1))
        }
        if sharesColumns, abs(other.maxY - game.minY) <= tolerance {
            return OpenEdge(edge: .top, displayUUID: uuid,
                            from: CGPoint(x: overlapX.0, y: game.minY), to: CGPoint(x: overlapX.1, y: game.minY))
        }
        if sharesColumns, abs(other.minY - game.maxY) <= tolerance {
            return OpenEdge(edge: .bottom, displayUUID: uuid,
                            from: CGPoint(x: overlapX.0, y: game.maxY), to: CGPoint(x: overlapX.1, y: game.maxY))
        }
        return nil
    }

    /// Every stretch of the game display's border that another display touches.
    static func openEdges(frames: [String: CGRect], game: String) -> [OpenEdge] {
        guard let gameFrame = frames[game] else { return [] }
        return frames.keys.sorted().compactMap { uuid in
            uuid == game ? nil : openEdge(of: gameFrame, with: frames[uuid]!, uuid: uuid)
        }
    }

    /// The automatic game layout: every display that shares a side with the
    /// game display moves into the nearest free diagonal, so it touches the
    /// game display only at a corner. Other displays stay where they are.
    static func gameFrames(from frames: [String: CGRect], game: String) -> [String: CGRect] {
        guard let g = frames[game] else { return frames }
        var result = frames
        let neighbours = openEdges(frames: frames, game: game)
        for open in neighbours {
            let b = frames[open.displayUUID]!
            let topLeft = CGRect(x: g.minX - b.width, y: g.minY - b.height, width: b.width, height: b.height)
            let topRight = CGRect(x: g.maxX, y: g.minY - b.height, width: b.width, height: b.height)
            let bottomLeft = CGRect(x: g.minX - b.width, y: g.maxY, width: b.width, height: b.height)
            let bottomRight = CGRect(x: g.maxX, y: g.maxY, width: b.width, height: b.height)
            let candidates: [CGRect] = switch open.edge {
            case .left: [topLeft, bottomLeft, topRight, bottomRight]
            case .right: [topRight, bottomRight, topLeft, bottomLeft]
            case .top: [topLeft, topRight, bottomLeft, bottomRight]
            case .bottom: [bottomLeft, bottomRight, topLeft, topRight]
            }
            let others = result.filter { $0.key != open.displayUUID }.map(\.value)
            if let free = candidates.first(where: { candidate in
                !others.contains { $0.intersection(candidate).width > tolerance && $0.intersection(candidate).height > tolerance }
            }) {
                result[open.displayUUID] = free
            }
        }
        return result
    }
}

/// Reads and changes the real display arrangement.
nonisolated enum Displays {
    struct Info: Identifiable, Equatable, Sendable {
        /// Display UUID: stable across reboots and reconnections.
        let id: String
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let isMain: Bool
    }

    /// Active displays that aren't mirroring another one.
    static func online() -> [Info] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayIsActive(id) != 0, CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                  let uuid = uuid(of: id) else { return nil }
            return Info(id: uuid, displayID: id, frame: CGDisplayBounds(id), isMain: id == main)
        }
    }

    static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func current() -> Arrangement? {
        let displays = online()
        guard let main = displays.first(where: \.isMain) else { return nil }
        return Arrangement(mainUUID: main.id, frames: Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.frame) }))
    }

    enum ApplyResult: Equatable, Sendable {
        case applied, unchanged
        case mainDisplayChanged
        case failed(Int32)
    }

    /// Moves the displays to `arrangement`. The change lasts for this login
    /// session only (never saved to disk), so logging out or restarting
    /// always brings back the arrangement from System Settings.
    static func apply(_ arrangement: Arrangement) -> ApplyResult {
        let displays = online()
        guard let main = displays.first(where: \.isMain), main.id == arrangement.mainUUID else {
            return .mainDisplayChanged
        }
        let moves = displays.compactMap { display -> (CGDirectDisplayID, Int32, Int32)? in
            guard !display.isMain, let origin = arrangement.origins[display.id], origin.count == 2,
                  origin[0] != Int32(display.frame.minX) || origin[1] != Int32(display.frame.minY) else { return nil }
            return (display.displayID, origin[0], origin[1])
        }
        guard !moves.isEmpty else { return .unchanged }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { return .failed(begin.rawValue) }
        for (id, x, y) in moves {
            CGConfigureDisplayOrigin(config, id, x, y)
        }
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        return result == .success ? .applied : .failed(result.rawValue)
    }
}
