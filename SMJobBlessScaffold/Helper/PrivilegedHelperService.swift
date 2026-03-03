import Foundation

final class PrivilegedHelperService: NSObject, PrivilegedHelperProtocol {
    // Keep this list tight. Expand only with explicit validation.
    private let allowedPrefixes = [
        "pfctl -E",
        "pfctl -a portmanager -f -",
        "pfctl -a portmanager -F all"
    ]

    func runPrivilegedCommand(_ command: String, withReply reply: @escaping (Int32, String) -> Void) {
        guard isAllowed(command) else {
            reply(126, "Command blocked by helper policy.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
            let stderrData = err.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let combined = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            reply(process.terminationStatus, combined)
        } catch {
            reply(127, error.localizedDescription)
        }
    }

    private func isAllowed(_ command: String) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowedPrefixes.contains { normalized.hasPrefix($0) }
    }
}

final class PrivilegedHelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PrivilegedHelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
