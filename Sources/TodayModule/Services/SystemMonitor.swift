import Combine
import Darwin
import Foundation
import IslandCore

/// Нагрузка: ЦП (дельта тиков), память, тепловое состояние. Без прав.
struct SystemSample: Equatable, Sendable {
    var cpu: Double      // 0…1
    var memory: Double   // 0…1
    var memoryUsedGB: Double
    var memoryTotalGB: Double
    var thermal: ProcessInfo.ThermalState
}

enum SystemStats {
    struct CPUTicks: Equatable, Sendable {
        var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
        var busy: UInt64 { user + system + nice }
        var total: UInt64 { busy + idle }
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    /// Доля занятости между двумя замерами.
    static func cpuUsage(from a: CPUTicks, to b: CPUTicks) -> Double {
        let total = b.total &- a.total
        guard total > 0, b.total >= a.total else { return 0 }
        return min(1, max(0, Double(b.busy &- a.busy) / Double(total)))
    }

    /// Занятая память как в Мониторе системы: приложения (internal − purgeable) + wired + сжатая.
    static func memory() -> (used: Double, total: Double)? {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = Double(pageSize)
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        let used = (max(0, app) + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        return (used, Double(ProcessInfo.processInfo.physicalMemory))
    }

    static func thermalTitle(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "норм"
        case .fair: return "тепло"
        case .serious: return "жарко"
        case .critical: return "крит"
        @unknown default: return "—"
        }
    }

    /// Заполнение кольца «Нагрев».
    static func thermalLevel(_ s: ProcessInfo.ThermalState) -> Double {
        switch s {
        case .nominal: return 0.25
        case .fair: return 0.5
        case .serious: return 0.75
        case .critical: return 1
        @unknown default: return 0
        }
    }
}

/// Опрос раз в 2 с через общий тикер (`SharedTicker`, пауза во сне/блокировке) — только пока вкладка видна
/// (`setActive`). Своих таймеров нет.
@MainActor
final class SystemMonitor {
    private var tick: AnyCancellable?
    private var last: SystemStats.CPUTicks?
    var onSample: (@MainActor (SystemSample) -> Void)?
    var isActive: Bool { tick != nil }

    func setActive(_ on: Bool) {
        if on, tick == nil {
            // Первый замер — средняя с прошлого показа (или с загрузки), а не ноль.
            sample()
            tick = SharedTicker.shared.subscribe(every: 2) { [weak self] _ in self?.sample() }
        } else if !on {
            tick = nil
        }
    }

    private func sample() {
        let now = SystemStats.cpuTicks()
        var cpu = 0.0
        if let b = now { cpu = SystemStats.cpuUsage(from: last ?? .init(user: 0, system: 0, idle: 0, nice: 0), to: b) }
        last = now
        let mem = SystemStats.memory() ?? (0, 1)
        onSample?(SystemSample(cpu: cpu, memory: mem.total > 0 ? mem.used / mem.total : 0,
                               memoryUsedGB: mem.used / 1_073_741_824, memoryTotalGB: mem.total / 1_073_741_824,
                               thermal: ProcessInfo.processInfo.thermalState))
    }
}
