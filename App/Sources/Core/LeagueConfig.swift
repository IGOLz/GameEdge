import AppKit

/// League of Legends' `game.cfg`. In Windowed mode the game renders at the
/// resolution saved there and stretches it into the window, so with the title
/// bar and the strip below covered the picture gets squashed. GameEdge writes
/// the window's real content size there while you're not playing (the game
/// reads the file when a match starts and rewrites it when it ends), and puts
/// your own resolution back when Windowed mode or the option is turned off.
enum LeagueConfig {
    static let windowedMode = 1

    static var url: URL? {
        let client = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.riotgames.leagueoflegends")
            ?? URL(fileURLWithPath: "/Applications/League of Legends.app")
        let file = client.appendingPathComponent("Contents/LoL/Config/game.cfg")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    struct General: Equatable {
        var width: Int?
        var height: Int?
        var windowMode: Int?
    }

    static func read() -> General? {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let values = generalValues(text)
        return General(width: values["Width"].flatMap(Int.init), height: values["Height"].flatMap(Int.init),
                       windowMode: values["WindowMode"].flatMap(Int.init))
    }

    /// Changes Width and Height in [General], leaving everything else as it is.
    @discardableResult
    static func setResolution(width: Int, height: Int) -> Bool {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        var inGeneral = false
        var found: Set<String> = []
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inGeneral = line.trimmingCharacters(in: .whitespacesAndNewlines) == "[General]"
                continue
            }
            guard inGeneral else { continue }
            let ending = lines[index].hasSuffix("\r") ? "\r" : ""
            if line.hasPrefix("Width=") { lines[index] = "Width=\(width)" + ending; found.insert("Width") }
            if line.hasPrefix("Height=") { lines[index] = "Height=\(height)" + ending; found.insert("Height") }
        }
        guard found == ["Width", "Height"] else { return false }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.write("game.cfg: \(error.localizedDescription)")
            return false
        }
    }

    private static func generalValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        var inGeneral = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inGeneral = line == "[General]"; continue }
            guard inGeneral, let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return values
    }
}
