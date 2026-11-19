import AppKit
import Darwin
import Foundation

// MARK: - System

struct SystemSnapshot {
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memUsed: UInt64 = 0
    var memCompressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// 1 normal, 2 warning, 4 critical (the kernel's own scale).
    var pressure: Int = 1
    /// 0...1 across all cores.
    var cpuLoad: Double = 0
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var lowPower = false
    var launchAgents = 0

    var memFraction: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) }
    var diskFreeFraction: Double { diskTotal == 0 ? 1 : Double(diskFree) / Double(diskTotal) }

    /// 0...100. A plain weighted penalty model, so the number can be explained.
    var health: Int {
        var score = 100.0
        if pressure >= 4 { score -= 30 } else if pressure >= 2 { score -= 15 }
        score -= max(0, memFraction - 0.75) * 60
        score -= min(15, Double(swapUsed) / 1_073_741_824 * 2)
        score -= max(0, cpuLoad - 0.5) * 40
        if diskFreeFraction < 0.05 { score -= 25 } else if diskFreeFraction < 0.10 { score -= 15 } else if diskFreeFraction < 0.20 { score -= 6 }
        switch thermal {
        case .serious: score -= 10
        case .critical: score -= 20
        default: break
        }
        if uptime > 14 * 86_400 { score -= 5 }
        return Int(max(5, min(100, score)).rounded())
    }

    /// Why the score is below 100, biggest cost first, in plain words. Mirrors `health` exactly.
    var healthReasons: [String] {
        var parts: [(Double, String)] = []
        if pressure >= 4 { parts.append((30, "memory pressure is critical")) } else if pressure >= 2 { parts.append((15, "memory pressure is high")) }
        let full = max(0, memFraction - 0.75) * 60
        if full >= 1 { parts.append((full, "memory is \(Int(memFraction * 100))% full")) }
        let swap = min(15, Double(swapUsed) / 1_073_741_824 * 2)
        if swap >= 1 { parts.append((swap, "\(Fmt.mem(swapUsed)) was moved to disk")) }
        let busy = max(0, cpuLoad - 0.5) * 40
        if busy >= 1 { parts.append((busy, "the processor is \(Int(cpuLoad * 100))% busy")) }
        if diskFreeFraction < 0.05 { parts.append((25, "storage is almost full")) }
        else if diskFreeFraction < 0.10 { parts.append((15, "less than 10% of storage is free")) }
        else if diskFreeFraction < 0.20 { parts.append((6, "less than 20% of storage is free")) }
        if thermal == .critical { parts.append((20, "the Mac is very hot")) } else if thermal == .serious { parts.append((10, "the Mac is hot")) }
        if uptime > 14 * 86_400 { parts.append((5, "\(Fmt.uptime(uptime)) without a restart")) }
        return parts.sorted { $0.0 > $1.0 }.map(\.1)
    }

    var healthWord: String {
        switch health {
        case 85...: return "Calm"
        case 65..<85: return "Steady"
        case 40..<65: return "Strained"
        default: return "Struggling"
        }
    }
}

final class SystemProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var prevTicks: (busy: UInt64, total: UInt64)?
    private var prevNet: (rx: UInt64, tx: UInt64, at: Date)?

    func read() -> SystemSnapshot {
        lock.lock(); defer { lock.unlock() }
        var s = SystemSnapshot()
        let page = UInt64(getpagesize())

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            // Same sum Activity Monitor shows as "Memory Used": app + wired + compressed.
            let app = UInt64(vm.internal_page_count) &- UInt64(vm.purgeable_count)
            s.memCompressed = UInt64(vm.compressor_page_count) * page
            s.memUsed = min(s.memTotal, (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { s.swapUsed = swap.xsu_used }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 { s.pressure = Int(level) }

        var cpu = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ckr = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if ckr == KERN_SUCCESS {
            let t = cpu.cpu_ticks
            let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
            let total = busy + UInt64(t.2)
            if let p = prevTicks, total > p.total {
                s.cpuLoad = Double(busy - p.busy) / Double(total - p.total)
            }
            prevTicks = (busy, total)
        }

        var fs = statfs()
        if statfs(Env.realHome.path, &fs) == 0 {
            s.diskTotal = Int64(fs.f_blocks) * Int64(fs.f_bsize)
            s.diskFree = Int64(fs.f_bavail) * Int64(fs.f_bsize)
        }

        var boot = timeval()
        var bootSize = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0 {
            s.uptime = Date().timeIntervalSince1970 - Double(boot.tv_sec)
        }

        s.thermal = ProcessInfo.processInfo.thermalState
        s.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        let (rx, tx) = Self.interfaceBytes()
        let now = Date()
        if let p = prevNet {
            let dt = max(0.2, now.timeIntervalSince(p.at))
            // Interface counters are 32-bit and wrap; a wrapped sample reads as zero.
            s.netIn = rx >= p.rx ? Double(rx - p.rx) / dt : 0
            s.netOut = tx >= p.tx ? Double(tx - p.tx) / dt : 0
        }
        prevNet = (rx, tx, now)
        return s
    }

    private static func interfaceBytes() -> (UInt64, UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return (0, 0) }
        defer { freeifaddrs(head) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var cursor = head
        while let c = cursor {
            let name = String(cString: c.pointee.ifa_name)
            if let addr = c.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               name.hasPrefix("en"), let raw = c.pointee.ifa_data {
                let d = raw.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(d.ifi_ibytes)
                tx += UInt64(d.ifi_obytes)
            }
            cursor = c.pointee.ifa_next
        }
        return (rx, tx)
    }
}

// MARK: - Processes

struct ProcInfo: Identifiable, Hashable {
    let pid: pid_t
    var name: String
    var path: String = ""
    /// Percent of one core, as Activity Monitor shows it.
    var cpu: Double = 0
    var footprint: UInt64 = 0
    var isZombie = false
    /// Name of the app bundle this process lives in ("Google Chrome" for a renderer helper).
    var ownerApp: String?
    /// Seconds this process has stayed above 90% CPU without a break.
    var hotSeconds: TimeInterval = 0
    /// Bytes gained over `growthMinutes` when memory only ever went up. Nil when it looks normal.
    var growth: UInt64?
    var growthMinutes: Double = 0

    var id: pid_t { pid }
    var isRunaway: Bool { hotSeconds >= 60 }
    var displayName: String { name }
}

final class ProcessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var prevCPU: [pid_t: (ns: UInt64, at: Date, start: UInt64)] = [:]
    private var history: [pid_t: [(at: Date, bytes: UInt64)]] = [:]
    private var hotSince: [pid_t: Date] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    /// How many processes exposed their resource usage on the last sample (0 means the sandbox blocks it).
    private(set) var readable = 0
    /// True when memory figures are resident size, as they are inside the App Store sandbox.
    private(set) var residentOnly = false

    func sample() -> [ProcInfo] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        var out: [ProcInfo] = []
        var alive = Set<pid_t>()
        var ok = 0
        var usedFallback = false

        for kp in Self.listOwnProcesses() {
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { continue }
            alive.insert(pid)

            var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = pathLen > 0 ? String(cString: pathBuf) : ""
            var name = (path as NSString).lastPathComponent
            if name.isEmpty {
                name = withUnsafePointer(to: kp.kp_proc.p_comm) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
                }
            }
            var info = ProcInfo(pid: pid, name: name, path: path)
            info.isZombie = kp.kp_proc.p_stat == 5 // SZOMB
            info.ownerApp = Self.ownerApp(of: path)

            // Two ways to read a process's usage. The first gives the same "memory footprint"
            // Activity Monitor shows, but the App Store sandbox only answers it for Aerilo itself.
            // The second works inside the sandbox too and gives resident memory, which leaves out
            // compressed pages and so reads a little lower.
            var ns: UInt64?
            var started: UInt64 = 0
            var ru = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if r == 0 {
                info.footprint = ru.ri_phys_footprint
                ns = (ru.ri_user_time + ru.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
                started = ru.ri_proc_start_abstime
            } else {
                var task = proc_taskinfo()
                let want = Int32(MemoryLayout<proc_taskinfo>.size)
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, want) == want {
                    info.footprint = task.pti_resident_size
                    ns = (task.pti_total_user + task.pti_total_system) * UInt64(timebase.numer) / UInt64(timebase.denom)
                    started = UInt64(kp.kp_proc.p_starttime.tv_sec)
                    usedFallback = true
                }
            }
            if let ns {
                ok += 1
                if let p = prevCPU[pid], p.start == started, ns >= p.ns {
                    let dt = now.timeIntervalSince(p.at)
                    if dt > 0.05 { info.cpu = Double(ns - p.ns) / 1e9 / dt * 100 }
                } else {
                    history[pid] = nil
                    hotSince[pid] = nil
                }
                prevCPU[pid] = (ns, now, started)

                if info.cpu >= 90 {
                    if hotSince[pid] == nil { hotSince[pid] = now }
                    info.hotSeconds = now.timeIntervalSince(hotSince[pid]!)
                } else {
                    hotSince[pid] = nil
                }

                var h = history[pid] ?? []
                if h.last.map({ now.timeIntervalSince($0.at) >= 10 }) ?? true {
                    h.append((now, info.footprint))
                    if h.count > 180 { h.removeFirst(h.count - 180) }
                    history[pid] = h
                }
                if let g = Self.growth(in: h) {
                    info.growth = g.bytes
                    info.growthMinutes = g.minutes
                }
            }
            out.append(info)
        }
        readable = ok
        residentOnly = usedFallback
        for pid in prevCPU.keys where !alive.contains(pid) {
            prevCPU[pid] = nil; history[pid] = nil; hotSince[pid] = nil
        }
        return out
    }

    /// A leak can't be proven from outside a process. What can be seen is memory that climbs for
    /// minutes and never comes back: at least 4 minutes, +150 MB, +25%, and 80% of steps not falling.
    static func growth(in h: [(at: Date, bytes: UInt64)]) -> (bytes: UInt64, minutes: Double)? {
        guard h.count >= 12, let first = h.first, let last = h.last else { return nil }
        let minutes = last.at.timeIntervalSince(first.at) / 60
        guard minutes >= 4, last.bytes > first.bytes else { return nil }
        let gained = last.bytes - first.bytes
        guard gained >= 150 * 1_048_576, Double(gained) >= Double(first.bytes) * 0.25 else { return nil }
        var rising = 0
        for i in 1..<h.count where h[i].bytes >= h[i - 1].bytes { rising += 1 }
        guard Double(rising) / Double(h.count - 1) >= 0.8 else { return nil }
        return (gained, minutes)
    }

    static func ownerApp(of path: String) -> String? {
        for part in path.split(separator: "/") where part.hasSuffix(".app") {
            return String(part.dropLast(4))
        }
        return nil
    }

    private static func listOwnProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return Array(procs.prefix(size / stride))
    }

    /// The full command line, for telling a Gradle daemon from any other `java`.
    static func arguments(of pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return "" }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var parts: [String] = []
        while i < size, parts.count < Int(argc) {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            parts.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Network per process

struct NetProc: Identifiable, Hashable {
    let pid: pid_t
    var name: String
    var bytesIn: Double
    var bytesOut: Double
    var id: pid_t { pid }
    var total: Double { bytesIn + bytesOut }
}

enum NetworkProbe {
    /// macOS has no public per-process traffic API. `nettop` is the system's own tool for it and
    /// only runs outside the sandbox, so this is empty in the App Store build.
    static var isAvailable: Bool { !Env.isSandboxed }

    /// Bytes per second for each process, measured over one second.
    static func sample() -> [NetProc] {
        guard isAvailable,
              let text = Shell.run("/usr/bin/nettop", ["-P", "-d", "-x", "-L", "2", "-s", "1", "-J", "bytes_in,bytes_out"], timeout: 8)
        else { return [] }
        // Two CSV blocks, each starting with a header line. The second holds the one-second deltas.
        let blocks = text.components(separatedBy: "\n").split(whereSeparator: { $0.hasPrefix("time,") || $0.hasPrefix(",bytes_in") })
        guard let last = blocks.last else { return [] }
        var out: [NetProc] = []
        for line in last {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3 else { continue }
            // Columns are "name.pid", bytes_in, bytes_out, sometimes with a leading time column.
            let offset = Double(cols[1]) == nil ? 1 : 0
            guard cols.count >= offset + 3, let dot = cols[offset].lastIndex(of: "."),
                  let pid = pid_t(cols[offset][cols[offset].index(after: dot)...]),
                  let rx = Double(cols[offset + 1]), let tx = Double(cols[offset + 2]), rx + tx > 0
            else { continue }
            out.append(NetProc(pid: pid, name: String(cols[offset][..<dot]), bytesIn: rx, bytesOut: tx))
        }
        return out.sorted { $0.total > $1.total }
    }
}

// MARK: - Shell

enum Shell {
    /// Runs a tool and returns its standard output, or nil when it can't start, fails, or times out.
    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // A GUI app does not inherit the terminal's PATH.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
