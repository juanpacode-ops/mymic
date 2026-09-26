import Foundation
import CryptoKit
import Security

/// Datos de la PC donde corre My Mic.
struct PCInfo: Codable {
    var name: String
    var host: String      // IP o nombre.local
    var https: Int        // puerto del canal seguro (audio, video, control)
    var http: Int         // puerto del panel (de ahí se baja el certificado)
    var fp: String        // huella SHA-256 del certificado de My Mic (la anuncia la PC por Bonjour)
    var ca: Data?         // certificado de My Mic (DER)

    static var saved: PCInfo? {
        guard let d = UserDefaults.standard.data(forKey: "pc") else { return nil }
        return try? JSONDecoder().decode(PCInfo.self, from: d)
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "pc") }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2.5
        return URLSession(configuration: c)
    }()

    /// Se asegura de tener el certificado de la PC (y de que coincida con la huella anunciada).
    func ensureCA(_ done: @escaping (PCInfo?) -> Void) {
        if let ca = ca, fp.isEmpty || PCInfo.sha(ca) == fp { done(self); return }
        if let s = PCInfo.saved, let ca = s.ca, s.host == host, !fp.isEmpty, PCInfo.sha(ca) == fp {
            var me = self; me.ca = ca; done(me); return
        }
        guard let url = URL(string: "http://\(PCInfo.urlHost(host)):\(http)/ca.der") else { done(nil); return }
        PCInfo.session.dataTask(with: url) { data, _, _ in
            guard let data = data, !data.isEmpty else { done(nil); return }
            if !fp.isEmpty && PCInfo.sha(data) != fp { done(nil); return }   // no es tu PC: no confiar
            var me = self
            me.ca = data
            if me.fp.isEmpty { me.fp = PCInfo.sha(data) }
            done(me)
        }.resume()
    }

    /// Dirección escrita a mano: "192.168.1.16", "192.168.1.16:18080" o "http://juanpa.local:18080".
    static func fromManual(_ raw: String, _ done: @escaping (PCInfo?) -> Void) {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["http://", "https://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        var host = t
        var ports = [8080, 18080, 28080, 38080, 5080, 3080, 58080]
        if let colon = t.lastIndex(of: ":"), let p = Int(t[t.index(after: colon)...]) {
            host = String(t[..<colon]); ports = [p] + ports
        }
        guard !host.isEmpty else { done(nil); return }
        tryPorts(host, ports, done)
    }

    private static func tryPorts(_ host: String, _ ports: [Int], _ done: @escaping (PCInfo?) -> Void) {
        guard let port = ports.first, let url = URL(string: "http://\(urlHost(host)):\(port)/info") else { done(nil); return }
        session.dataTask(with: url) { data, _, _ in
            if let data = data,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let https = j["https_port"] as? Int {
                let name = (j["host"] as? String)?.replacingOccurrences(of: ".local", with: "") ?? host
                PCInfo(name: name, host: host, https: https, http: port, fp: "", ca: nil).ensureCA(done)
            } else {
                tryPorts(host, Array(ports.dropFirst()), done)
            }
        }.resume()
    }

    static func urlHost(_ h: String) -> String { h.contains(":") ? "[\(h)]" : h }
    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}

/// Busca la PC en el Wi-Fi por Bonjour (_mymic._tcp).
final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onFound: ((PCInfo) -> Void)?
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []

    func start() {
        DispatchQueue.main.async {
            guard self.browser == nil else { return }
            let b = NetServiceBrowser()
            b.delegate = self
            self.browser = b
            b.searchForServices(ofType: "_mymic._tcp.", inDomain: "local.")
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.browser?.stop()
            self.browser = nil
            self.services.forEach { $0.stop() }
            self.services.removeAll()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        self.browser = nil
    }

    func netServiceDidResolveAddress(_ s: NetService) {
        var txt: [String: String] = [:]
        if let data = s.txtRecordData() {
            for (k, v) in NetService.dictionary(fromTXTRecord: data) { txt[k] = String(data: v, encoding: .utf8) }
        }
        var ip: String?
        for addr in s.addresses ?? [] where addr.count >= MemoryLayout<sockaddr_in>.size {
            var sin = sockaddr_in()
            _ = withUnsafeMutableBytes(of: &sin) { addr.copyBytes(to: $0, count: MemoryLayout<sockaddr_in>.size) }
            if sin.sin_family == sa_family_t(AF_INET) {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                ip = String(cString: buf)
                break
            }
        }
        let host = ip ?? s.hostName ?? ""
        guard !host.isEmpty else { return }
        let https = Int(txt["https"] ?? "") ?? s.port
        let http = Int(txt["http"] ?? "") ?? 8080
        onFound?(PCInfo(name: txt["name"] ?? s.name, host: host, https: https, http: http, fp: txt["fp"] ?? "", ca: nil))
    }
}

/// Las dos conexiones con la PC: control+video (/ws) y voz (/wsa, aparte para que no espere al video).
final class Link: NSObject, URLSessionWebSocketDelegate {
    var queue = DispatchQueue(label: "mymic.link")
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onRTT: ((Int) -> Void)?

    private var session: URLSession?
    private var ctl: URLSessionWebSocketTask?
    private var aud: URLSessionWebSocketTask?
    private var ca: SecCertificate?
    private var gen = 0
    private var pendingAudio = 0
    private var videoBusy = false
    private var pingTimer: DispatchSourceTimer?
    private let lock = NSLock()

    var videoFree: Bool { lock.lock(); defer { lock.unlock() }; return !videoBusy && ctl != nil }

    func connect(_ pc: PCInfo) {
        close()
        gen += 1
        let g = gen
        if let der = pc.ca { ca = SecCertificateCreateWithData(nil, der as CFData) }
        let oq = OperationQueue()
        oq.underlyingQueue = queue
        oq.maxConcurrentOperationCount = 1
        let conf = URLSessionConfiguration.default
        conf.waitsForConnectivity = false
        conf.timeoutIntervalForRequest = 6
        let s = URLSession(configuration: conf, delegate: self, delegateQueue: oq)
        session = s
        let h = PCInfo.urlHost(pc.host)
        guard let u1 = URL(string: "wss://\(h):\(pc.https)/ws"), let u2 = URL(string: "wss://\(h):\(pc.https)/wsa") else { return }
        let c = s.webSocketTask(with: u1)
        c.maximumMessageSize = 8 * 1024 * 1024
        let a = s.webSocketTask(with: u2)
        ctl = c; aud = a
        c.resume(); a.resume()
        receive(c, g); receive(a, g)
    }

    func close() {
        gen += 1
        pingTimer?.cancel(); pingTimer = nil
        ctl?.cancel(with: .goingAway, reason: nil)
        aud?.cancel(with: .goingAway, reason: nil)
        ctl = nil; aud = nil
        session?.invalidateAndCancel(); session = nil
        lock.lock(); videoBusy = false; lock.unlock()
        pendingAudio = 0
    }

    private func receive(_ task: URLSessionWebSocketTask, _ g: Int) {
        task.receive { [weak self] result in
            guard let self = self, g == self.gen else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let s):
                    if task === self.aud {
                        if s.hasPrefix("{\"type\":\"pong\"") { self.pong(s) }
                    } else { self.onText?(s) }
                case .data(let d):
                    if task === self.ctl { self.onBinary?(d) }
                @unknown default: break
                }
                self.receive(task, g)
            case .failure:
                if task === self.ctl { self.failed(g) }
                else { self.aud = nil }        // sin canal de voz: se usa el de control
            }
        }
    }

    private func failed(_ g: Int) {
        guard g == gen else { return }
        close()
        onClose?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        if webSocketTask === ctl {
            startPing()
            onOpen?()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if webSocketTask === ctl { failed(gen) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task === ctl, error != nil { failed(gen) }
    }

    /// Confía solo en el certificado de TU PC (el que anuncia por Bonjour), aunque no esté instalado en el iPhone.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if let ca = ca {
            SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var err: CFError?
            if SecTrustEvaluateWithError(trust, &err) {
                completionHandler(.useCredential, URLCredential(trust: trust)); return
            }
        }
        completionHandler(.performDefaultHandling, nil)   // último intento: el certificado instalado en el iPhone
    }

    // MARK: envío
    func sendText(_ s: String) { ctl?.send(.string(s)) { _ in } }

    func sendControlData(_ d: Data) { ctl?.send(.data(d)) { _ in } }

    func sendAudio(_ d: Data) {
        guard let ch = aud ?? ctl else { return }
        if pendingAudio > 4 { return }                 // si el Wi-Fi se atrasa, se descarta en vez de acumular
        pendingAudio += 1
        ch.send(.data(d)) { [weak self] _ in self?.queue.async { self?.pendingAudio -= 1 } }
    }

    func sendVideo(_ d: Data) {
        lock.lock()
        if videoBusy || ctl == nil { lock.unlock(); return }
        videoBusy = true
        lock.unlock()
        ctl?.send(.data(d)) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); self.videoBusy = false; self.lock.unlock()
        }
    }

    // MARK: medición del retraso de red
    private func startPing() {
        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self = self, let a = self.aud else { return }
            let ms = Int(Date().timeIntervalSince1970 * 1000)
            a.send(.string("{\"type\":\"ping\",\"t\":\(ms)}")) { _ in }
        }
        t.resume()
        pingTimer = t
    }

    private func pong(_ s: String) {
        guard let data = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = j["t"] as? Double else { return }
        let rtt = Int(Date().timeIntervalSince1970 * 1000 - t)
        if rtt >= 0 && rtt < 5000 { onRTT?(rtt) }
    }
}
