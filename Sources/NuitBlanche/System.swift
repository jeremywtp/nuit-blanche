import Foundation
import CoreGraphics
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - Commandes système

enum Shell {
    /// Lance une commande et attend sa fin avec posix_spawn + waitpid.
    /// Surtout pas `Process.waitUntilExit()` : il fait tourner la boucle d’événements principale pendant l’attente,
    /// ce qui exécute mises en page et minuteurs au milieu de notre code (réentrance, boucle infinie constatée).
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 15) -> (status: Int32, output: String) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return (-1, "pipe impossible") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO)

        // L’enfant n’hérite que de stdin/stdout/stderr (pas des descripteurs ouverts de l’app),
        // et retrouve les signaux par défaut (l’app ignore SIGTERM/SIGINT/SIGHUP pour s’arrêter proprement).
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(fds[1])
        guard spawned == 0 else {
            close(fds[0])
            return (-1, String(cString: strerror(spawned)))
        }

        // Lecture avec délai maximal : un pmset ou un sudo figé ne doit pas bloquer l’app.
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while true {
            var pollfd = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            let ready = poll(&pollfd, 1, remaining)
            if ready == 0 { timedOut = true; break }
            if ready < 0 { if errno == EINTR { continue } else { break } }
            let count = read(fds[0], &buffer, buffer.count)
            if count > 0 { output.append(buffer, count: count) } else if count == 0 || errno != EINTR { break }
        }
        close(fds[0])
        if timedOut { kill(pid, SIGKILL) }
        // Attente de fin bornée elle aussi (sortie fermée mais processus encore vivant).
        var status: Int32 = 0
        while true {
            let done = waitpid(pid, &status, WNOHANG)
            if done == pid || (done == -1 && errno != EINTR) { break }
            if Date() > deadline.addingTimeInterval(2) {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                timedOut = true
                break
            }
            usleep(5_000)
        }
        if timedOut { return (-1, "délai dépassé") }
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        return (exitCode, String(decoding: output, as: UTF8.self))
    }

    /// Entoure une chaîne de guillemets simples pour un shell POSIX.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - État de l'alimentation

struct PowerSnapshot: Equatable {
    var batteryPercent: Int?
    var onAC = true
    var charging = false
    var lidClosed = false
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPowerMode = false

    var isHot: Bool { thermal == .serious || thermal == .critical }
    var hasBattery: Bool { batteryPercent != nil }
}

enum PowerInfo {
    static func snapshot() -> PowerSnapshot {
        var snap = PowerSnapshot()
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      desc["Type"] as? String == "InternalBattery" else { continue }
                if let current = desc["Current Capacity"] as? Int,
                   let maximum = desc["Max Capacity"] as? Int, maximum > 0 {
                    snap.batteryPercent = Int((Double(current) / Double(maximum) * 100).rounded())
                }
                snap.onAC = (desc["Power Source State"] as? String) == "AC Power"
                snap.charging = desc["Is Charging"] as? Bool ?? false
            }
        }
        snap.lidClosed = clamshellClosed()
        snap.thermal = ProcessInfo.processInfo.thermalState
        snap.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        return snap
    }

    /// Lit `AppleClamshellState` dans IOPMrootDomain : vrai quand l'écran est rabattu.
    static func clamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return false }
        return (value as? Bool) ?? false
    }
}

// MARK: - Veille système (pmset)

enum SleepControl {
    static let pmset = "/usr/bin/pmset"

    /// Valeur actuelle de `SleepDisabled` (réglage posé par `pmset disablesleep`).
    static func isSleepDisabled() -> Bool? {
        let result = Shell.run(pmset, ["-g"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled" {
                return parts.count > 1 && parts[1] == "1"
            }
        }
        return false
    }

    /// Passe par la règle sudoers installée par l'assistant (aucun mot de passe demandé).
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        Shell.run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
    }

    static func displaySleepNow() {
        Shell.run(pmset, ["displaysleepnow"])
    }

    /// Met le Mac en veille tout de suite (pas besoin des droits administrateur).
    static func sleepNow() {
        Shell.run(pmset, ["sleepnow"])
    }
}

// MARK: - Écrans

enum DisplayInfo {
    /// Vrai si un écran externe est actif : écran rabattu + écran externe = mode bureau voulu, on ne force pas la veille.
    static func externalDisplayActive() -> Bool {
        // Écrans en ligne (et pas seulement actifs) : un écran externe en veille d’écran compte toujours.
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

// MARK: - Assertions IOKit (équivalent de caffeinate, libérées si l'app meurt)

final class Assertions {
    static let idleSystem = "PreventUserIdleSystemSleep"
    static let idleDisplay = "PreventUserIdleDisplaySleep"
    static let system = "PreventSystemSleep"

    private var held: [String: IOPMAssertionID] = [:]

    func set(_ type: String, _ on: Bool, reason: String = "Nuit Blanche - maintien en cours") {
        if on, held[type] == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id
            )
            if result == kIOReturnSuccess { held[type] = id }
        } else if !on, let id = held[type] {
            IOPMAssertionRelease(id)
            held[type] = nil
        }
    }

    func releaseAll() {
        for id in held.values { IOPMAssertionRelease(id) }
        held.removeAll()
    }
}

enum ProcessCheck {
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Mémo de 30 s : la vérification lance pgrep, inutile de la refaire toutes les 2 secondes.
    nonisolated(unsafe) private static var activityCache: [Int32: (date: Date, active: Bool)] = [:]

    /// Vrai si l’agent exécute quelque chose : une commande shell (outil Bash de Claude Code, commande Codex,
    /// y compris en arrière-plan) ou le `caffeinate` que Claude Code lance pendant ses longues opérations.
    /// Les serveurs MCP (enfants `node`) ne comptent pas. Constaté : session au travail = `zsh` + `caffeinate`,
    /// session au repos = seulement `node`.
    static func hasActivityChild(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if let cached = activityCache[pid], Date().timeIntervalSince(cached.date) < 30 { return cached.active }
        let result = Shell.run("/usr/bin/pgrep", ["-lP", String(pid)], timeout: 5)
        let busyNames: Set<String> = ["zsh", "bash", "sh", "fish", "caffeinate"]
        let active = result.status == 0 && result.output.split(separator: "\n").contains { line in
            let name = line.split(separator: " ").dropFirst().first.map { String($0.split(separator: "/").last ?? $0) } ?? ""
            return busyNames.contains(name)
        }
        activityCache[pid] = (Date(), active)
        if activityCache.count > 64 { activityCache = activityCache.filter { Date().timeIntervalSince($0.value.date) < 60 } }
        return active
    }

    /// Chemin de l’exécutable d’un processus (vide s’il n’existe plus).
    static func executablePath(_ pid: Int32) -> String {
        guard pid > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }
}
