import Foundation
import Network

/// A minimal passive-mode FTP server bound to 127.0.0.1 for integration tests.
final class LocalFTPServer: @unchecked Sendable {
    struct Account: Sendable {
        var user: String
        var password: String
    }

    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var log: [String] = []
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var activeTransfers = 0
    private var maxActiveTransfers = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalFTPServer")
    private(set) var port: UInt16 = 0

    /// nil accepts anonymous logins with any password.
    var account: Account? {
        get { lock.withLock { _account } }
        set { lock.withLock { _account = newValue } }
    }
    var supportsRest: Bool {
        get { lock.withLock { _supportsRest } }
        set { lock.withLock { _supportsRest = newValue } }
    }
    var bytesPerSecond: Int? {
        get { lock.withLock { _bytesPerSecond } }
        set { lock.withLock { _bytesPerSecond = newValue } }
    }
    var supportsEPSV: Bool {
        get { lock.withLock { _supportsEPSV } }
        set { lock.withLock { _supportsEPSV = newValue } }
    }
    private var _supportsEPSV = true
    private var _account: Account?
    private var _supportsRest = true
    private var _bytesPerSecond: Int?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        // The port is bound right after start; poll it instead of blocking on a state callback.
        let deadline = Date().addingTimeInterval(5)
        while (listener.port?.rawValue ?? 0) == 0, Date() < deadline {
            usleep(1000)
        }
        guard let port = listener.port?.rawValue, port != 0 else {
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    deinit { stop() }

    func url(_ path: String, user: String? = nil, password: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.user = user
        components.password = password
        components.path = path
        return components.url!
    }

    func setFile(_ path: String, _ data: Data) {
        lock.withLock { files[path] = data }
    }

    var commands: [String] { lock.withLock { log } }
    var peakConcurrentTransfers: Int { lock.withLock { maxActiveTransfers } }

    func stop() {
        listener.cancel()
        let all = lock.withLock { () -> [Session] in
            let all = Array(sessions.values)
            sessions.removeAll()
            return all
        }
        all.forEach { $0.close() }
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(server: self, control: connection)
        lock.withLock { sessions[ObjectIdentifier(session)] = session }
        session.start()
    }

    fileprivate func record(_ line: String) {
        lock.withLock { log.append(line) }
    }

    fileprivate func file(_ path: String) -> Data? {
        lock.withLock { files[path] }
    }

    fileprivate func transferStarted() {
        lock.withLock {
            activeTransfers += 1
            maxActiveTransfers = max(maxActiveTransfers, activeTransfers)
        }
    }

    fileprivate func transferEnded() {
        lock.withLock { activeTransfers -= 1 }
    }

    fileprivate func ended(_ session: Session) {
        lock.withLock { _ = sessions.removeValue(forKey: ObjectIdentifier(session)) }
    }

    fileprivate var settings: (account: Account?, rest: Bool, rate: Int?) {
        lock.withLock { (_account, _supportsRest, _bytesPerSecond) }
    }

    // MARK: - Session

    fileprivate final class Session: @unchecked Sendable {
        weak var server: LocalFTPServer?
        let control: NWConnection
        let queue = DispatchQueue(label: "LocalFTPServer.session")
        var buffer = Data()
        var user: String?
        var loggedIn = false
        var restOffset = 0
        var cwd = "/"
        var passiveListener: NWListener?
        var dataConnection: NWConnection?
        var waitingForData: ((NWConnection) -> Void)?
        var transferring = false
        var aborted = false

        init(server: LocalFTPServer, control: NWConnection) {
            self.server = server
            self.control = control
        }

        func start() {
            control.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.passiveListener?.cancel()
                    self.dataConnection?.cancel()
                    self.server?.ended(self)
                default: break
                }
            }
            control.start(queue: queue)
            reply("220 cDownloader test FTP ready")
            receive()
        }

        func close() {
            queue.async {
                self.passiveListener?.cancel()
                self.dataConnection?.cancel()
                self.control.cancel()
            }
        }

        private func reply(_ line: String) {
            control.send(content: Data((line + "\r\n").utf8), completion: .contentProcessed { _ in })
        }

        private func receive() {
            control.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                while let range = self.buffer.range(of: Data("\r\n".utf8)) {
                    let line = String(decoding: self.buffer[self.buffer.startIndex..<range.lowerBound], as: UTF8.self)
                    self.buffer.removeSubrange(self.buffer.startIndex..<range.upperBound)
                    self.handle(line)
                }
                if isComplete || error != nil {
                    self.control.cancel()
                } else {
                    self.receive()
                }
            }
        }

        private func resolve(_ path: String) -> String {
            if path.hasPrefix("/") { return path }
            return (cwd.hasSuffix("/") ? cwd : cwd + "/") + path
        }

        private func handle(_ line: String) {
            guard let server else { return }
            server.record(line)
            let parts = line.split(separator: " ", maxSplits: 1)
            let command = parts.first.map { $0.uppercased() } ?? ""
            let argument = parts.count > 1 ? String(parts[1]) : ""
            let settings = server.settings

            switch command {
            case "USER":
                user = argument
                reply("331 Password required")
            case "PASS":
                if let account = settings.account {
                    loggedIn = user == account.user && argument == account.password
                } else {
                    loggedIn = true
                }
                reply(loggedIn ? "230 Logged in" : "530 Login incorrect")
            case "SYST":
                reply("215 UNIX Type: L8")
            case "FEAT":
                reply("211-Features:\r\n SIZE\r\n MDTM\r\n EPSV\r\n" + (settings.rest ? " REST STREAM\r\n" : "") + "211 End")
            case "OPTS", "NOOP", "TYPE", "MODE", "STRU":
                reply("200 OK")
            case "PWD":
                reply("257 \"\(cwd)\"")
            case "CWD":
                cwd = resolve(argument)
                reply("250 OK")
            case "QUIT":
                reply("221 Bye")
                control.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [control] _ in
                    control.cancel()
                })
            default:
                guard loggedIn else { return reply("530 Not logged in") }
                handleLoggedIn(command, argument, settings: settings)
            }
        }

        private func handleLoggedIn(_ command: String, _ argument: String, settings: (account: Account?, rest: Bool, rate: Int?)) {
            switch command {
            case "SIZE":
                if let data = server?.file(resolve(argument)) {
                    reply("213 \(data.count)")
                } else {
                    reply("550 No such file")
                }
            case "MDTM":
                server?.file(resolve(argument)) != nil ? reply("213 20240102030405") : reply("550 No such file")
            case "REST":
                guard settings.rest else { return reply("502 REST not implemented") }
                restOffset = Int(argument) ?? 0
                reply("350 Restarting at \(restOffset)")
            case "EPSV" where !(server?.supportsEPSV ?? true):
                reply("500 EPSV not understood")
            case "PASV", "EPSV":
                openPassive(extended: command == "EPSV")
            case "RETR":
                retrieve(resolve(argument), rate: settings.rate)
            case "ABOR":
                if transferring {
                    aborted = true
                    dataConnection?.forceCancel()
                    reply("426 Transfer aborted")
                }
                reply("226 ABOR successful")
            default:
                reply("502 Command not implemented")
            }
        }

        private func openPassive(extended: Bool) {
            passiveListener?.cancel()
            dataConnection = nil
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            guard let listener = try? NWListener(using: parameters) else { return reply("425 Cannot open data port") }
            passiveListener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.dataConnection = connection
                if let waiting = self.waitingForData {
                    self.waitingForData = nil
                    waiting(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state, let port = listener.port?.rawValue else { return }
                if extended {
                    self.reply("229 Entering Extended Passive Mode (|||\(port)|)")
                } else {
                    self.reply("227 Entering Passive Mode (127,0,0,1,\(port / 256),\(port % 256))")
                }
            }
            listener.start(queue: queue)
        }

        private func retrieve(_ path: String, rate: Int?) {
            guard let data = server?.file(path) else {
                return reply("550 No such file")
            }
            let offset = min(restOffset, data.count)
            restOffset = 0
            guard passiveListener != nil else { return reply("425 Use PASV first") }
            reply("150 Opening BINARY mode data connection")
            transferring = true
            aborted = false
            server?.transferStarted()
            let begin: (NWConnection) -> Void = { [weak self] connection in
                self?.sendChunk(connection, data: data, offset: offset, rate: rate)
            }
            if let connection = dataConnection {
                begin(connection)
            } else {
                waitingForData = begin
            }
        }

        private func sendChunk(_ connection: NWConnection, data: Data, offset: Int, rate: Int?) {
            if aborted { return finishTransfer(connection, ok: false) }
            guard offset < data.count else { return finishTransfer(connection, ok: true) }
            let size = rate.map { max(1, min(16384, $0 / 10)) } ?? 65536
            let end = min(data.count, offset + size)
            let chunk = data.subdata(in: offset..<end)
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if error != nil { return self.finishTransfer(connection, ok: false) }
                    if let rate {
                        self.queue.asyncAfter(deadline: .now() + Double(chunk.count) / Double(rate)) {
                            self.sendChunk(connection, data: data, offset: end, rate: rate)
                        }
                    } else {
                        self.sendChunk(connection, data: data, offset: end, rate: rate)
                    }
                }
            })
        }

        private func finishTransfer(_ connection: NWConnection, ok: Bool) {
            guard transferring else { return }
            transferring = false
            server?.transferEnded()
            passiveListener?.cancel()
            passiveListener = nil
            dataConnection = nil
            if ok {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                reply("226 Transfer complete")
            } else {
                connection.forceCancel()
                if !aborted { reply("426 Connection closed; transfer aborted") }
            }
        }
    }
}
