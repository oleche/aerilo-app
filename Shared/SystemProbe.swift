#if os(macOS)
import Darwin
import Foundation

// The Mac's whole-system readings. Shared so the widget shows the same health score as the app.

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
#endif
