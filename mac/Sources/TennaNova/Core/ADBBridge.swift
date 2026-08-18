import Foundation

struct ADBDevice: Equatable {
    let serial: String
    let state: String
}

enum USBBridgeStatus: Equatable {
    case searching
    case adbUnavailable
    case waitingForPhone
    case needsAuthorization
    case multiplePhones
    case ready(serial: String)
    case failed(String)

    var label: String {
        switch self {
        case .searching:             return "Checking USB…"
        case .adbUnavailable:        return "USB helper unavailable — using LAN"
        case .waitingForPhone:       return "Connect your phone by USB, or use LAN"
        case .needsAuthorization:    return "Allow USB debugging on your phone"
        case .multiplePhones:        return "Connect only one Tennanova phone"
        case .ready:                 return "USB connection ready"
        case .failed(let message):   return "USB: \(message)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Keeps the Android loopback endpoint connected to the local TLS server.
///
/// ADB is never used for app privileges. It is only a local transport helper, equivalent
/// to running `adb reverse tcp:18777 tcp:18777`. Every poll re-validates that exactly one
/// authorized device with TennaNova installed is present, so detach/reattach and adb-server
/// restarts recover without terminal commands.
final class ADBBridge {
    var onStatus: ((USBBridgeStatus) -> Void)?

    private let queue = DispatchQueue(label: "com.tennanova.adb-bridge")
    private let executable: URL?
    private var timer: DispatchSourceTimer?
    private var port = Int(Proto.defaultPort)
    private var lastStatus: USBBridgeStatus?

    var isAvailable: Bool { executable != nil }

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        executable = Self.findExecutable(bundle: bundle, environment: environment)
    }

    func start(port: Int) {
        self.port = port
        guard executable != nil else {
            emit(.adbUnavailable)
            return
        }
        guard timer == nil else { return }

        emit(.searching)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(300))
        source.setEventHandler { [weak self] in self?.probe() }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func probe() {
        guard let executable else { return }
        let listing = Self.run(executable, arguments: ["devices", "-l"])
        guard listing.status == 0 else {
            emit(.failed(Self.shortError(listing.output)))
            return
        }

        let devices = Self.parseDevices(listing.output)
        let authorized = devices.filter { $0.state == "device" }
        let unauthorized = devices.filter { $0.state == "unauthorized" }
        var tennaPhones: [ADBDevice] = []

        for device in authorized {
            let check = Self.run(
                executable,
                arguments: ["-s", device.serial, "shell", "pm", "path", "com.tennanova"]
            )
            if check.status == 0 && check.output.contains("package:") {
                tennaPhones.append(device)
            }
        }

        if tennaPhones.count > 1 {
            emit(.multiplePhones)
            return
        }
        guard let phone = tennaPhones.first else {
            emit(unauthorized.isEmpty ? .waitingForPhone : .needsAuthorization)
            return
        }

        let endpoint = "tcp:\(port)"
        let reverse = Self.run(
            executable,
            arguments: ["-s", phone.serial, "reverse", endpoint, endpoint]
        )
        if reverse.status == 0 {
            emit(.ready(serial: phone.serial))
        } else {
            emit(.failed(Self.shortError(reverse.output)))
        }
    }

    private func emit(_ status: USBBridgeStatus) {
        guard status != lastStatus else { return }
        lastStatus = status
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }

    static func parseDevices(_ output: String) -> [ADBDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] != "List", !fields[0].hasPrefix("*") else {
                return nil
            }
            return ADBDevice(serial: String(fields[0]), state: String(fields[1]))
        }
    }

    private static func findExecutable(
        bundle: Bundle,
        environment: [String: String]
    ) -> URL? {
        var candidates: [URL] = []
        if let bundled = bundle.url(
            forResource: "adb",
            withExtension: nil,
            subdirectory: "platform-tools"
        ) {
            candidates.append(bundled)
        }
        if let sdk = environment["ANDROID_SDK_ROOT"] ?? environment["ANDROID_HOME"] {
            candidates.append(URL(fileURLWithPath: sdk).appendingPathComponent("platform-tools/adb"))
        }
        candidates.append(
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Android/sdk/platform-tools/adb")
        )
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/adb"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/adb"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private static func run(_ executable: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }

    private static func shortError(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "tunnel setup failed" : String(text.prefix(120))
    }
}
