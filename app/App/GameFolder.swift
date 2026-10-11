import Foundation

/// Where your own copy of the game lives on this iPhone. Two ways:
/// - In the app's own folder (Files › On My iPhone › GTA V Port): found automatically, at any
///   depth, with no picking and no permissions. Moving a folder within On My iPhone is instant.
/// - A folder picked in Files: kept between launches with a bookmark.
/// Either way the app reads the files directly while you play, so no server is needed.
enum GameFolder {
    private static let bookmarkKey = "gameFolderBookmark"
    private static let nameKey = "gameFolderName"
    private static let subpathKey = "gameFolderSubpath" // from the picked folder (or the app folder) down to data/
    private static let inAppKey = "gameFolderInApp"
    private static var accessing: URL?
    /// Lines for the app's log (Settings › Share log), so a refused folder can be diagnosed.
    static var log: (String) -> Void = { _ in }

    static var isChosen: Bool { inAppFolder || UserDefaults.standard.data(forKey: bookmarkKey) != nil }
    static var inAppFolder: Bool { UserDefaults.standard.bool(forKey: inAppKey) }
    static var name: String { UserDefaults.standard.string(forKey: nameKey) ?? "folder" }
    static var appFolder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func clear() {
        for key in [bookmarkKey, nameKey, subpathKey, inAppKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: The app's own folder

    /// Looks for the game inside Files › On My iPhone › GTA V Port. Returns true when it was found
    /// and checked (and remembers it). Does nothing when a picked folder is already in use.
    @discardableResult
    static func findInAppFolder() -> Bool {
        if isChosen && !inAppFolder { return false }
        guard let data = findData(in: appFolder, depth: 4) else {
            if inAppFolder { log("The game folder is no longer in the app's folder."); clear() }
            return false
        }
        if let problem = check(data) {
            log("Game folder in the app's folder refused (\(relative(data, to: appFolder))): \(problem)")
            return false
        }
        let subpath = relative(data, to: appFolder)
        if !inAppFolder || UserDefaults.standard.string(forKey: subpathKey) != subpath {
            log("Game folder found in the app's folder: \(subpath)")
        }
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.set(true, forKey: inAppKey)
        UserDefaults.standard.set(subpath, forKey: subpathKey)
        UserDefaults.standard.set(data.deletingLastPathComponent().lastPathComponent, forKey: nameKey)
        return true
    }

    // MARK: A folder picked in Files

    /// Checks a folder picked in Files and remembers it. Returns a message if it is not usable.
    static func choose(_ picked: URL) -> String? {
        // Folders picked in Files need security-scoped access; plain paths (tests) don't.
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        log("Folder picked: \(picked.path) (access granted: \(scoped), \(describeLocation(picked)))")
        guard FileManager.default.isReadableFile(atPath: picked.path) else {
            return "The app was not allowed to open that folder. Move your game folder to Files › On My iPhone › GTA V Port instead; the app finds it there by itself."
        }
        guard let data = findData(in: picked, depth: 4) else { return wrongFolderMessage(picked) }
        if let problem = check(data) { return problem }
        do {
            let bookmark = try picked.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set(false, forKey: inAppKey)
            UserDefaults.standard.set(relative(data, to: picked), forKey: subpathKey)
            UserDefaults.standard.set(data == picked ? picked.lastPathComponent : data.deletingLastPathComponent().lastPathComponent, forKey: nameKey)
            log("Game folder accepted: data at \(relative(data, to: picked).isEmpty ? "(the picked folder)" : relative(data, to: picked))")
            return nil
        } catch {
            return "The app could not remember that folder: \(error.localizedDescription)"
        }
    }

    /// The chosen game's data/ folder, with access granted for the rest of this launch.
    static func open() -> URL? {
        let subpath = UserDefaults.standard.string(forKey: subpathKey) ?? ""
        if inAppFolder {
            let data = subpath.isEmpty ? appFolder : appFolder.appendingPathComponent(subpath)
            return FileManager.default.fileExists(atPath: data.appendingPathComponent("manifest.json").path) ? data : nil
        }
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if root.startAccessingSecurityScopedResource() { accessing = root }
        guard FileManager.default.isReadableFile(atPath: root.path) else { return nil }
        if stale, let fresh = try? root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        // Folders remembered by older versions have no subpath: look again.
        let data = subpath.isEmpty ? (findData(in: root, depth: 4) ?? root) : root.appendingPathComponent(subpath)
        return FileManager.default.fileExists(atPath: data.appendingPathComponent("manifest.json").path) ? data : nil
    }

    // MARK: Finding and checking

    /// The game's data/ folder inside `folder` (or `folder` itself), up to `depth` levels down.
    /// It is the folder with manifest.json next to x64 or common.
    private static func findData(in folder: URL, depth: Int) -> URL? {
        let manager = FileManager.default
        func isData(_ url: URL) -> Bool {
            manager.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
                && (directoryExists(url.appendingPathComponent("x64")) || directoryExists(url.appendingPathComponent("common")))
        }
        var level = [folder]
        for _ in 0...depth {
            var next: [URL] = []
            // A folder named data comes first, so a whole game folder wins over stray copies.
            for candidate in level {
                if isData(candidate.appendingPathComponent("data")) { return candidate.appendingPathComponent("data") }
                if isData(candidate) { return candidate }
            }
            for candidate in level {
                let children = (try? manager.contentsOfDirectory(at: candidate, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                next += children.filter { directoryExists($0) && !["EngineFiles", "b", "x64", "common", "__MACOSX"].contains($0.lastPathComponent) }
            }
            if next.isEmpty { break }
            level = Array(next.prefix(200))
        }
        return nil
    }

    /// Explains what to pick instead when the picked folder has no game data in it.
    private static func wrongFolderMessage(_ picked: URL) -> String {
        let name = picked.lastPathComponent
        let manager = FileManager.default
        let hasEngine = manager.fileExists(atPath: picked.appendingPathComponent("game.wasm").path)
            || manager.fileExists(atPath: picked.appendingPathComponent("8b0b5899ed/game.wasm").path)
        if name == "b" || name == "8b0b5899ed" || name == "shaders" || hasEngine {
            return "You opened the \"\(name)\" folder. Go back up one or two levels and pick the folder that has both \"data\" and \"b\" inside, then tap Open there."
        }
        return "There is no game in \"\(name)\". Pick the folder that has both \"data\" and \"b\" inside (or any folder above it).\n\nEasiest: move your game folder into Files › On My iPhone › GTA V Port. The app finds it there by itself."
    }

    /// Compares a sample of files (the first ones, the biggest ones) with the game's file list.
    private static func check(_ data: URL) -> String? {
        guard let path = EnginePaths.manifest,
              let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
              let files = json["files"] as? [[Any]] else { return "The app's game file list is missing." }
        let entries = files.compactMap { entry -> (String, UInt64)? in
            guard entry.count >= 2, let name = entry[0] as? String, let size = (entry[1] as? NSNumber)?.uint64Value else { return nil }
            return (name, size)
        }
        let sample = Array(entries.prefix(5)) + Array(entries.sorted { $0.1 > $1.1 }.prefix(5))
        for (name, size) in sample {
            let file = data.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) {
                let cloud = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + ".icloud")
                if FileManager.default.fileExists(atPath: cloud.path) {
                    return "Some game files are only in iCloud, not on this iPhone. Move the game folder to Files › On My iPhone › GTA V Port and try again."
                }
                return "The folder is missing game files (for example \(name)). Is the download or unpacking complete?"
            }
            let actual = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if actual != size { return "\(name) has a different size than the game expects. The folder may be incomplete or from another version." }
        }
        return nil
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    private static func relative(_ url: URL, to base: URL) -> String {
        let full = url.standardizedFileURL.path, root = base.standardizedFileURL.path
        guard full.hasPrefix(root) else { return full }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private static func describeLocation(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeNameKey, .volumeIsInternalKey])
        var parts: [String] = []
        if values?.isUbiquitousItem == true { parts.append("iCloud") }
        if let volume = values?.volumeName { parts.append("volume \(volume)") }
        if values?.volumeIsInternal == false { parts.append("external drive") }
        if url.path.contains("/File Provider Storage/") || url.path.contains("/Containers/Shared/AppGroup/") { parts.append("On My iPhone") }
        else if url.path.contains("/Library/CloudStorage/") || url.path.contains("FileProvider") { parts.append("cloud or app provider") }
        return parts.isEmpty ? "location unknown" : parts.joined(separator: ", ")
    }
}
