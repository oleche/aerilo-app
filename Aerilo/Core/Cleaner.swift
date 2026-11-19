import AppKit
import Foundation

enum Tier: Int, CaseIterable {
    /// Cleaned by the one button.
    case safe
    /// Rebuilt by the next build or download; the user ticks these.
    case rebuildable
    /// Never deleted by Aerilo. Shown with "Reveal in Finder".
    case ask

    var title: String {
        switch self {
        case .safe: return "Always safe"
        case .rebuildable: return "Rebuilt on demand"
        case .ask: return "Yours to decide"
        }
    }
    var note: String {
        switch self {
        case .safe: return "The Breathe button clears these."
        case .rebuildable: return "Safe to remove. The next build or download is slower."
        case .ask: return "Aerilo never deletes these."
        }
    }
}

struct CleanItem: Identifiable {
    enum Kind {
        /// Remove what is inside each folder and keep the folder.
        case contents([URL])
        /// Remove each folder itself.
        case folders([URL])
        /// `xcrun simctl delete unavailable`
        case simulators
        /// `xcrun simctl runtime delete` for iOS versions no simulator uses.
        case runtimes
        case reveal(URL)
    }
    let id: String
    let name: String
    let detail: String
    let tier: Tier
    let kind: Kind
    /// Lives outside the home folder or needs a developer tool, so only the direct build can do it.
    var needsFullAccess = false
    /// Returns why the item must be skipped right now, or nil.
    var blocker: ([ProcInfo]) -> String? = { _ in nil }

    /// What this item covers, for the activity log.
    var paths: [String] {
        switch kind {
        case .contents(let urls), .folders(let urls): return urls.map(\.path)
        case .reveal(let url): return [url.path]
        case .simulators: return ["xcrun simctl delete unavailable"]
        case .runtimes: return ["xcrun simctl runtime delete (unused runtimes)"]
        }
    }
}

enum Cleaner {
    // MARK: Home folder access (sandbox)

    private static let bookmarkKey = "homeBookmark"
    private static var scopedHome: URL?

    /// The home folder when Aerilo may read and write inside it, else nil.
    static var home: URL? {
        if !Env.isSandboxed { return Env.realHome }
        if let scopedHome { return scopedHome }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        scopedHome = url
        return url
    }

    /// Asks once for the home folder. The sandbox gives no other way to reach caches in it.
    @MainActor static func requestHomeAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.directoryURL = Env.realHome
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        panel.message = "Choose your Home folder so Aerilo can measure and clear caches inside it."
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL.path == Env.realHome.standardizedFileURL.path,
              let data = try? url.bookmarkData(options: .withSecurityScope) else { return false }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        scopedHome = nil
        return home != nil
    }

    // MARK: System temp folder access (sandbox)

    private static let tempKey = "tempBookmark"
    private static var scopedTemp: URL?

    /// `/var/folders/xx/yyyy`, the per-user area that holds the C, T and X folders. Found from the
    /// user cache folder, which inside the sandbox has the app's own name appended.
    static var tempRootPath: String {
        var parts = URL(fileURLWithPath: confstr(_CS_DARWIN_USER_CACHE_DIR)).standardizedFileURL.pathComponents
        if let c = parts.lastIndex(of: "C") { parts.removeSubrange(c...) }
        return NSString.path(withComponents: parts)
    }

    /// The per-user temp area when Aerilo may work inside it, else nil.
    static var tempRoot: URL? {
        if Env.isHomeOverridden { return nil }
        if !Env.isSandboxed { return URL(fileURLWithPath: tempRootPath, isDirectory: true) }
        if let scopedTemp { return scopedTemp }
        guard let data = UserDefaults.standard.data(forKey: tempKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        scopedTemp = url
        return url
    }

    /// Optional, App Store edition only: lets Aerilo clear the Chrome signing copy and test leftovers.
    @MainActor static func requestTempAccess() -> Bool {
        let root = URL(fileURLWithPath: tempRootPath, isDirectory: true)
        let panel = NSOpenPanel()
        panel.directoryURL = root
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        panel.message = "This is your Mac's temporary folder. Click Allow without changing the selection so Aerilo can clear leftovers apps left inside it."
        guard panel.runModal() == .OK, let url = panel.url,
              url.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path,
              let data = try? url.bookmarkData(options: .withSecurityScope) else { return false }
        UserDefaults.standard.set(data, forKey: tempKey)
        scopedTemp = nil
        return tempRoot != nil
    }

    // MARK: Catalogue

    static func items() -> [CleanItem] {
        guard let home else { return [] }
        let fm = FileManager.default
        func h(_ path: String) -> URL { home.appendingPathComponent(path) }
        func running(_ names: [String], args: [String] = []) -> ([ProcInfo]) -> String? {
            { procs in
                for p in procs {
                    if names.contains(p.name) { return "\(p.name) is running" }
                    if !args.isEmpty, ["java", "node"].contains(p.name) {
                        let line = ProcessProbe.arguments(of: p.pid)
                        if let hit = args.first(where: { line.contains($0) }) { return "\(hit) is running" }
                    }
                }
                return nil
            }
        }
        let caches = h("Library/Caches")
        let updaters = ((try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".ShipIt") }

        // Every other app's cache folder, except apps that are open now, Apple's own, and the ones
        // listed separately. An open app may be writing to its cache, so it is left alone.
        let open = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let listed: Set<String> = ["Homebrew", "pip", "Yarn", "CocoaPods"]
        let appCaches = ((try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter { url in
            let name = url.lastPathComponent
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            return !listed.contains(name) && !name.hasSuffix(".ShipIt") && !name.hasPrefix("com.apple.") && !name.hasPrefix("app.aerilo.")
                && !open.contains(name) && !open.contains { name.hasPrefix($0 + ".") }
        }

        var list: [CleanItem] = [
            // Each item is skipped while the tool that owns it is at work, so nothing is pulled from under it.
            CleanItem(id: "derived", name: "Xcode build data", detail: "DerivedData. The next build takes longer.", tier: .safe,
                      kind: .contents([h("Library/Developer/Xcode/DerivedData")]), blocker: running(["Xcode", "xcodebuild", "swift-build"])),
            CleanItem(id: "npm", name: "npm cache", detail: "Downloaded packages, fetched again when needed.", tier: .safe,
                      kind: .contents([h(".npm/_cacache")]), blocker: running(["npm"], args: ["npm-cli", "/npm ", "npx", "pnpm"])),
            CleanItem(id: "yarn", name: "Yarn cache", detail: "Downloaded packages, fetched again when needed.", tier: .safe,
                      kind: .contents([h("Library/Caches/Yarn")]), blocker: running(["yarn"], args: ["yarn"])),
            CleanItem(id: "brew", name: "Homebrew downloads", detail: "Installers Homebrew already used.", tier: .safe,
                      kind: .contents([h("Library/Caches/Homebrew")]), blocker: running(["brew", "ruby"])),
            CleanItem(id: "pip", name: "pip cache", detail: "Downloaded Python packages.", tier: .safe,
                      kind: .contents([h("Library/Caches/pip")]), blocker: running(["pip", "pip3"])),
            CleanItem(id: "updaters", name: "App update leftovers", detail: "Installers that apps kept after updating.", tier: .safe,
                      kind: .contents(updaters), blocker: running(["ShipIt"])),
            CleanItem(id: "pods", name: "CocoaPods cache", detail: "The next iOS build downloads its pods again.", tier: .rebuildable,
                      kind: .contents([h("Library/Caches/CocoaPods")]), blocker: running(["pod", "xcodebuild"])),
            CleanItem(id: "gradle", name: "Gradle caches", detail: "The next Android build downloads them again.", tier: .rebuildable,
                      kind: .contents([h(".gradle/caches")]), blocker: running(["studio"], args: ["GradleDaemon"])),
            CleanItem(id: "devicesupport", name: "iOS device support", detail: "Debug symbols for devices, copied again on connect.", tier: .rebuildable,
                      kind: .contents([h("Library/Developer/Xcode/iOS DeviceSupport")])),
            CleanItem(id: "appcaches", name: "Caches of closed apps", detail: "What other apps stored to open faster. Each app rebuilds its own when it next opens.", tier: .rebuildable,
                      kind: .contents(appCaches)),
            CleanItem(id: "reports", name: "Old crash reports", detail: "Reports macOS wrote when an app crashed.", tier: .rebuildable,
                      kind: .contents([h("Library/Logs/DiagnosticReports")])),
            CleanItem(id: "chromedata", name: "Chrome profile", detail: "Your bookmarks, history and logins. Clear browsing data inside Chrome instead.", tier: .ask,
                      kind: .reveal(h("Library/Application Support/Google/Chrome"))),
            CleanItem(id: "archives", name: "Xcode archives", detail: "Keep the ones for shipped releases: they hold crash symbols.", tier: .ask,
                      kind: .reveal(h("Library/Developer/Xcode/Archives"))),
        ]

        // /var/folders/xx/yy/{C,T,X}: the per-user cache, temp and code-sign-clone folders. The
        // App Store edition reaches them only after the user allows that folder too.
        if let root = tempRoot {
            let chromeClone = root.appendingPathComponent("X/com.google.Chrome.code_sign_clone")
            let testOutput = ((try? fm.contentsOfDirectory(at: root.appendingPathComponent("T"), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("maestro_xctestrunner_") }
            list.insert(contentsOf: [
                CleanItem(id: "chromeclone", name: "Chrome signing copy", detail: "A copy Chrome leaves behind. Cleared only while Chrome is closed.", tier: .safe,
                          kind: .folders([chromeClone]), needsFullAccess: true, blocker: running(["Google Chrome"])),
                CleanItem(id: "testoutput", name: "Test runner leftovers", detail: "Temporary output from UI test runs.", tier: .safe,
                          kind: .folders(testOutput), needsFullAccess: true, blocker: running(["xcodebuild", "maestro"], args: ["eas-cli", "maestro"])),
            ], at: 0)
        }
        if !Env.isSandboxed, !Env.isHomeOverridden {
            // Simulators can only be removed through Xcode's own tool, which the sandbox cannot run.
            list.insert(CleanItem(id: "simulators", name: "Unusable simulators", detail: "Simulators of iOS versions that are no longer installed.", tier: .safe,
                                  kind: .simulators, needsFullAccess: true), at: 0)
            list.append(CleanItem(id: "runtimes", name: "Unused simulator versions", detail: "iOS versions that no simulator uses. Xcode downloads them again if you need them.",
                                  tier: .rebuildable, kind: .runtimes, needsFullAccess: true, blocker: running(["Simulator", "xcodebuild"])))
        }
        return list
    }

    private static func confstr(_ name: Int32) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        _ = Darwin.confstr(name, &buf, buf.count)
        return String(cString: buf)
    }

    // MARK: Measure

    static func measure(_ item: CleanItem) -> Int64 {
        switch item.kind {
        case .contents(let urls), .folders(let urls):
            return urls.reduce(0) { $0 + size(of: $1) }
        case .reveal(let url):
            return size(of: url)
        case .simulators:
            return unavailableSimulators().reduce(0) { $0 + size(of: $1) }
        case .runtimes:
            return unusedRuntimes().reduce(0) { $0 + $1.bytes }
        }
    }

    /// Allocated size of everything under `url`. The enumerator does not follow symlinks.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            if let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private static func unavailableSimulators() -> [URL] {
        guard let json = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 30),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.values.joined().compactMap { device in
            // Only devices simctl itself reports as unavailable. A booted simulator is never in this list.
            guard device["isAvailable"] as? Bool == false, let path = device["dataPath"] as? String else { return nil }
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
    }

    /// Installed simulator runtimes that no available simulator device uses. If either question
    /// to simctl fails, the answer is "none": a failed lookup must never read as "nothing uses it".
    static func unusedRuntimes() -> [(id: String, bytes: Int64)] {
        guard let devicesJSON = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], timeout: 30),
              let devicesRoot = try? JSONSerialization.jsonObject(with: Data(devicesJSON.utf8)) as? [String: Any],
              let devices = devicesRoot["devices"] as? [String: [[String: Any]]],
              let runtimesJSON = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 30),
              let runtimes = try? JSONSerialization.jsonObject(with: Data(runtimesJSON.utf8)) as? [String: [String: Any]]
        else { return [] }
        let used = Set(devices.filter { !$0.value.isEmpty }.keys)
        return runtimes.values.compactMap { r in
            guard r["deletable"] as? Bool == true, r["state"] as? String == "Ready",
                  let runtime = r["runtimeIdentifier"] as? String, !used.contains(runtime),
                  let id = r["identifier"] as? String else { return nil }
            return (id, (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// True when macOS has downloaded an update and is holding space for it until it is installed.
    static func hasPreparedUpdate() -> Bool {
        guard !Env.isSandboxed, let out = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 10) else { return false }
        return out.contains("MSUPrepareUpdate")
    }

    // MARK: Clean

    /// The last line of defence: whatever the catalogue says, Aerilo deletes only inside a known
    /// cache location, at least two folders below the home folder or inside the per-user temp area.
    static func isSafeTarget(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = Env.realHome.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix(home + "/") {
            let parts = path.dropFirst(home.count + 1).split(separator: "/")
            guard parts.count >= 2, !parts.contains("..") else { return false }
            let allowed = ["Library/Caches/", "Library/Logs/DiagnosticReports", "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/iOS DeviceSupport",
                           ".npm/_cacache", ".gradle/caches"]
            let relative = parts.joined(separator: "/")
            return allowed.contains { relative == $0 || relative.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        // /var/folders/xx/yyyy/{T,X}/name, with or without the /private prefix macOS puts in front.
        let parts = (path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path).split(separator: "/")
        return parts.count >= 6 && parts[0] == "var" && parts[1] == "folders" && ["T", "X"].contains(String(parts[4])) && !parts.contains("..")
    }

    /// Removes the item. Errors on single files are skipped: a cache file in use stays where it is.
    static func clean(_ item: CleanItem) {
        let fm = FileManager.default
        switch item.kind {
        case .contents(let urls):
            for dir in urls where isSafeTarget(dir) {
                // Refuse a folder that is itself a symlink, so nothing outside the target is touched.
                guard (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
                for child in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: child)
                }
            }
        case .folders(let urls):
            for dir in urls where isSafeTarget(dir) { try? fm.removeItem(at: dir) }
        case .simulators:
            // Only through simctl, never by deleting inside CoreSimulator/Devices.
            Shell.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 300)
        case .runtimes:
            for runtime in unusedRuntimes() {
                Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", runtime.id], timeout: 300)
            }
        case .reveal:
            break
        }
    }
}
