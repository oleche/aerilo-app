import Darwin
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

// MARK: - Whole-device load (every platform)

/// What the system shares about the device as a whole. It shares nothing about other apps: no
/// list of them, and no memory or processor figures for any app but this one.
enum DeviceLoad {
    /// Memory in use across the device, 0...1.
    static func memoryFraction() -> Double? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let used = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count) + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return nil }
        return min(1, Double(used * UInt64(getpagesize())) / Double(total))
    }

    private static func ticks() -> (busy: UInt64, total: UInt64)? {
        var cpu = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = cpu.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        return (busy, busy + UInt64(t.2))
    }

    /// Processor load across all cores over one second, 0...1.
    static func processorFraction() async -> Double? {
        guard let a = ticks() else { return nil }
        try? await Task.sleep(for: .seconds(1))
        guard let b = ticks(), b.total > a.total else { return nil }
        return Double(b.busy - a.busy) / Double(b.total - a.total)
    }
}
