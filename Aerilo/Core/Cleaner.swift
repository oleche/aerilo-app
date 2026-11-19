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
    /// Returns why the item must be skipped right now, or nil. Asked with a fresh list of processes
    /// immediately before the item is cleared.
    var blocker: ([ProcInfo]) -> String? = { _ in nil }
    /// Asked for each folder at the moment it is about to be cleared: true leaves that folder alone.
    var inUse: (URL) -> Bool = { _ in false }

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
                    // Many tools are a script run by an interpreter, so the name to look for is in the arguments.
                    if !args.isEmpty, ["java", "node", "ruby"].contains(p.name) || p.name.lowercased().hasPrefix("python") {
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
        let open = openApps()
        let listed: Set<String> = ["Homebrew", "pip", "Yarn", "CocoaPods"]
        let appCaches = ((try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).filter { url in
            let name = url.lastPathComponent
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            // Only folders named after an app ("com.example.App"). Others, such as a browser's "Google" or a
            // tool's "pypoetry", cannot be matched to a running program and may hold things that do not rebuild
            // themselves (whole Python environments, downloaded test browsers), so Aerilo leaves them alone.
            return looksLikeAppID(name) && !listed.contains(name) && !name.hasSuffix(".ShipIt") && !name.hasPrefix("com.apple.") && !name.hasPrefix("app.aerilo.")
                && !isOpen(name, among: open)
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
                      kind: .contents([h("Library/Caches/Homebrew")]), blocker: running(["brew"], args: ["/brew.rb", "Homebrew/"])),
            CleanItem(id: "pip", name: "pip cache", detail: "Downloaded Python packages.", tier: .safe,
                      kind: .contents([h("Library/Caches/pip")]), blocker: running(["pip", "pip3"], args: ["/pip", "-m pip", " pip "])),
            CleanItem(id: "updaters", name: "App update leftovers", detail: "Installers that apps kept after updating.", tier: .safe,
                      kind: .contents(updaters), blocker: running(["ShipIt"])),
            CleanItem(id: "pods", name: "CocoaPods cache", detail: "The next iOS build downloads its pods again.", tier: .rebuildable,
                      kind: .contents([h("Library/Caches/CocoaPods")]), blocker: running(["pod", "xcodebuild"], args: ["/pod ", "/bin/pod", "cocoapods"])),
            CleanItem(id: "gradle", name: "Gradle caches", detail: "The next Android build downloads them again.", tier: .rebuildable,
                      kind: .contents([h(".gradle/caches")]), blocker: running(["studio"], args: ["GradleDaemon"])),
            CleanItem(id: "devicesupport", name: "iOS device support", detail: "Debug symbols for devices, copied again on connect.", tier: .rebuildable,
                      kind: .contents([h("Library/Developer/Xcode/iOS DeviceSupport")])),
            CleanItem(id: "appcaches", name: "Caches of closed apps", detail: "What other apps stored to open faster. Each app rebuilds its own when it next opens.", tier: .rebuildable,
                      kind: .contents(appCaches),
                      // The list above was made when Storage was measured. An app may have been opened since, so
                      // each folder is checked again at the moment it would be cleared.
                      inUse: { isOpen($0.lastPathComponent, among: openApps()) }),
            CleanItem(id: "reports", name: "Crash reports", detail: "Every report macOS wrote when an app crashed or hung, recent ones included.", tier: .rebuildable,
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
            // Not cleared by the one button: right after an Xcode update, simulators can read as unusable for a
            // while, and removing one also removes the apps and data inside it.
            list.append(CleanItem(id: "simulators", name: "Unusable simulators", detail: "Simulators of iOS versions that are no longer installed, with the apps and data inside them.",
                                  tier: .rebuildable, kind: .simulators, needsFullAccess: true, blocker: running(["Xcode", "Simulator", "xcodebuild"])))
            list.append(CleanItem(id: "runtimes", name: "Unused simulator versions", detail: "iOS versions that no simulator uses. Xcode downloads them again if you need them.",
                                  tier: .rebuildable, kind: .runtimes, needsFullAccess: true, blocker: running(["Simulator", "xcodebuild"])))
        }
        return list
    }

    /// Bundle identifiers of the apps that are open right now.
    static func openApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// "com.example.App": at least three parts of letters, digits, dashes or underscores, joined by dots.
    static func looksLikeAppID(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil
    }

    /// A cache folder is named after its app ("com.example.App") or a part of it ("com.example.App.helper").
    static func isOpen(_ cacheName: String, among open: Set<String>) -> Bool {
        open.contains(cacheName) || open.contains { cacheName.hasPrefix($0 + ".") }
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

    /// True when Apple's developer tools are installed. Asking `xcrun` without them makes macOS offer to
    /// install them, which a clean-up must never cause.
    static let hasDeveloperTools: Bool = {
        guard let path = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 10)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path + "/usr/bin/simctl") || FileManager.default.fileExists(atPath: path + "/usr/bin/xcrun")
    }()

    private static func unavailableSimulators() -> [URL] {
        guard hasDeveloperTools, let json = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"], timeout: 30),
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
        guard hasDeveloperTools, let devicesJSON = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], timeout: 30),
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
        // The temp area: only inside this user's own T and X folders, and only below them. The root is the
        // exact folder macOS reports for this user, not anything that merely looks like one.
        guard !Env.isHomeOverridden else { return false }
        let root = URL(fileURLWithPath: tempRootPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard root.split(separator: "/").count >= 4 else { return false }
        for area in ["T", "X"] where path.hasPrefix("\(root)/\(area)/") {
            let rest = path.dropFirst(root.count + area.count + 2).split(separator: "/")
            return !rest.isEmpty && !rest.contains("..")
        }
        return false
    }

    /// Removes the item. Errors on single files are skipped.
    ///
    /// A file an app has open is not protected by that: macOS lets it be removed. What protects a working
    /// app is `blocker` and `inUse`, both asked immediately before the folder is cleared. A tool that
    /// starts in the instant between that question and the removal can still lose cache files; they are
    /// caches, and it fetches or rebuilds them.
    static func clean(_ item: CleanItem) {
        switch item.kind {
        case .contents(let urls):
            for dir in urls where !item.inUse(dir) { remove(dir, keepFolder: true) }
        case .folders(let urls):
            for dir in urls where !item.inUse(dir) { remove(dir, keepFolder: false) }
        case .simulators:
            // Only through simctl, never by deleting inside CoreSimulator/Devices.
            guard hasDeveloperTools else { return }
            Shell.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 300)
        case .runtimes:
            for runtime in unusedRuntimes() where hasDeveloperTools {
                Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", runtime.id], timeout: 300)
            }
        case .reveal:
            break
        }
    }

    /// Empties a folder, and removes the folder too unless `keepFolder`.
    ///
    /// The folder is opened once and everything is done through that open handle, by name, never by path.
    /// So the check and the removal are about the same folder: swapping the folder or one of its parents
    /// for a link after the check cannot send the removal somewhere else. Links inside are removed as
    /// links and never followed, and the walk never crosses onto another volume.
    static func remove(_ url: URL, keepFolder: Bool) {
        // Refuses a folder that is itself a link.
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // Where the open handle really is, whatever the path said.
        guard let real = path(of: fd), isSafeTarget(URL(fileURLWithPath: real)) else { return }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        empty(fd, volume: info.st_dev, depth: 0)
        guard !keepFolder else { return }
        let parent = (real as NSString).deletingLastPathComponent
        let parentFD = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFD >= 0 else { return }
        defer { close(parentFD) }
        guard path(of: parentFD) == parent else { return }
        unlinkat(parentFD, (real as NSString).lastPathComponent, AT_REMOVEDIR)
    }

    /// The real location of an open folder.
    private static func path(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return fcntl(fd, F_GETPATH, &buffer) == 0 ? String(cString: buffer) : nil
    }

    private static func empty(_ fd: Int32, volume: dev_t, depth: Int) {
        // Names first, then removal, so the listing is not disturbed while it is read.
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else { if copy >= 0 { close(copy) }; return }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        closedir(dir)
        for name in names {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                // A folder on another volume is a mount point: not Aerilo's to empty.
                guard info.st_dev == volume, depth < 128 else { continue }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if child >= 0 {
                    empty(child, volume: volume, depth: depth + 1)
                    close(child)
                }
                unlinkat(fd, name, AT_REMOVEDIR)
            } else {
                unlinkat(fd, name, 0)
            }
        }
    }
}
