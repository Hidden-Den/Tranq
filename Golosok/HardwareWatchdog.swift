import Foundation

public enum HardwareSafetyDecision: Equatable {
    case allowed
    case restricted(reason: String)
}

public struct HardwareWatchdog {

    /// Проверка, безопасно ли запускать тяжелый локальный инференс SLM на устройстве
    public static func evaluateInferenceSafety() -> HardwareSafetyDecision {
        let processInfo = ProcessInfo.processInfo
        return evaluateDecision(
            thermalState: processInfo.thermalState,
            isLowPowerMode: processInfo.isLowPowerModeEnabled,
            freeMB: freeMemoryMB()
        )
    }

    /// Детерминированная проверка параметров безопасности (для рабочего цикла и тестирования)
    public static func evaluateDecision(
        thermalState: ProcessInfo.ThermalState,
        isLowPowerMode: Bool,
        freeMB: Int?
    ) -> HardwareSafetyDecision {
        // 1. Проверка термального состояния macOS
        if !isThermalStateSafe(state: thermalState) {
            let reason = thermalState == .critical ? "Критический перегрев устройства" : "Повышенная температура устройства"
            AppLogger.shared.warn("HardwareWatchdog", "Инференс пропущен: \(reason)")
            return .restricted(reason: reason)
        }

        // 2. Проверка режима энергосбережения
        if isLowPowerMode {
            let reason = "Включен режим энергосбережения"
            AppLogger.shared.info("HardwareWatchdog", "Инференс пропущен: \(reason)")
            return .restricted(reason: reason)
        }

        // 3. Проверка доступной физической памяти (порог 1.2 ГБ)
        guard let free = freeMB else {
            let reason = "Не удалось определить объем свободной оперативной памяти"
            AppLogger.shared.warn("HardwareWatchdog", "Инференс пропущен: \(reason)")
            return .restricted(reason: reason)
        }

        if free < 1200 {
            let reason = "Недостаточно свободной оперативной памяти: \(free) МБ"
            AppLogger.shared.warn("HardwareWatchdog", "Инференс пропущен: \(reason)")
            return .restricted(reason: reason)
        }

        return .allowed
    }

    /// Проверка допустимости термального уровня
    public static func isThermalStateSafe(state: ProcessInfo.ThermalState) -> Bool {
        switch state {
        case .nominal, .fair:
            return true
        case .serious, .critical:
            return false
        @unknown default:
            return false
        }
    }

    /// Получение объема свободной оперативной памяти в мегабайтах
    private static func freeMemoryMB() -> Int? {
        var pageSize: vm_size_t = 0
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        var hostSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        guard host_page_size(hostPort, &pageSize) == KERN_SUCCESS else { return nil }

        var vmStat = vm_statistics64()
        let kernStatus = withUnsafeMutablePointer(to: &vmStat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(hostSize)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &hostSize)
            }
        }

        guard kernStatus == KERN_SUCCESS else { return nil }

        let freePages = UInt64(vmStat.free_count) + UInt64(vmStat.inactive_count)
        let freeBytes = freePages * UInt64(pageSize)
        return Int(freeBytes / (1024 * 1024))
    }
}
