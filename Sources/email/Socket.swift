import Foundation
import Network

enum NetError: LocalizedError {
    case connect(String), closed, timeout, server(String), protocolError(String)

    var errorDescription: String? {
        switch self {
        case .connect(let s): return "couldn't connect — \(s)"
        case .closed: return "the server closed the connection"
        case .timeout: return "the server took too long to answer"
        case .server(let s): return s
        case .protocolError(let s): return "unexpected reply — \(s)"
        }
    }

    /// Transport failures are worth one reconnect; server refusals are not.
    var isTransport: Bool {
        switch self {
        case .connect, .closed, .timeout: return true
        default: return false
        }
    }
}

/// A small blocking CRLF socket over Network.framework (TLS), used from a background queue.
final class LineSocket {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "linesocket")
    private var buf = [UInt8]()
    private var pos = 0
    var timeout: TimeInterval = 30

    init(host: String, port: Int, tls: Bool) throws {
        let params: NWParameters = tls ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : .tcp
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: params)
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        var done = false
        conn.stateUpdateHandler = { state in
            guard !done else { return }
            switch state {
            case .ready: done = true; sem.signal()
            case .failed(let e), .waiting(let e): done = true; err = e; sem.signal()
            default: break
            }
        }
        conn.start(queue: queue)
        if sem.wait(timeout: .now() + 20) == .timedOut {
            conn.cancel()
            throw NetError.connect("couldn't reach \(host)")
        }
        if let err {
            conn.cancel()
            throw NetError.connect(err.localizedDescription)
        }
    }

    deinit { conn.cancel() }

    func close() { conn.cancel() }

    private func fill() throws {
        let sem = DispatchSemaphore(value: 0)
        var got: Data?
        var failure: Error?
        var ended = false
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
            got = data
            failure = error
            ended = complete
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { conn.cancel(); throw NetError.timeout }
        if let failure { throw NetError.connect(failure.localizedDescription) }
        guard let got, !got.isEmpty else {
            if ended { throw NetError.closed }
            return
        }
        buf.append(contentsOf: got)
    }

    private func compact() {
        if pos == buf.count { buf.removeAll(keepingCapacity: true); pos = 0 }
        else if pos > 1 << 20 { buf.removeFirst(pos); pos = 0 }
    }

    func readLine() throws -> [UInt8] {
        var from = pos
        while true {
            var i = from
            while i + 1 < buf.count {
                if buf[i] == 13 && buf[i + 1] == 10 {
                    let line = Array(buf[pos..<i])
                    pos = i + 2
                    compact()
                    return line
                }
                i += 1
            }
            from = max(pos, buf.count - 1)
            try fill()
        }
    }

    func readBytes(_ n: Int) throws -> [UInt8] {
        while buf.count - pos < n { try fill() }
        let out = Array(buf[pos..<pos + n])
        pos += n
        compact()
        return out
    }

    func write(_ bytes: [UInt8]) throws {
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        conn.send(content: Data(bytes), completion: .contentProcessed { e in failure = e; sem.signal() })
        if sem.wait(timeout: .now() + timeout) == .timedOut { conn.cancel(); throw NetError.timeout }
        if let failure { throw NetError.connect(failure.localizedDescription) }
    }

    func write(_ s: String) throws { try write(Array(s.utf8)) }
}
