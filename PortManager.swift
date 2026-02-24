import SwiftUI
import Foundation
import AppKit
import Network
import Darwin
import Combine

// MARK: - Model

struct PortInfo: Identifiable, Hashable {
    let id = UUID()
    let pid: Int
    let processName: String
    let userName: String
    let port: Int
    let protocolType: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(port)
        hasher.combine(protocolType)
    }

    static func == (lhs: PortInfo, rhs: PortInfo) -> Bool {
        lhs.pid == rhs.pid && lhs.port == rhs.port && lhs.protocolType == rhs.protocolType
    }
}

// MARK: - Dev Server Models

struct DevServerConfig: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var routeName: String
    var workingDirectory: String
    var command: String
    var autoStart: Bool

    init(
        id: UUID = UUID(),
        name: String,
        routeName: String = "",
        workingDirectory: String,
        command: String,
        autoStart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.routeName = routeName
        self.workingDirectory = workingDirectory
        self.command = command
        self.autoStart = autoStart
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case routeName
        case workingDirectory
        case command
        case autoStart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        routeName = try container.decodeIfPresent(String.self, forKey: .routeName) ?? ""
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        command = try container.decode(String.self, forKey: .command)
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(routeName, forKey: .routeName)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(command, forKey: .command)
        try container.encode(autoStart, forKey: .autoStart)
    }
}

enum ServerStatus: String {
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case failed = "Failed"
}

final class RunningServer: ObservableObject, Identifiable {
    let id: UUID
    let configID: UUID
    let name: String
    let workingDirectory: String
    let command: String
    let process: Process
    let routeHost: String
    let assignedPort: Int
    let proxyPort: Int
    @Published var status: ServerStatus
    @Published var pid: Int
    @Published var lastError: String?
    let startedAt: Date

    var proxiedURL: String {
        if proxyPort == 80 {
            return "http://\(routeHost)"
        }
        return "http://\(routeHost):\(proxyPort)"
    }

    init(config: DevServerConfig, process: Process, pid: Int, routeHost: String, assignedPort: Int, proxyPort: Int) {
        self.id = UUID()
        self.configID = config.id
        self.name = config.name
        self.workingDirectory = config.workingDirectory
        self.command = config.command
        self.process = process
        self.routeHost = routeHost
        self.assignedPort = assignedPort
        self.proxyPort = proxyPort
        self.status = .starting
        self.pid = pid
        self.lastError = nil
        self.startedAt = Date()
    }
}

// MARK: - Localhost Proxy

private final class ProxyTunnel {
    let id = UUID()
    private let client: NWConnection
    private let queue: DispatchQueue
    private let routeLookup: (String) -> Int?
    private let onClose: (UUID) -> Void
    private var upstream: NWConnection?
    private var isClosed = false
    private var initialBuffer = Data()
    private let maxInitialHeaderBytes = 64 * 1024

    init(
        client: NWConnection,
        queue: DispatchQueue,
        routeLookup: @escaping (String) -> Int?,
        onClose: @escaping (UUID) -> Void
    ) {
        self.client = client
        self.queue = queue
        self.routeLookup = routeLookup
        self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.close()
            }
        }
        client.start(queue: queue)
        receiveInitialRequest()
    }

    func shutdown() {
        close()
    }

    private func receiveInitialRequest() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.close()
                return
            }
            guard let data, !data.isEmpty else {
                self.close()
                return
            }

            self.initialBuffer.append(data)
            if self.initialBuffer.count > self.maxInitialHeaderBytes {
                self.respondBadRequest()
                return
            }

            guard Self.containsCompleteHTTPHeaders(self.initialBuffer) else {
                self.receiveInitialRequest()
                return
            }

            guard let host = Self.extractHost(from: self.initialBuffer), let targetPort = self.routeLookup(host) else {
                self.respondNotFound()
                return
            }

            guard let upstreamPort = NWEndpoint.Port(rawValue: UInt16(targetPort)) else {
                self.close()
                return
            }
            let upstream = NWConnection(host: .ipv4(IPv4Address.loopback), port: upstreamPort, using: .tcp)
            self.upstream = upstream
            upstream.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    upstream.send(content: self.initialBuffer, completion: .contentProcessed { _ in })
                    self.initialBuffer.removeAll(keepingCapacity: false)
                    self.pipe(source: self.client, destination: upstream)
                    self.pipe(source: upstream, destination: self.client)
                case .failed:
                    self.close()
                default:
                    break
                }
            }
            upstream.start(queue: queue)
        }
    }

    private func pipe(source: NWConnection, destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    if sendError != nil {
                        self?.close()
                    }
                })
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.pipe(source: source, destination: destination)
        }
    }

    private static func containsCompleteHTTPHeaders(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let marker = Data([13, 10, 13, 10]) // \r\n\r\n
        return data.range(of: marker) != nil
    }

    private static func extractHost(from data: Data) -> String? {
        guard let requestText = String(data: data, encoding: .utf8) else { return nil }
        for line in requestText.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("host:") {
                let hostPart = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                let host = hostPart.split(separator: ":").first.map(String.init) ?? ""
                if !host.isEmpty {
                    return host.lowercased()
                }
            }
        }
        return nil
    }

    private func respondBadRequest() {
        let body = "Bad Request\n"
        let response = """
        HTTP/1.1 400 Bad Request\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        client.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func respondNotFound() {
        let body = "Not Found: no app registered for this hostname.\n"
        let response = """
        HTTP/1.1 404 Not Found\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        client.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        client.cancel()
        upstream?.cancel()
        onClose(id)
    }
}

final class LocalhostProxyManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isHTTPRunning = false
    @Published private(set) var isHTTPSRunning = false
    @Published private(set) var listenPort: Int
    @Published private(set) var secureListenPort: Int
    @Published var errorMessage: String?
    @Published var trustHint: String?

    private var httpListener: NWListener?
    private var httpsListener: NWListener?
    private let listenerQueue = DispatchQueue(label: "PortManager.Proxy.Listener")
    private let routesQueue = DispatchQueue(label: "PortManager.Proxy.Routes")
    private var routeMap: [String: Int] = [:]
    private var activeTunnels: [UUID: ProxyTunnel] = [:]
    private let certificatePassphrase = "port-manager"
    private var expectedHosts: Set<String> = ["localhost"]

    init(listenPort: Int = 1355, secureListenPort: Int = 443) {
        self.listenPort = listenPort
        self.secureListenPort = secureListenPort
    }

    func start() {
        guard !isRunning else { return }
        do {
            try startHTTPListener()
            DispatchQueue.main.async {
                self.errorMessage = nil
                self.refreshRunningState()
            }
        } catch {
            stop()
            errorMessage = "Failed to start proxy: \(error.localizedDescription)"
        }
    }

    func stop() {
        listenerQueue.async {
            for tunnel in self.activeTunnels.values {
                tunnel.shutdown()
            }
            self.activeTunnels.removeAll()
        }
        httpListener?.cancel()
        httpListener = nil
        httpsListener?.cancel()
        httpsListener = nil
        isHTTPRunning = false
        isHTTPSRunning = false
        refreshRunningState()
    }

    func updateRoutes(_ routes: [String: Int]) {
        routesQueue.async { [routes] in
            self.routeMap = routes
        }
    }

    func setExpectedHosts(_ hosts: [String]) {
        let normalized = Set(hosts.map { $0.lowercased() }).union(["localhost"])
        guard normalized != expectedHosts else { return }
        expectedHosts = normalized
        if isRunning {
            stop()
            start()
        }
    }

    private func refreshRunningState() {
        isRunning = isHTTPRunning
    }

    private func registerConnection(_ connection: NWConnection) {
        let tunnel = ProxyTunnel(
            client: connection,
            queue: listenerQueue,
            routeLookup: { host in
                self.routesQueue.sync {
                    self.routeMap[host]
                }
            },
            onClose: { [weak self] tunnelID in
                self?.listenerQueue.async {
                    self?.activeTunnels.removeValue(forKey: tunnelID)
                }
            }
        )
        listenerQueue.async {
            self.activeTunnels[tunnel.id] = tunnel
        }
        tunnel.start()
    }

    private func startHTTPListener() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(listenPort)) else {
            throw NSError(domain: "PortManagerProxy", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP port \(listenPort)"])
        }
        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.registerConnection(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isHTTPRunning = true
                    self.refreshRunningState()
                case .failed(let error):
                    self.isHTTPRunning = false
                    self.refreshRunningState()
                    self.errorMessage = "HTTP proxy failed: \(error.localizedDescription)"
                case .cancelled:
                    self.isHTTPRunning = false
                    self.refreshRunningState()
                default:
                    break
                }
            }
        }
        httpListener = listener
        listener.start(queue: listenerQueue)
    }

    private func startHTTPSListener(identity: sec_identity_t) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(secureListenPort)) else {
            throw NSError(domain: "PortManagerProxy", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTPS port \(secureListenPort)"])
        }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.registerConnection(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isHTTPSRunning = true
                    self.refreshRunningState()
                case .failed(let error):
                    self.isHTTPSRunning = false
                    self.refreshRunningState()
                    self.errorMessage = "HTTPS proxy failed: \(error.localizedDescription)"
                case .cancelled:
                    self.isHTTPSRunning = false
                    self.refreshRunningState()
                default:
                    break
                }
            }
        }
        httpsListener = listener
        listener.start(queue: listenerQueue)
    }

    private func ensureTLSIdentity() throws -> sec_identity_t {
        let certDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".port-manager", isDirectory: true)
            .appendingPathComponent("certs", isDirectory: true)
        let certPath = certDir.appendingPathComponent("localhost-cert.pem")
        let keyPath = certDir.appendingPathComponent("localhost-key.pem")
        let p12Path = certDir.appendingPathComponent("localhost-identity.p12")
        let hostsPath = certDir.appendingPathComponent("hosts.txt")
        try FileManager.default.createDirectory(at: certDir, withIntermediateDirectories: true)

        let expectedHostsList = Array(expectedHosts).sorted()
        let expectedHostsText = expectedHostsList.joined(separator: "\n")
        let currentHostsText = (try? String(contentsOf: hostsPath, encoding: .utf8)) ?? ""

        if !FileManager.default.fileExists(atPath: certPath.path)
            || !FileManager.default.fileExists(atPath: keyPath.path)
            || !FileManager.default.fileExists(atPath: p12Path.path)
            || currentHostsText != expectedHostsText {
            try generateCertificate(
                certPath: certPath,
                keyPath: keyPath,
                p12Path: p12Path,
                explicitHosts: expectedHostsList
            )
            try expectedHostsText.write(to: hostsPath, atomically: true, encoding: .utf8)
        }

        trustHint = "Trust cert once: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \(certPath.path)"

        let p12Data = try Data(contentsOf: p12Path)
        var imported: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: certificatePassphrase]
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess,
              let items = imported as? [[String: Any]],
              let first = items.first,
              let identityValue = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "PortManagerProxy", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Failed to load TLS identity"])
        }
        let secIdentity = identityValue as! SecIdentity

        guard let identity = sec_identity_create(secIdentity) else {
            throw NSError(domain: "PortManagerProxy", code: 1005, userInfo: [NSLocalizedDescriptionKey: "Failed to build TLS identity object"])
        }

        return identity
    }

    private func generateCertificate(certPath: URL, keyPath: URL, p12Path: URL, explicitHosts: [String]) throws {
        let extFile = certPath.deletingLastPathComponent().appendingPathComponent("openssl-localhost.cnf")
        var altLines = [
            "DNS.1 = localhost",
            "DNS.2 = *.localhost"
        ]
        var nextIndex = 3
        for host in explicitHosts where host != "localhost" {
            altLines.append("DNS.\(nextIndex) = \(host)")
            nextIndex += 1
        }
        let config = """
        [req]
        prompt = no
        distinguished_name = dn
        x509_extensions = v3_req

        [dn]
        CN = localhost

        [v3_req]
        subjectAltName = @alt_names
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth

        [alt_names]
        \(altLines.joined(separator: "\n"))
        """
        try config.write(to: extFile, atomically: true, encoding: .utf8)

        try runCommand(
            executable: "/usr/bin/openssl",
            arguments: [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", keyPath.path,
                "-out", certPath.path,
                "-days", "825",
                "-config", extFile.path
            ]
        )

        try runCommand(
            executable: "/usr/bin/openssl",
            arguments: [
                "pkcs12", "-export",
                "-inkey", keyPath.path,
                "-in", certPath.path,
                "-out", p12Path.path,
                "-passout", "pass:\(certificatePassphrase)"
            ]
        )
    }

    private func runCommand(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "PortManagerProxy", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Command failed (\(executable)): \(stderrText)"])
        }
    }
}

// MARK: - Dev Server Manager

@MainActor
final class DevServerManager: ObservableObject {
    static let shared = DevServerManager()

    @Published var configs: [DevServerConfig] = []
    @Published var runningServers: [RunningServer] = []
    @Published var lastErrorMessage: String?
    @Published private(set) var proxy = LocalhostProxyManager()

    private let configsKey = "devServerConfigs"
    private let portRange = 4000...4999
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        proxy.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        loadConfigs()
        refreshExpectedHosts()
        proxy.start()
        for config in configs where config.autoStart {
            start(config: config)
        }
    }

    private func normalizedRouteName(for config: DevServerConfig) -> String {
        let raw = config.routeName.isEmpty ? config.name : config.routeName
        let allowed = raw.lowercased().map { char -> Character in
            if char.isLetter || char.isNumber || char == "-" || char == "." {
                return char
            }
            return "-"
        }
        let collapsed = String(allowed).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "app" : trimmed
    }

    private func reserveAvailablePort() -> Int? {
        for candidate in portRange.shuffled() where isTCPPortAvailable(candidate) {
            if !runningServers.contains(where: { $0.assignedPort == candidate }) {
                return candidate
            }
        }
        return nil
    }

    private func refreshProxyRoutes() {
        let routes = Dictionary(uniqueKeysWithValues: runningServers.map { ($0.routeHost.lowercased(), $0.assignedPort) })
        proxy.updateRoutes(routes)
    }

    private func refreshExpectedHosts() {
        let configHosts = configs.map { "\(normalizedRouteName(for: $0)).localhost" }
        let runningHosts = runningServers.map(\.routeHost)
        proxy.setExpectedHosts(configHosts + runningHosts)
    }

    func start(config: DevServerConfig) {
        if runningServers.contains(where: { $0.configID == config.id }) {
            return
        }

        let workingDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
        guard FileManager.default.fileExists(atPath: workingDirectoryURL.path) else {
            lastErrorMessage = "Directory not found: \(config.workingDirectory)"
            return
        }

        guard let assignedPort = reserveAvailablePort() else {
            lastErrorMessage = "Could not find a free port in \(portRange.lowerBound)-\(portRange.upperBound)"
            return
        }

        let routeHost = "\(normalizedRouteName(for: config)).localhost"
        if runningServers.contains(where: { $0.routeHost == routeHost }) {
            lastErrorMessage = "Route already in use: \(routeHost)"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", config.command]
        process.currentDirectoryURL = workingDirectoryURL

        // Build environment with extended PATH to include common user binary directories
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userPaths = [
            "\(home)/.bun/bin",
            "\(home)/.local/bin",
            "\(home)/.nvm/current/bin",
            "\(home)/.volta/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extendedPath = userPaths.joined(separator: ":") + ":" + existingPath
        env["PATH"] = extendedPath
        env["PORT"] = String(assignedPort)
        env["HOST"] = "127.0.0.1"
        env["PORTLESS_PORT"] = String(proxy.listenPort)
        env["PORTLESS_HOSTNAME"] = routeHost
        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let server = RunningServer(
            config: config,
            process: process,
            pid: 0,
            routeHost: routeHost,
            assignedPort: assignedPort,
            proxyPort: proxy.listenPort
        )
        runningServers.append(server)
        refreshExpectedHosts()
        refreshProxyRoutes()

        outputPipe.fileHandleForReading.readabilityHandler = { _ in }
        errorPipe.fileHandleForReading.readabilityHandler = { _ in }

        process.terminationHandler = { [weak self, weak server] _ in
            DispatchQueue.main.async {
                guard let self, let server else { return }
                if server.status != .failed {
                    server.status = .stopped
                }
                self.runningServers.removeAll { $0.id == server.id }
                self.refreshExpectedHosts()
                self.refreshProxyRoutes()
            }
        }

        do {
            try process.run()
            server.pid = Int(process.processIdentifier)
            server.status = .running
        } catch {
            server.status = .failed
            server.lastError = "Failed to start: \(error.localizedDescription)"
            lastErrorMessage = server.lastError
            runningServers.removeAll { $0.id == server.id }
            refreshExpectedHosts()
            refreshProxyRoutes()
        }
    }

    func stop(config: DevServerConfig) {
        guard let server = runningServers.first(where: { $0.configID == config.id }) else { return }
        stop(server: server)
    }

    func stop(server: RunningServer) {
        server.process.terminate()
        let pid = server.pid
        let serverID = server.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                if !isProcessRunning(pid: pid) {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if isProcessRunning(pid: pid) {
                _ = sendSignal(pid: pid, signal: 9)
            }
            DispatchQueue.main.async {
                self?.runningServers.removeAll { $0.id == serverID }
                self?.refreshExpectedHosts()
                self?.refreshProxyRoutes()
            }
        }
    }

    func addConfig(_ config: DevServerConfig) {
        configs.append(config)
        refreshExpectedHosts()
        saveConfigs()
    }

    func updateConfig(_ config: DevServerConfig) {
        guard let index = configs.firstIndex(where: { $0.id == config.id }) else { return }
        configs[index] = config
        refreshExpectedHosts()
        saveConfigs()
    }

    func deleteConfigs(at offsets: IndexSet) {
        for index in offsets {
            let config = configs[index]
            stop(config: config)
        }
        configs.remove(atOffsets: offsets)
        refreshExpectedHosts()
        saveConfigs()
    }

    private func saveConfigs() {
        do {
            let data = try JSONEncoder().encode(configs)
            UserDefaults.standard.set(data, forKey: configsKey)
        } catch {
            lastErrorMessage = "Failed to save configs: \(error.localizedDescription)"
        }
    }

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: configsKey) else { return }
        do {
            configs = try JSONDecoder().decode([DevServerConfig].self, from: data)
        } catch {
            lastErrorMessage = "Failed to load configs: \(error.localizedDescription)"
        }
    }
}

private func isTCPPortAvailable(_ port: Int) -> Bool {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return false }
    defer { close(socketFD) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    return withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride)) == 0
        }
    }
}

// MARK: - Port Scanner

class PortScanner: ObservableObject {
    @Published var ports: [PortInfo] = []
    @Published var isScanning = false
    @Published var errorMessage: String?

    func scan() {
        isScanning = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.runLsof() ?? []
            DispatchQueue.main.async {
                self?.ports = result.sorted { $0.port < $1.port }
                self?.isScanning = false
            }
        }
    }

    private func runLsof() -> [PortInfo] {
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-iTCP", "-iUDP", "-sTCP:LISTEN", "-P", "-n"]
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to run lsof: \(error.localizedDescription)"
            }
            return []
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if let errorMessage, !errorMessage.isEmpty {
                    self.errorMessage = "lsof failed: \(errorMessage)"
                } else {
                    self.errorMessage = "lsof exited with status \(process.terminationStatus)"
                }
            }
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return parseLsofOutput(output)
    }

    private func parseLsofOutput(_ output: String) -> [PortInfo] {
        var results: [PortInfo] = []
        var seen = Set<String>()

        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() { // Skip header
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count >= 9 else { continue }

            let processName = String(components[0])
            guard let pid = Int(components[1]) else { continue }
            let userName = String(components[2])

            // Parse protocol (TCP/UDP)
            let protocolType: String
            let typeField = String(components[4])
            if typeField.contains("TCP") || line.contains("TCP") {
                protocolType = "TCP"
            } else if typeField.contains("UDP") || line.contains("UDP") {
                protocolType = "UDP"
            } else {
                protocolType = "TCP" // Default
            }

            // Parse port from the NAME column.
            // NAME can span multiple space-separated fields, e.g. "127.0.0.1:3000 (LISTEN)"
            // The NAME column starts at index 8, so join everything from there on.
            let nameField = components.dropFirst(8).joined(separator: " ")
            guard let port = extractPort(from: nameField) else { continue }

            // Deduplicate
            let key = "\(pid)-\(port)-\(protocolType)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            results.append(PortInfo(
                pid: pid,
                processName: processName,
                userName: userName,
                port: port,
                protocolType: protocolType
            ))
        }

        return results
    }

    private func extractPort(from nameField: String) -> Int? {
        // NAME may look like:
        // "127.0.0.1:3000 (LISTEN)" or "*:1900" or "[::1]:8080 (LISTEN)"
        // We search tokens from the end and pick the last one that contains a port.
        let tokens = nameField.split(separator: " ")

        for token in tokens.reversed() {
            if let port = extractPort(fromToken: String(token)) {
                return port
            }
        }

        return nil
    }

    private func extractPort(fromToken token: String) -> Int? {
        let parts = token.split(separator: ":")
        guard let lastPart = parts.last, !lastPart.isEmpty else { return nil }

        // Strip brackets from IPv6-style addresses if present
        let cleaned = lastPart.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return Int(cleaned)
    }
}

// MARK: - Process Killer

struct KillResult {
    let success: Bool
    let message: String
    let needsForce: Bool
}

private func sendSignal(pid: Int, signal: Int) -> (success: Bool, message: String) {
    let process = Process()
    let errorPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/kill")
    process.arguments = ["-\(signal)", String(pid)]
    process.standardError = errorPipe

    do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return (true, "Signal \(signal) sent to process \(pid)")
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"

            if errorMessage.contains("Operation not permitted") || errorMessage.contains("Permission denied") {
                return (false, "Permission denied. Try running with sudo or kill system processes manually.")
            }
            return (false, "Failed to kill process: \(errorMessage)")
        }
    } catch {
        return (false, "Error: \(error.localizedDescription)")
    }
}

private func isProcessRunning(pid: Int) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/kill")
    process.arguments = ["-0", String(pid)]

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func terminateProcess(pid: Int) -> KillResult {
    let result = sendSignal(pid: pid, signal: 15)
    if !result.success {
        return KillResult(success: false, message: result.message, needsForce: false)
    }

    if isProcessRunning(pid: pid) {
        return KillResult(success: false, message: "Process \(pid) is still running after SIGTERM.", needsForce: true)
    }

    return KillResult(success: true, message: "Process \(pid) terminated successfully", needsForce: false)
}

func forceKillProcess(pid: Int) -> KillResult {
    let result = sendSignal(pid: pid, signal: 9)
    if !result.success {
        return KillResult(success: false, message: result.message, needsForce: false)
    }

    if isProcessRunning(pid: pid) {
        return KillResult(success: false, message: "Process \(pid) is still running after SIGKILL.", needsForce: false)
    }

    return KillResult(success: true, message: "Process \(pid) killed successfully", needsForce: false)
}

// MARK: - Views

struct DevServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var routeName: String
    @State private var workingDirectory: String
    @State private var command: String
    @State private var autoStart: Bool

    let onSave: (DevServerConfig) -> Void
    let existingID: UUID?

    init(config: DevServerConfig?, onSave: @escaping (DevServerConfig) -> Void) {
        self.onSave = onSave
        self.existingID = config?.id
        _name = State(initialValue: config?.name ?? "New Dev Server")
        _routeName = State(initialValue: config?.routeName ?? "")
        _workingDirectory = State(initialValue: config?.workingDirectory ?? "")
        _command = State(initialValue: config?.command ?? "bun run dev")
        _autoStart = State(initialValue: config?.autoStart ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dev Server")
                .font(.headline)

            TextField("Name", text: $name)
            TextField("Route name (e.g. myapp)", text: $routeName)

            HStack {
                TextField("Working directory", text: $workingDirectory)
                Button("Choose...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url {
                        workingDirectory = url.path
                    }
                }
            }

            TextField("Command", text: $command)
                .font(.system(.body, design: .monospaced))

            Toggle("Auto-start on launch", isOn: $autoStart)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    let config = DevServerConfig(
                        id: existingID ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        routeName: routeName.trimmingCharacters(in: .whitespacesAndNewlines),
                        workingDirectory: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
                        command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                        autoStart: autoStart
                    )
                    onSave(config)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct DevServersView: View {
    @StateObject private var manager = DevServerManager.shared
    @State private var showingEditor = false
    @State private var editingConfig: DevServerConfig?
    @State private var alertMessage = ""
    @State private var showingAlert = false
    @State private var showingDeleteConfirmation = false
    @State private var configToDelete: DevServerConfig?

    private func runningServer(for config: DevServerConfig) -> RunningServer? {
        manager.runningServers.first(where: { $0.configID == config.id })
    }

    private func statusText(for config: DevServerConfig) -> String {
        if let server = runningServer(for: config) {
            return "\(server.status.rawValue) · PID \(server.pid) · :\(server.assignedPort)"
        }
        return ServerStatus.stopped.rawValue
    }

    private func statusColor(for config: DevServerConfig) -> Color {
        guard let server = runningServer(for: config) else {
            return .secondary
        }
        switch server.status {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private func deleteConfig(_ config: DevServerConfig) {
        if let index = manager.configs.firstIndex(where: { $0.id == config.id }) {
            manager.deleteConfigs(at: IndexSet(integer: index))
        }
    }

    private func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Dev Servers")
                    .font(.headline)
                Spacer()
                Button(action: {
                    editingConfig = nil
                    showingEditor = true
                }) {
                    Label("Add", systemImage: "plus")
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            HStack(spacing: 10) {
                Circle()
                    .fill(manager.proxy.isRunning ? .green : .red)
                    .frame(width: 8, height: 8)
                Text("Proxy \(manager.proxy.isRunning ? "Running" : "Stopped") on :\(String(manager.proxy.listenPort))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if manager.proxy.isRunning {
                    Button("Stop Proxy") {
                        manager.proxy.stop()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Start Proxy") {
                        manager.proxy.start()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if let proxyError = manager.proxy.errorMessage {
                Text(proxyError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            if manager.configs.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No dev servers configured")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Add one to start and stop your dev servers with a click.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
            } else {
                List {
                    ForEach(manager.configs) { config in
                        let server = runningServer(for: config)
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(config.name)
                                    .font(.headline)
                                if let server {
                                    HStack(spacing: 8) {
                                        Text(server.proxiedURL)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.blue)
                                            .lineLimit(1)
                                        Button("Open") {
                                            openURL(server.proxiedURL)
                                        }
                                        .buttonStyle(.link)
                                    }
                                } else if !config.routeName.isEmpty {
                                    Text(manager.proxy.listenPort == 80
                                         ? "http://\(config.routeName).localhost"
                                         : "http://\(config.routeName).localhost:\(String(manager.proxy.listenPort))")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Text(config.workingDirectory)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Text(config.command)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(statusText(for: config))
                                .font(.caption)
                                .foregroundColor(statusColor(for: config))
                                .frame(width: 180, alignment: .trailing)
                            if server != nil {
                                Button("Stop") {
                                    manager.stop(config: config)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            } else {
                                Button("Start") {
                                    manager.start(config: config)
                                    if let error = manager.lastErrorMessage {
                                        alertMessage = error
                                        showingAlert = true
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            Button {
                                editingConfig = config
                                showingEditor = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.plain)
                            .help("Edit")
                            Button {
                                configToDelete = config
                                showingDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .help("Delete")
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("\(manager.configs.count) server\(manager.configs.count == 1 ? "" : "s")")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Spacer()
                if let error = manager.lastErrorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 520, minHeight: 320)
        .sheet(isPresented: $showingEditor) {
            DevServerEditorView(config: editingConfig) { config in
                if let _ = manager.configs.firstIndex(where: { $0.id == config.id }) {
                    manager.updateConfig(config)
                } else {
                    manager.addConfig(config)
                }
            }
        }
        .alert("Dev Server", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .alert("Delete Server?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let config = configToDelete {
                    deleteConfig(config)
                }
            }
        } message: {
            if let config = configToDelete {
                Text("Are you sure you want to delete \"\(config.name)\"? This action cannot be undone.")
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var scanner = PortScanner()
    @State private var searchText = ""
    @State private var showingKillConfirmation = false
    @State private var portToKill: PortInfo?
    @State private var alertMessage = ""
    @State private var showingAlert = false
    @State private var showingForceKillConfirmation = false
    @State private var portToForceKill: PortInfo?
    @State private var refreshInterval: RefreshInterval = .off
    @State private var refreshTimer: Timer?
    @State private var protocolFilter: ProtocolFilter = .all
    @State private var sortField: SortField = .port
    @State private var sortAscending = true

    enum RefreshInterval: String, CaseIterable, Identifiable {
        case off = "Off"
        case twoSeconds = "2s"
        case fiveSeconds = "5s"
        case tenSeconds = "10s"

        var id: String { rawValue }

        var seconds: TimeInterval? {
            switch self {
            case .off: return nil
            case .twoSeconds: return 2
            case .fiveSeconds: return 5
            case .tenSeconds: return 10
            }
        }
    }

    enum ProtocolFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case tcp = "TCP"
        case udp = "UDP"

        var id: String { rawValue }
    }

    enum SortField: String, CaseIterable, Identifiable {
        case port = "Port"
        case protocolType = "Protocol"
        case pid = "PID"
        case processName = "Process"
        case userName = "User"

        var id: String { rawValue }
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard let interval = refreshInterval.seconds else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            scanner.scan()
        }
    }

    var filteredPorts: [PortInfo] {
        var results = scanner.ports

        if protocolFilter != .all {
            results = results.filter { $0.protocolType == protocolFilter.rawValue }
        }

        if !searchText.isEmpty {
            results = results.filter { port in
                port.processName.localizedCaseInsensitiveContains(searchText) ||
                port.userName.localizedCaseInsensitiveContains(searchText) ||
                String(port.port).contains(searchText) ||
                String(port.pid).contains(searchText)
            }
        }

        results = results.sorted { lhs, rhs in
            let comparison: Bool
            switch sortField {
            case .port:
                comparison = lhs.port < rhs.port
            case .protocolType:
                comparison = lhs.protocolType < rhs.protocolType
            case .pid:
                comparison = lhs.pid < rhs.pid
            case .processName:
                comparison = lhs.processName.localizedCaseInsensitiveCompare(rhs.processName) == .orderedAscending
            case .userName:
                comparison = lhs.userName.localizedCaseInsensitiveCompare(rhs.userName) == .orderedAscending
            }
            return sortAscending ? comparison : !comparison
        }

        return results
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            VStack(alignment: .leading, spacing: 0) {
                // Search
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 16)

                // Filters
                VStack(alignment: .leading, spacing: 16) {
                    // Protocol filter
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Protocol")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Picker("Protocol", selection: $protocolFilter) {
                            ForEach(ProtocolFilter.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }

                    // Auto-refresh
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Auto-refresh")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Picker("Auto-refresh", selection: $refreshInterval) {
                            ForEach(RefreshInterval.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    // Sort
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sort by")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        HStack(spacing: 6) {
                            Picker("Sort", selection: $sortField) {
                                ForEach(SortField.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            Button(action: { sortAscending.toggle() }) {
                                Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.bordered)
                            .help(sortAscending ? "Ascending" : "Descending")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .padding(.horizontal, 16)

                // Refresh button
                HStack {
                    Button(action: { scanner.scan() }) {
                        HStack(spacing: 6) {
                            if scanner.isScanning {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Refresh")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(scanner.isScanning)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Spacer()

                // Status bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(scanner.errorMessage == nil ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text("\(filteredPorts.count) port\(filteredPorts.count == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    if let error = scanner.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            }
            .frame(width: 200)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // MARK: - Main content
            VStack(spacing: 0) {
                // Table header
                HStack(spacing: 0) {
                    Text("Port")
                        .frame(width: 70, alignment: .leading)
                    Text("Proto")
                        .frame(width: 55, alignment: .leading)
                    Text("PID")
                        .frame(width: 75, alignment: .leading)
                    Text("Process")
                        .frame(minWidth: 140, alignment: .leading)
                    Spacer()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

                Divider()

                if filteredPorts.isEmpty && !scanner.isScanning {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: scanner.ports.isEmpty ? "network.slash" : "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary.opacity(0.5))
                        if scanner.ports.isEmpty {
                            Text("No listening ports found")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        } else {
                            Text("No matches for \"\(searchText)\"")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredPorts) { port in
                                HStack(spacing: 0) {
                                    Text(String(port.port))
                                        .frame(width: 70, alignment: .leading)
                                        .font(.system(.body, design: .monospaced))
                                    Text(port.protocolType)
                                        .frame(width: 55, alignment: .leading)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(port.protocolType == "TCP" ? .blue : .orange)
                                    Text(String(port.pid))
                                        .frame(width: 75, alignment: .leading)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(port.processName)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text(port.userName)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(minWidth: 140, alignment: .leading)
                                    Spacer()
                                    Button(action: {
                                        portToKill = port
                                        showingKillConfirmation = true
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Kill process \(port.pid)")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.clear)
                                .contentShape(Rectangle())

                                if port.id != filteredPorts.last?.id {
                                    Divider()
                                        .padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 400)
        }
        .frame(minWidth: 600, minHeight: 360)
        .onAppear {
            scanner.scan()
            startAutoRefresh()
        }
        .onChange(of: refreshInterval) {
            startAutoRefresh()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .alert("Kill Process?", isPresented: $showingKillConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Kill", role: .destructive) {
                if let port = portToKill {
                    let result = terminateProcess(pid: port.pid)
                    alertMessage = result.message
                    showingAlert = true
                    if result.success {
                        // Refresh the list after killing
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            scanner.scan()
                        }
                    } else if result.needsForce {
                        portToForceKill = port
                        showingForceKillConfirmation = true
                    }
                }
            }
        } message: {
            if let port = portToKill {
                Text("Kill \(port.processName) (PID: \(port.pid)) listening on port \(port.port)?")
            }
        }
        .alert("Force Kill?", isPresented: $showingForceKillConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Force Kill", role: .destructive) {
                if let port = portToForceKill {
                    let result = forceKillProcess(pid: port.pid)
                    alertMessage = result.message
                    showingAlert = true
                    if result.success {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            scanner.scan()
                        }
                    }
                }
            }
        } message: {
            if let port = portToForceKill {
                Text("\(port.processName) (PID: \(port.pid)) is still running. Force kill with SIGKILL?")
            }
        }
        .alert("Result", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
}

// MARK: - Settings

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let launchAtLoginKey = "launchAtLogin"
    private let autoCheckUpdatesKey = "autoCheckUpdates"
    private let updatesFeedURLKey = "updatesFeedURL"
    private let defaultUpdatesFeedURL = "https://api.github.com/repos/fightingentropy/port-manager/releases/latest"

    @Published private(set) var menuBarModeEnabled: Bool = true

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: launchAtLoginKey)
        }
    }

    @Published var autoCheckUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: autoCheckUpdatesKey)
        }
    }

    @Published var updatesFeedURL: String {
        didSet {
            UserDefaults.standard.set(updatesFeedURL, forKey: updatesFeedURLKey)
        }
    }

    private init() {
        self.launchAtLogin = UserDefaults.standard.bool(forKey: launchAtLoginKey)
        if UserDefaults.standard.object(forKey: autoCheckUpdatesKey) == nil {
            self.autoCheckUpdates = true
        } else {
            self.autoCheckUpdates = UserDefaults.standard.bool(forKey: autoCheckUpdatesKey)
        }
        self.updatesFeedURL = UserDefaults.standard.string(forKey: updatesFeedURLKey) ?? defaultUpdatesFeedURL
    }

    func applyAppMode() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var isUpdateAvailable = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var latestReleaseURL: URL?
    @Published private(set) var canInstallUpdate = false

    private var latestAssetURL: URL?
    private var latestAssetName: String?

    private init() {}

    func checkForUpdates(feedURLString: String, silentNoUpdate: Bool = false) async {
        guard !isChecking else { return }
        guard let feedURL = URL(string: feedURLString), !feedURLString.isEmpty else {
            statusMessage = "Invalid update feed URL."
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: feedURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("PortManager", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                statusMessage = "Update check failed: unexpected server response."
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            latestVersion = latest
            latestReleaseURL = URL(string: release.htmlURL)
            latestAssetURL = Self.selectInstallAsset(from: release.assets)
            latestAssetName = latestAssetURL?.lastPathComponent
            canInstallUpdate = latestAssetURL != nil

            if Self.isVersion(latest, greaterThan: currentVersion) {
                isUpdateAvailable = true
                if let latestAssetName {
                    statusMessage = "Update available: \(latest) (current \(currentVersion)). Asset: \(latestAssetName)"
                } else {
                    statusMessage = "Update available: \(latest) (current \(currentVersion)). No installable asset found."
                }
            } else {
                isUpdateAvailable = false
                canInstallUpdate = false
                if !silentNoUpdate {
                    statusMessage = "You are up to date (\(currentVersion))."
                }
            }
        } catch {
            statusMessage = "Update check failed: \(error.localizedDescription)"
        }
    }

    func openLatestReleasePage() {
        guard let url = latestReleaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    func installLatestUpdate() async {
        guard !isInstalling else { return }
        guard isUpdateAvailable else {
            statusMessage = "No update is currently available."
            return
        }
        guard let assetURL = latestAssetURL else {
            statusMessage = "No installable update asset found. Open the release page and install manually."
            return
        }

        isInstalling = true
        defer { isInstalling = false }

        do {
            statusMessage = "Downloading update..."
            var request = URLRequest(url: assetURL)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("PortManager", forHTTPHeaderField: "User-Agent")
            let (downloadedURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                statusMessage = "Update download failed: unexpected server response."
                return
            }

            let tempBase = FileManager.default.temporaryDirectory
                .appendingPathComponent("portmanager-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)

            let archiveName = latestAssetName ?? "PortManager.zip"
            let archiveURL = tempBase.appendingPathComponent(archiveName)
            try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)

            let extractDir = tempBase.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

            statusMessage = "Extracting update..."
            try runCommand(executable: "/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractDir.path])

            guard let appPath = findAppBundle(in: extractDir)?.path else {
                statusMessage = "Update package did not contain an .app bundle."
                return
            }

            statusMessage = "Installing update (admin prompt may appear)..."
            try installAppWithAdminPrivileges(fromPath: appPath)

            statusMessage = "Update installed. Relaunching..."
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/PortManager.app"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
            }
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    private static func selectInstallAsset(from assets: [GitHubAsset]) -> URL? {
        let preferred = assets.first {
            let name = $0.name.lowercased()
            return name.hasSuffix(".zip") && name.contains("portmanager")
        } ?? assets.first {
            $0.name.lowercased().hasSuffix(".zip")
        }
        guard let preferred, let url = URL(string: preferred.browserDownloadURL) else {
            return nil
        }
        return url
    }

    private func findAppBundle(in root: URL) -> URL? {
        if root.pathExtension.lowercased() == "app" { return root }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        for case let candidate as URL in enumerator {
            if candidate.pathExtension.lowercased() == "app" {
                return candidate
            }
        }
        return nil
    }

    private func installAppWithAdminPrivileges(fromPath sourcePath: String) throws {
        let escapedSource = shellEscape(sourcePath)
        let command = "rm -rf /Applications/PortManager.app && cp -R \(escapedSource) /Applications/PortManager.app"
        let appleScriptCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(appleScriptCommand)\" with administrator privileges"
        try runCommand(executable: "/usr/bin/osascript", arguments: ["-e", script])
    }

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runCommand(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw NSError(domain: "PortManagerUpdate", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderrText])
        }
    }

    private static func isVersion(_ lhs: String, greaterThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(left.count, right.count)
        for idx in 0..<count {
            let l = idx < left.count ? left[idx] : 0
            let r = idx < right.count ? right[idx] : 0
            if l != r {
                return l > r
            }
        }
        return false
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: $settings.launchAtLogin)
                        .toggleStyle(.switch)
                        .disabled(true)
                    Text("Coming soon")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-check for updates", isOn: $settings.autoCheckUpdates)
                        .toggleStyle(.switch)

                    TextField("GitHub releases API URL", text: $settings.updatesFeedURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    HStack(spacing: 10) {
                        Button {
                            Task {
                                await updateChecker.checkForUpdates(feedURLString: settings.updatesFeedURL)
                            }
                        } label: {
                            if updateChecker.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Check for Updates")
                            }
                        }
                        .disabled(updateChecker.isChecking)

                        if updateChecker.isUpdateAvailable {
                            Button {
                                Task {
                                    await updateChecker.installLatestUpdate()
                                }
                            } label: {
                                if updateChecker.isInstalling {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Text("Install Update")
                                }
                            }
                            .disabled(updateChecker.isInstalling || !updateChecker.canInstallUpdate)

                            Button("Open Latest Release") {
                                updateChecker.openLatestReleasePage()
                            }
                            .buttonStyle(.link)
                        }
                    }

                    if let message = updateChecker.statusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(updateChecker.isUpdateAvailable ? .orange : .secondary)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 360)
    }
}

// MARK: - Main Content View

struct MainContentView: View {
    @State private var showingSettings = false

    var body: some View {
        TabView {
            ContentView()
                .tabItem { Label("Ports", systemImage: "network") }
            DevServersView()
                .tabItem { Label("Dev Servers", systemImage: "terminal") }
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var settingsWindow: NSWindow?
    @Published var isPopoverShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        AppSettings.shared.applyAppMode()
        if AppSettings.shared.autoCheckUpdates {
            Task {
                await UpdateChecker.shared.checkForUpdates(
                    feedURLString: AppSettings.shared.updatesFeedURL,
                    silentNoUpdate: true
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Port Manager")
            button.action = #selector(handleMenuBarClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 720, height: 500)
        pop.contentViewController = NSHostingController(rootView: MainContentView())
        popover = pop

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    @objc private func handleMenuBarClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }

        togglePopover()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Port Manager", action: #selector(togglePopoverAction), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettingsWindow), keyEquivalent: ","))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.last?.target = self

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func togglePopover() {
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        isPopoverShown = true
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() {
        popover?.performClose(nil)
        isPopoverShown = false
    }

    @objc private func togglePopoverAction() {
        togglePopover()
    }

    @objc private func openSettingsWindow() {
        closePopover()

        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 460, height: 360))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func activateApp() {
        closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }

        if !AppSettings.shared.menuBarModeEnabled {
            // Stay in regular mode
        } else {
            // Will return to accessory mode when window closes
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - App

@main
struct PortManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
