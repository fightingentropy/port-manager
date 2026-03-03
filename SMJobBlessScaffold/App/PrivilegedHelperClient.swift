import Foundation
import Security
import ServiceManagement

enum PrivilegedHelperError: LocalizedError {
    case authorization(OSStatus)
    case blessFailed(String)
    case connectionFailed(String)
    case executionFailed(Int32, String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .authorization(let status):
            return "Authorization failed (\(status))."
        case .blessFailed(let message):
            return "SMJobBless failed: \(message)"
        case .connectionFailed(let message):
            return "Helper connection failed: \(message)"
        case .executionFailed(let code, let output):
            if output.isEmpty {
                return "Privileged command failed (code \(code))."
            }
            return "Privileged command failed (code \(code)): \(output)"
        case .timeout:
            return "Timed out waiting for privileged helper response."
        }
    }
}

final class PrivilegedHelperClient {
    static let shared = PrivilegedHelperClient()

    // Keep this label aligned with helper launchd plist.
    static let helperLabel = "com.erlinhoxha.portmanager.helper"

    private init() {}

    func blessHelperIfNeeded() throws {
        var authRef: AuthorizationRef?
        let create = AuthorizationCreate(nil, nil, [.interactionAllowed, .extendRights, .preAuthorize], &authRef)
        guard create == errAuthorizationSuccess, let authRef else {
            throw PrivilegedHelperError.authorization(create)
        }
        defer {
            AuthorizationFree(authRef, [.destroyRights])
        }

        var error: Unmanaged<CFError>?
        let blessed = SMJobBless(kSMDomainSystemLaunchd, Self.helperLabel as CFString, authRef, &error)
        guard blessed else {
            let message = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown error"
            throw PrivilegedHelperError.blessFailed(message)
        }
    }

    func run(command: String, timeout: TimeInterval = 10) throws -> String {
        let connection = NSXPCConnection(machServiceName: Self.helperLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)

        let semaphore = DispatchSemaphore(value: 0)
        var resultCode: Int32 = -1
        var resultOutput = ""
        var connectionError: String?

        connection.invalidationHandler = {
            semaphore.signal()
        }
        connection.interruptionHandler = {
            connectionError = "Connection interrupted."
            semaphore.signal()
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            connectionError = error.localizedDescription
            semaphore.signal()
        }) as? PrivilegedHelperProtocol else {
            connection.invalidate()
            throw PrivilegedHelperError.connectionFailed("Unable to build XPC proxy.")
        }

        proxy.runPrivilegedCommand(command) { code, output in
            resultCode = code
            resultOutput = output
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        connection.invalidate()

        if waitResult == .timedOut {
            throw PrivilegedHelperError.timeout
        }
        if let connectionError {
            throw PrivilegedHelperError.connectionFailed(connectionError)
        }
        if resultCode != 0 {
            throw PrivilegedHelperError.executionFailed(resultCode, resultOutput)
        }
        return resultOutput
    }
}
