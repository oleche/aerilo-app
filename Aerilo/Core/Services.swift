import AppKit
import Observation
import ServiceManagement
import UserNotifications

// MARK: - Permissions

/// What Aerilo may be allowed to do, and where the user allows it. macOS has no install-time
/// permissions: each one is asked for on first use, and Settings shows them all in one place.
enum Permissions {
    /// Full Disk Access lets the direct edition clear other apps' leftovers without a prompt per app.
    /// The privacy database is only readable with it, which makes it a reliable check.
    static var hasFullDiskAccess: Bool {
        guard !Env.isSandboxed else { return false }
        let db = Env.realHome.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: db) else { return false }
        try? handle.close()
        return true
    }

    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    static func openNotifications() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }

    // Launch at login

    static var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func setLaunchAtLogin(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            Audit.record("settings", ["name": "launch at login", "value": on])
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Notifications

/// A quiet warning when the Mac is running out of room. It never cleans anything by itself.
enum Notifier {
    static let enabledKey = "notifyEnabled"
    static let thresholdKey = "notifyThresholdGB"
    private static let lastKey = "notifyLast"

    static var thresholdGB: Int {
        let v = UserDefaults.standard.integer(forKey: thresholdKey)
        return v == 0 ? 15 : v
    }

    static func authorized() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }

    /// Asks macOS for permission. Returns whether notifications are allowed afterwards.
    static func request() async -> Bool {
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        Audit.record("settings", ["name": "notifications", "value": ok])
        return ok
    }

    /// Called on every monitor tick. Sends at most one notification every six hours.
    static func check(_ s: SystemSnapshot) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledKey), s.diskTotal > 0 else { return }
        let low = s.diskFree < Int64(thresholdGB) << 30
        let critical = s.pressure >= 4
        guard low || critical else { return }
        guard Date().timeIntervalSince1970 - defaults.double(forKey: lastKey) > 6 * 3600 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: lastKey)

        let content = UNMutableNotificationContent()
        content.title = low ? "Your Mac is short on space" : "Your Mac is short on memory"
        content.body = low ? "\(Fmt.bytes(s.diskFree)) of storage is free. Open Aerilo and tap Breathe."
                           : "Memory pressure is critical. Open Aerilo to see which app is holding the most."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "aerilo.low", content: content, trigger: nil))
        Audit.record("notify", ["title": content.title])
    }
}

// MARK: - Updates (direct edition)

/// The App Store updates its own edition. The edition from aerilo.app asks the site once a day
/// whether a newer version exists and, if so, offers the download. It never installs by itself:
/// the user opens the disk image from the project's GitHub releases, so macOS checks the new copy like the first one.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let autoKey = "updateAuto"
    #if AERILO_DIRECT
    static let feed = URL(string: "https://aerilo.app/appcast.json")!
    #endif

    struct Release {
        let version: String
        let url: URL
        let notes: String
    }

    static var isAvailable: Bool {
        #if AERILO_DIRECT
        return true
        #else
        return false
        #endif
    }

    var release: Release?
    var checking = false
    var message = ""

    static var automatic: Bool {
        UserDefaults.standard.object(forKey: autoKey) == nil ? true : UserDefaults.standard.bool(forKey: autoKey)
    }

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// True when `a` is a later version than `b` ("1.10.0" is later than "1.9.2").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func checkDailyIfEnabled() async {
        guard Self.isAvailable, Self.automatic, !Env.isDemo else { return }
        let last = UserDefaults.standard.double(forKey: "updateLast")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        await check()
    }

    func check() async {
        #if AERILO_DIRECT
        guard Self.isAvailable, !checking else { return }
        checking = true
        defer { checking = false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateLast")
        var request = URLRequest(url: Self.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Aerilo/\(current)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String,
              let link = (obj["url"] as? String).flatMap(URL.init(string:)),
              // Only ever send people to our own site or our own GitHub releases, over https.
              link.scheme == "https",
              link.host == "aerilo.app" || (link.host == "github.com" && link.path.hasPrefix("/oleche/aerilo-app/releases/"))
        else {
            message = "Couldn't reach aerilo.app. Try again later."
            Audit.record("update.check", ["result": "unreachable"])
            return
        }
        if Self.isNewer(version, than: current) {
            release = Release(version: version, url: link, notes: obj["notes"] as? String ?? "")
            message = "Aerilo \(version) is available."
        } else {
            release = nil
            message = "Aerilo \(current) is the latest version."
        }
        Audit.record("update.check", ["result": message])
        #endif
    }

    func download() {
        guard let release else { return }
        NSWorkspace.shared.open(release.url)
        Audit.record("action.open", ["url": release.url.absoluteString])
    }
}
