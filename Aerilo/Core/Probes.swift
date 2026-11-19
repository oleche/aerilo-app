import AppKit
import Darwin
import Foundation

// MARK: - Processes

struct ProcInfo: Identifiable, Hashable {
    let pid: pid_t
    var name: String
    var path: String = ""
    /// The process that started this one.
    var parent: pid_t = 0
    /// When this process started, in microseconds. With the pid it names one process for good: the system
    /// hands a finished process's pid to a new one, and the start time is how Aerilo tells them apart.
    var born: UInt64 = 0
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
            info.parent = kp.kp_eproc.e_ppid
            info.born = Self.birth(kp)
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

    private static func birth(_ kp: kinfo_proc) -> UInt64 {
        UInt64(kp.kp_proc.p_starttime.tv_sec) * 1_000_000 + UInt64(kp.kp_proc.p_starttime.tv_usec)
    }

    /// The start time of the process that holds this pid right now, or nil when there is none.
    static func birth(of pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        return birth(kp)
    }

    /// True when `pid` is still the process Aerilo looked at, not a newer one that was given the same number.
    static func isSame(pid: pid_t, born: UInt64) -> Bool {
        guard born > 0, let now = birth(of: pid) else { return false }
        return now == born
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
    /// Runs a tool and returns its standard output, or nil when it can't start, fails, or runs out of time.
    ///
    /// It always returns by `timeout` plus a few seconds. The tool runs in its own process group, so when
    /// time is up the tool and everything it started are asked to stop, then killed, and the pipe is closed
    /// from this side: a child that ignores the request, or a grandchild that keeps the pipe open, can no
    /// longer hold a clean-up forever.
    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Its own process group, and none of Aerilo's other open files.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)

        var env = ProcessInfo.processInfo.environment
        // A GUI app does not inherit the terminal's PATH.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        var argv: [UnsafeMutablePointer<CChar>?] = ([tool] + args).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, tool, &actions, &attr, &argv, &envp)
        close(writeEnd)
        guard spawned == 0 else { close(readEnd); return nil }

        // Read with a deadline: poll says when there is something to read, so a read never blocks.
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var finished = false
        while !finished {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            var watch = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watch, 1, Int32(min(left, 1) * 1000))
            if ready < 0 && errno != EINTR { break }
            if ready > 0 {
                let n = read(readEnd, &buffer, buffer.count)
                if n > 0 { data.append(buffer, count: n) } else if n == 0 || errno != EINTR { finished = true }
            }
        }
        close(readEnd)

        // Wait for the exit within what is left of the time; then ask, then insist. The exit is watched
        // without collecting it, so the process group still belongs to this tool when it is signalled.
        func exited(within seconds: TimeInterval) -> Bool {
            let until = Date().addingTimeInterval(seconds)
            repeat {
                var info = siginfo_t()
                let r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if (r == 0 && info.si_pid == pid) || (r < 0 && errno != EINTR) { return true }
                usleep(20_000)
            } while Date() < until
            return false
        }
        var onTime = finished && exited(within: max(0.2, deadline.timeIntervalSinceNow))
        // Whatever is left in the group goes too: the tool itself when it ran over, or helpers it left behind.
        kill(-pid, SIGTERM)
        var gone = onTime
        if !gone { gone = exited(within: 2) }
        if !gone {
            kill(-pid, SIGKILL)
            gone = exited(within: 2)
        }
        var status: Int32 = 0
        if gone {
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        } else {
            // It cannot be collected yet; do that whenever it ends, so nothing is left half-finished in the process table.
            let child = pid
            DispatchQueue.global(qos: .utility).async { var s: Int32 = 0; while waitpid(child, &s, 0) < 0 && errno == EINTR {} }
            onTime = false
        }
        onTime = onTime && (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 0
        return onTime ? String(decoding: data, as: UTF8.self) : nil
    }
}
