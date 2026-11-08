import SwiftUI

/// A to-scale drawing of the displays, like System Settings › Displays ›
/// Arrange. The game display is tinted; edges where the cursor can leave it are red.
struct DisplayDiagram: View {
    let frames: [String: CGRect]
    let displays: [GameMode.Display]
    var height: CGFloat = 150
    var showsNames = true

    private var gameID: String? { displays.first(where: \.isMain)?.id }

    var body: some View {
        GeometryReader { proxy in
            let union = frames.values.reduce(CGRect.null) { $0.union($1) }
            if union.isNull || union.width == 0 || union.height == 0 {
                Color.clear
            } else {
                let inset: CGFloat = 8
                let scale = min((proxy.size.width - inset * 2) / union.width, (proxy.size.height - inset * 2) / union.height)
                let origin = CGPoint(x: (proxy.size.width - union.width * scale) / 2,
                                     y: (proxy.size.height - union.height * scale) / 2)
                let map = { (point: CGPoint) in
                    CGPoint(x: origin.x + (point.x - union.minX) * scale, y: origin.y + (point.y - union.minY) * scale)
                }
                ZStack(alignment: .topLeading) {
                    ForEach(displays) { display in
                        if let frame = frames[display.id] {
                            let topLeft = map(frame.origin)
                            DisplayTile(display: display, isGame: display.id == gameID, showsName: showsNames)
                                .frame(width: max(frame.width * scale - 3, 4), height: max(frame.height * scale - 3, 4))
                                .position(x: topLeft.x + frame.width * scale / 2, y: topLeft.y + frame.height * scale / 2)
                        }
                    }
                    if let gameID {
                        ForEach(Array(Geometry.openEdges(frames: frames, game: gameID).enumerated()), id: \.offset) { _, open in
                            Path { path in
                                path.move(to: map(open.from))
                                path.addLine(to: map(open.to))
                            }
                            .stroke(Color.red, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .shadow(color: .red.opacity(0.5), radius: 3)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.35), value: frames)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let gameID else { return "No displays" }
        let open = Geometry.openEdges(frames: frames, game: gameID).map(\.edge.rawValue)
        return "\(frames.count) displays. " + (open.isEmpty ? "No edge of the game display is shared."
                                                : "Shared edges of the game display: \(GameEdgeFormat.list(open)).")
    }
}

private struct DisplayTile: View {
    let display: GameMode.Display
    let isGame: Bool
    let showsName: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        GeometryReader { proxy in
            VStack(spacing: 2) {
                Image(systemName: isGame ? "gamecontroller.fill" : "display")
                    .font(.system(size: min(16, proxy.size.height * 0.3), weight: .semibold))
                    .foregroundStyle(isGame ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                if showsName, proxy.size.height > 46, proxy.size.width > 60 {
                    Text(display.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(verbatim: "\(Int(display.frame.width))×\(Int(display.frame.height))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(4)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(isGame ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.06)), in: shape)
        .overlay {
            shape.strokeBorder(isGame ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(Color.cardStroke),
                               lineWidth: isGame ? 1.5 : 1)
        }
    }
}
