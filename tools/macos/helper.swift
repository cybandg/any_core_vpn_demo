import Foundation
import SystemConfiguration
import Darwin

enum Failure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw Failure.message(message)
    }
}

func runCapture(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

func preflight() throws {
    let routeOut = runCapture("/sbin/route", ["-n", "get", "default"])
    if let match = routeOut.range(of: #"interface:\s*(\S+)"#,
                                  options: .regularExpression) {
        let iface = routeOut[match]
            .split(whereSeparator: \.isWhitespace)
            .last.map(String.init) ?? ""
        try require(
            !iface.hasPrefix("utun"),
            "Другой VPN уже активен (интерфейс \(iface)). Завершите его подключение и повторите."
        )
    }

    let proxyOut = runCapture("/usr/sbin/scutil", ["--proxy"])
    for key in ["HTTPEnable : 1", "HTTPSEnable : 1",
                "SOCKSEnable : 1", "ProxyAutoConfigEnable : 1"] {
        try require(
            !proxyOut.contains(key),
            "В системе уже включён прокси (\(key)). Отключите его и повторите."
        )
    }
}

func writeJSON(_ object: [String: Any], to path: String) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    chmod(path, 0o644)
}

func readJSON(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let object = try JSONSerialization.jsonObject(with: data)
        as? [String: Any] else {
        throw Failure.message("Invalid JSON: \(path)")
    }
    return object
}

func preferences() throws -> SCPreferences {
    guard let value = SCPreferencesCreate(
        nil,
        "singbox-xray-flutter-dev" as CFString,
        nil
    ) else {
        throw Failure.message("SCPreferencesCreate failed")
    }
    return value
}

func serviceIDs(_ prefs: SCPreferences) throws -> [String] {
    guard let set = SCNetworkSetCopyCurrent(prefs),
          let services = SCNetworkSetCopyServices(set)
            as? [SCNetworkService] else {
        throw Failure.message("Cannot read current network services")
    }

    return services
        .filter { SCNetworkServiceGetEnabled($0) }
        .compactMap { service -> String? in
            guard let id = SCNetworkServiceGetServiceID(service) else {
                return nil
            }
            return id as String
        }
        .sorted()
}

func dictionary(_ prefs: SCPreferences, _ path: String) -> [String: Any]? {
    return SCPreferencesPathGetValue(prefs, path as CFString)
        as? [String: Any]
}

func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    return NSDictionary(dictionary: a).isEqual(NSDictionary(dictionary: b))
}

func commit(_ prefs: SCPreferences) throws {
    try require(
        SCPreferencesCommitChanges(prefs),
        "SCPreferencesCommitChanges: \(SCError())"
    )
    try require(
        SCPreferencesApplyChanges(prefs),
        "SCPreferencesApplyChanges: \(SCError())"
    )
}

func snapshot() throws -> [String: Any] {
    let prefs = try preferences()
    var result: [String: Any] = [:]

    for id in try serviceIDs(prefs) {
        for entity in ["Proxies", "DNS"] {
            let path = "/NetworkServices/\(id)/\(entity)"
            if let value = dictionary(prefs, path) {
                result[path] = value
            }
        }
    }

    return result
}

func applySettings(
    directory: String,
    mode: String,
    httpPort: Int,
    socksPort: Int,
    dns: [String]
) throws {
    let prefs = try preferences()

    try require(SCPreferencesLock(prefs, true), "Cannot lock preferences")
    defer { SCPreferencesUnlock(prefs) }

    let ids = try serviceIDs(prefs)
    try require(!ids.isEmpty, "No enabled network services")

    var entries: [[String: Any]] = []

    for id in ids {
        let entity = mode == "systemProxy" ? "Proxies" : "DNS"

        if entity == "DNS" && dns.isEmpty {
            continue
        }

        let path = "/NetworkServices/\(id)/\(entity)"
        let before = dictionary(prefs, path)
        var applied = before ?? [:]

        if entity == "Proxies" {
            applied["HTTPEnable"] = 1
            applied["HTTPProxy"] = "127.0.0.1"
            applied["HTTPPort"] = httpPort
            applied["HTTPSEnable"] = 1
            applied["HTTPSProxy"] = "127.0.0.1"
            applied["HTTPSPort"] = httpPort
            applied["SOCKSEnable"] = 1
            applied["SOCKSProxy"] = "127.0.0.1"
            applied["SOCKSPort"] = socksPort
            applied["ProxyAutoConfigEnable"] = 0
            applied["ProxyAutoDiscoveryEnable"] = 0
            applied["ExceptionsList"] = []
            applied["ExcludeSimpleHostnames"] = 0
        } else {
            applied["ServerAddresses"] = dns
        }

        entries.append([
            "path": path,
            "hadBefore": before != nil,
            "before": before ?? [:],
            "applied": applied
        ])
    }

    let journal = directory + "/network.plist"
    let data = try PropertyListSerialization.data(
        fromPropertyList: entries,
        format: .xml,
        options: 0
    )

    try data.write(to: URL(fileURLWithPath: journal), options: .atomic)
    chmod(journal, 0o644)

    for entry in entries {
        let path = entry["path"] as! String
        let applied = entry["applied"] as! [String: Any]

        try require(
            SCPreferencesPathSetValue(
                prefs,
                path as CFString,
                applied as CFDictionary
            ),
            "Cannot set \(path): \(SCError())"
        )
    }

    try commit(prefs)
}

func restoreSettings(_ directory: String) throws {
    let journal = directory + "/network.plist"

    guard FileManager.default.fileExists(atPath: journal) else {
        return
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: journal))
    guard let entries = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    ) as? [[String: Any]] else {
        throw Failure.message("Invalid network journal")
    }

    let prefs = try preferences()

    try require(SCPreferencesLock(prefs, true), "Cannot lock preferences")
    defer { SCPreferencesUnlock(prefs) }

    for entry in entries {
        let path = entry["path"] as! String
        let before = entry["before"] as! [String: Any]
        let applied = entry["applied"] as! [String: Any]
        let hadBefore = entry["hadBefore"] as! Bool
        let current = dictionary(prefs, path)

        if let current = current, same(current, applied) {
            if hadBefore {
                try require(
                    SCPreferencesPathSetValue(
                        prefs,
                        path as CFString,
                        before as CFDictionary
                    ),
                    "Cannot restore \(path)"
                )
            } else {
                try require(
                    SCPreferencesPathRemoveValue(prefs, path as CFString),
                    "Cannot remove \(path)"
                )
            }
        }
    }

    try commit(prefs)
    try FileManager.default.removeItem(atPath: journal)
}

func portOpen(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 {
        return false
    }
    defer { close(fd) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                fd,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            ) == 0
        }
    }
}

func acquireLock() throws -> Int32 {
    let fd = open(
        "/var/run/singbox-xray-flutter-dev.lock",
        O_CREAT | O_RDWR | O_NOFOLLOW,
        0o600
    )

    try require(fd >= 0, "Cannot open supervisor lock")

    if lockf(fd, F_TLOCK, 0) != 0 {
        close(fd)
        throw Failure.message("Другая сессия этого плагина уже активна. Завершите её и повторите.")
    }

    return fd
}

func probe(_ rawURL: String) throws {
    guard let url = URL(string: rawURL) else {
        throw Failure.message("Invalid probe URL")
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 25

    let session = URLSession(configuration: configuration)
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData

    let lock = NSLock()
    var finished = false
    var output: Data?
    var failure: Error?

    session.dataTask(with: request) { data, response, error in
        lock.lock()
        defer {
            finished = true
            lock.unlock()
        }

        if let error = error {
            failure = error
            return
        }

        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            failure = Failure.message("Probe returned a non-200 response")
            return
        }

        output = data
    }.resume()

    while true {
        lock.lock()
        let done = finished
        lock.unlock()

        if done {
            break
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    session.invalidateAndCancel()

    if let failure = failure {
        throw failure
    }

    guard let output = output else {
        throw Failure.message("Empty probe response")
    }

    FileHandle.standardOutput.write(output)
}

func runSession(_ directory: String) throws {
    try require(geteuid() == 0, "Supervisor requires administrator privileges")

    let lockFD = try acquireLock()
    defer { close(lockFD) }

    let manifest = try readJSON(directory + "/manifest.json")

    guard let binary = manifest["binary"] as? String,
          let core = manifest["core"] as? String,
          let mode = manifest["mode"] as? String,
          let owner = manifest["ownerPid"] as? Int,
          let httpPort = manifest["httpPort"] as? Int,
          let socksPort = manifest["socksPort"] as? Int,
          let dns = manifest["osDnsServers"] as? [String] else {
        throw Failure.message("Invalid session manifest")
    }

    try require(["singbox", "xray"].contains(core), "Unknown core")
    try require(["systemProxy", "tunnel"].contains(mode), "Unknown mode")

    let statePath = directory + "/state.json"
    let stopPath = directory + "/stop"
    let heartbeatPath = directory + "/heartbeat"
    let process = Process()

    var stopping = false
    var failure: Error?

    let sources = [SIGTERM, SIGINT, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: number,
            queue: .main
        )
        source.setEventHandler {
            stopping = true
        }
        source.resume()
        return source
    }

    defer {
        for source in sources {
            source.cancel()
        }
    }

    func shouldStop() -> Bool {
        if stopping || FileManager.default.fileExists(atPath: stopPath) {
            return true
        }

        if kill(pid_t(owner), 0) != 0 {
            return true
        }

        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: heartbeatPath
        ),
        let modified = attributes[.modificationDate] as? Date else {
            return true
        }

        return Date().timeIntervalSince(modified) > 20
    }

    do {
        try require(!shouldStop(), "Session cancelled before startup")
        try preflight()
        try require(!portOpen(httpPort), "HTTP port is already occupied")

        let log = try FileHandle(
            forWritingTo: URL(fileURLWithPath: directory + "/core.log")
        )
        defer { try? log.close() }

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = core == "singbox"
            ? ["run", "-c", directory + "/config.json"]
            : ["run", "-config", directory + "/config.json"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": directory,
            "TMPDIR": directory,
            "XRAY_LOCATIONS_ASSET":
                URL(fileURLWithPath: binary)
                    .deletingLastPathComponent().path
        ]
        process.standardOutput = log
        process.standardError = log

        try process.run()

        let deadline = Date().addingTimeInterval(20)

        while !portOpen(httpPort) {
            try require(process.isRunning, "Core exited during startup")
            try require(!shouldStop(), "Session cancelled during startup")
            try require(Date() < deadline, "Core startup timeout")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        try require(process.isRunning, "Core exited during startup")
        try require(!shouldStop(), "Session cancelled before network setup")

        try applySettings(
            directory: directory,
            mode: mode,
            httpPort: httpPort,
            socksPort: socksPort,
            dns: dns
        )

        try writeJSON([
            "state": "ready",
            "corePid": Int(process.processIdentifier),
            "supervisorPid": Int(getpid())
        ], to: statePath)

        while !shouldStop() {
            try require(process.isRunning, "Core exited unexpectedly")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    } catch {
        failure = error
    }

    do {
        try restoreSettings(directory)
    } catch {
        failure = error
    }

    if process.isRunning {
        process.terminate()

        let deadline = Date().addingTimeInterval(8)

        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        process.waitUntilExit()
    }

    if let failure = failure {
        try? writeJSON([
            "state": "failed",
            "error": String(describing: failure)
        ], to: statePath)
        throw failure
    }

    try writeJSON(["state": "stopped"], to: statePath)
}

do {
    let arguments = CommandLine.arguments
    try require(arguments.count >= 2, "Missing command")

    switch arguments[1] {
    case "run":
        try require(arguments.count == 3, "Expected session directory")
        try runSession(arguments[2])

    case "restore":
        try require(geteuid() == 0, "Restore requires administrator privileges")
        try require(arguments.count == 3, "Expected session directory")

        let fd = try acquireLock()
        defer { close(fd) }

        try restoreSettings(arguments[2])

    case "snapshot":
        let data = try JSONSerialization.data(
            withJSONObject: snapshot(),
            options: [.sortedKeys]
        )
        FileHandle.standardOutput.write(data)

    case "probe":
        try require(arguments.count == 3, "Expected probe URL")
        try probe(arguments[2])

    default:
        throw Failure.message("Unknown command")
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}