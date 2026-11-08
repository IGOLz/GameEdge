// Offline checks for the automatic game layout.
// swiftc -parse-as-library App/Sources/Core/DisplayLayout.swift Tests/LayoutChecks.swift -o build/layout-checks && build/layout-checks
import CoreGraphics
import Foundation

@main
struct LayoutChecks {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("✗ \(message)")
        }
    }

    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 2560, _ h: CGFloat = 1440) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    static func main() {
        // Three displays side by side, game on the middle one (the setup GameEdge was made for).
        let row = ["game": rect(0, 0), "left": rect(-2560, 0), "right": rect(2560, 0)]
        check(Set(Geometry.openEdges(frames: row, game: "game").map(\.edge)) == [.left, .right], "side-by-side edges are open")
        let game = Geometry.gameFrames(from: row, game: "game")
        check(Geometry.openEdges(frames: game, game: "game").isEmpty, "game layout seals every edge")
        check(game["left"] == rect(-2560, -1440), "left display moves to the top-left corner")
        check(game["right"] == rect(2560, -1440), "right display moves to the top-right corner")
        check(game["game"] == row["game"], "the game display never moves")

        // A corner-only contact is not an open edge.
        check(Geometry.openEdges(frames: ["game": rect(0, 0), "corner": rect(2560, 1440)], game: "game").isEmpty,
              "a shared corner doesn't count")

        // Partial overlap (smaller display, offset) still counts.
        let offset = ["game": rect(0, 0), "laptop": rect(-1512, 600, 1512, 982)]
        let open = Geometry.openEdges(frames: offset, game: "game")
        check(open.count == 1 && open[0].edge == .left && open[0].from.y == 600 && open[0].to.y == 1440,
              "an offset display opens only the shared stretch")
        check(Geometry.openEdges(frames: Geometry.gameFrames(from: offset, game: "game"), game: "game").isEmpty,
              "an offset display is moved too")

        // Display above and display on the left: both get a free corner, no overlap.
        let stacked = ["game": rect(0, 0), "above": rect(0, -1440), "left": rect(-2560, 0)]
        let moved = Geometry.gameFrames(from: stacked, game: "game")
        check(Geometry.openEdges(frames: moved, game: "game").isEmpty, "top and left are sealed")
        check(moved["left"]!.intersection(moved["above"]!).isNull || moved["left"]!.intersection(moved["above"]!).width == 0,
              "moved displays don't overlap")

        // A display that doesn't touch the game display stays put.
        let far = ["game": rect(0, 0), "left": rect(-2560, 0), "farLeft": rect(-5120, 0)]
        check(Geometry.gameFrames(from: far, game: "game")["farLeft"] == far["farLeft"], "unrelated displays stay put")

        // The virtual game display touches the arrangement only at a corner, whatever the layout.
        let virtualSize = CGSize(width: 2560, height: 1600)
        let layouts: [String: [CGRect]] = [
            "single": [rect(0, 0)],
            "side by side": [rect(0, 0), rect(-2560, 0), rect(2560, 0)],
            "game layout": [rect(0, 0), rect(-2560, -1440), rect(2560, -1440)],
            "stacked": [rect(0, 0), rect(0, -1440)],
            "laptop below": [rect(0, 0), rect(524, 1440, 1512, 982)],
            "uneven bottoms": [rect(0, 0), rect(-1920, 360, 1920, 1080), rect(2560, -200, 1440, 2560)],
            "retina and 4K": [rect(0, 0, 1512, 982), rect(1512, -1178, 3840, 2160)],
        ]
        for (name, displays) in layouts {
            guard let origin = Geometry.cornerOrigin(for: virtualSize, beside: displays) else {
                check(false, "\(name): no corner found"); continue
            }
            let virtual = CGRect(origin: origin, size: virtualSize)
            check(displays.allSatisfy { $0.intersection(virtual).width <= 0 || $0.intersection(virtual).height <= 0 },
                  "\(name): the virtual display doesn't overlap")
            check(displays.allSatisfy { Geometry.openEdge(of: $0, with: virtual, uuid: "v") == nil },
                  "\(name): the virtual display shares no edge")
            check(displays.contains { $0.minX == virtual.maxX && $0.maxY == virtual.minY },
                  "\(name): the virtual display touches a corner")
        }

        // Arrangement round trip.
        let arrangement = Arrangement(mainUUID: "game", frames: game)
        let sizes = game.mapValues(\.size)
        check(arrangement.frames(sizes: sizes) == game, "arrangement round trip")

        if failures == 0 {
            print("✓ Layout checks passed")
        } else {
            print("\(failures) layout check(s) failed")
            exit(1)
        }
    }
}
