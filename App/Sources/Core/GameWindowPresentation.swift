import Foundation

nonisolated enum GameWindowPresentation: Equatable {
    case windowed, native, unknown

    static func league(subrole: String?) -> Self {
        switch subrole {
        case "AXStandardWindow": .windowed
        case "AXUnknown": .native
        default: .unknown
        }
    }

    func retaining(_ previous: Self) -> Self {
        self == .unknown ? previous : self
    }
}
