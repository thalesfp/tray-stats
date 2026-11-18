import Darwin
import Foundation

struct ReadError: Error, CustomStringConvertible {
    let call: String
    let code: kern_return_t

    var description: String { "\(call) failed with \(code)" }
}

struct SystemReader {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let timebase: Timebase
    private let thermal = ThermalSensors()

    init() throws {
        var size: vm_size_t = 0
        let result = host_page_size(host, &size)
        guard result == KERN_SUCCESS else { throw ReadError(call: "host_page_size", code: result) }
        pageSize = UInt64(size)

        var info = mach_timebase_info_data_t()
        let timebaseResult = mach_timebase_info(&info)
        guard timebaseResult == KERN_SUCCESS else {
            throw ReadError(call: "mach_timebase_info", code: timebaseResult)
        }
        timebase = Timebase(numer: info.numer, denom: info.denom)
    }

    func cpuTicks() throws -> CPUTicks {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw ReadError(call: "host_statistics", code: result) }

        let ticks = info.cpu_ticks

        return CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    func memory() throws -> ByteUsage {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw ReadError(call: "host_statistics64", code: result)
        }

        let pages = MemoryPages(
            internalPages: UInt64(info.internal_page_count),
            purgeable: UInt64(info.purgeable_count),
            wired: UInt64(info.wire_count),
            compressed: UInt64(info.compressor_page_count)
        )

        return memoryUsage(
            pages, pageSize: pageSize, physical: ProcessInfo.processInfo.physicalMemory)
    }

    func disk() throws -> ByteUsage {
        let root = URL(fileURLWithPath: "/")
        let values = try root.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])

        guard let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage
        else {
            throw CocoaError(.fileReadUnknown)
        }

        return diskUsage(total: UInt64(total), available: UInt64(max(0, available)))
    }

    func cpuTemperature() throws(TemperatureUnavailable) -> Double {
        guard let celsius = hottestDieTemperature(try thermal.read()) else {
            throw TemperatureUnavailable(reason: "no valid CPU die temperature")
        }

        return celsius
    }

    /// Processes the kernel refuses to describe (other users, root) or that exit mid-scan are left out.
    func processes() -> [ProcessSample] {
        let capacity = proc_listallpids(nil, 0) + 64
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }

        return pids.prefix(Int(max(0, count))).compactMap(sample)
    }

    private func sample(_ pid: pid_t) -> ProcessSample? {
        guard pid > 0 else { return nil }

        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        guard result == 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: 64)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }

        let name = String(decoding: buffer.prefix(Int(length)).map(UInt8.init), as: UTF8.self)
        let cpu = timebase.nanoseconds(usage.ri_user_time + usage.ri_system_time)

        return ProcessSample(
            pid: pid, name: name, cpuNanoseconds: cpu, footprint: usage.ri_phys_footprint)
    }
}
