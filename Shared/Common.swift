import Foundation

// MARK: - Environment

enum Env {
    /// True in the Mac App Store build. The sandbox decides which features can run.
    /// `--demo --as-store` shows the App Store edition's interface from any build, for screenshots.
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        || (CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--as-store"))
    static let isDemo = CommandLine.arguments.contains("--demo")

    /// The user's real home folder. Inside the sandbox `NSHomeDirectory()` is the app container.
    /// `--home <folder>` points Aerilo at a stand-in home folder, for tests. With it set, Aerilo
    /// only ever works inside that folder: no temp area, no simulators, and its own log goes there.
    static let isHomeOverridden = arg("--home") != nil

    static let realHome: URL = {
        if let override = arg("--home") { return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL }
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }()

    /// True in the edition downloaded from aerilo.app.
    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static func arg(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// The four moments of a breath, shared by every screen that shows the orb.
enum BreathPhase {
    case idle, inhale, exhale, done
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func bytes(_ n: UInt64) -> String { bytes(Int64(min(n, UInt64(Int64.max)))) }
    static func mem(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(n, UInt64(Int64.max))), countStyle: .memory)
    }
    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }
    /// "1 item", "3 items".
    static func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

    static func uptime(_ t: TimeInterval) -> String {
        let days = Int(t / 86_400)
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        let hours = Int(t / 3600)
        return hours <= 1 ? "1 hour" : "\(hours) hours"
    }
}

// MARK: - Timeout

/// Runs `work` and gives up after `seconds`, returning nil. Unlike a task group, this returns on
/// time even when the work ignores cancellation, which the on-device model sometimes does.
enum Timeout {
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func finish(_ value: T?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    static func run<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once(continuation)
            let task = Task { once.finish(await work()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                task.cancel()
                once.finish(nil)
            }
        }
    }
}
