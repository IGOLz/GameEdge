import Foundation

@main struct Checks {
    static func main() {
        assert(GameWindowPresentation.league(subrole: "AXStandardWindow") == .windowed)
        assert(GameWindowPresentation.league(subrole: "AXUnknown") == .native)
        for failedRead in [nil, "AXDialog"] as [String?] {
            let observed = GameWindowPresentation.league(subrole: failedRead)
            assert(observed.retaining(.native) == .native)
            assert(observed.retaining(.windowed) == .windowed)
            assert(observed.retaining(.unknown) == .unknown)
        }
        assert(GameWindowPresentation.windowed.retaining(.native) == .windowed)
        assert(GameWindowPresentation.native.retaining(.windowed) == .native)
        print("Game window presentation checks passed")
    }
}
