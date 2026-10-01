import Foundation
import UIKit

/// Cerebro de la app: decide cuándo se transmite la voz (también con el iPhone bloqueado),
/// maneja la conexión con la PC y reenvía a la página lo que llega.
final class Core {
    static let shared = Core()

    var toPage: (([String: Any]) -> Void)?

    private let q = DispatchQueue(label: "mymic.core")
    private let link = Link()
    private let discovery = Discovery()
    private let audio = AudioCapture()
    private let cam = CameraCapture()

    // estado
    private var mode = "walkie"
    private var muted = false
    private var pressed = false
    private var pcMic = false
    private var audioOK = true
    private var connected = false
    private var started = false
    private var sending = false
    private var offWork: DispatchWorkItem?
    private var micOffWork: DispatchWorkItem?
    private var connecting: PCInfo?
    private var notFoundWork: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var camOn = false
    private var dimmed = false
    private var savedBrightness: CGFloat = 0.5
    private var lastLevelPush: TimeInterval = 0
    private var active = true
    /// Últimos mensajes de la PC por tipo, para ponerse al día al volver del segundo plano.
    private var lastMsgs: [String: String] = [:]

    private init() {
        link.queue = q
        link.onOpen = { [weak self] in self?.opened() }
        link.onClose = { [weak self] in self?.closed() }
        link.onText = { [weak self] s in self?.received(s) }
        link.onBinary = { [weak self] d in self?.receivedBinary(d) }
        link.onRTT = { [weak self] ms in self?.link.sendText("{\"type\":\"rtt\",\"ms\":\(ms)}") }

        audio.onChunk = { [weak self] data, level in
            self?.q.async { self?.audioChunk(data, level) }
        }
        audio.onError = { [weak self] msg in
            self?.q.async { self?.page(["t": "notice", "msg": msg]) }
        }
        cam.onFrame = { [weak self] kind, jpeg in
            guard let self = self else { return }
            var d = Data([kind]); d.append(jpeg)
            self.link.sendVideo(d)
        }
        cam.canSend = { [weak self] in self?.link.videoFree ?? false }
        cam.onError = { [weak self] msg in self?.page(["t": "camerr", "msg": msg, "off": true]) }

        discovery.onFound = { [weak self] pc in self?.q.async { self?.found(pc) } }

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.q.async { self?.becameActive() }
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            // Automático / Siempre: el micrófono queda abierto EN ESPERA (sin mandar nada) antes de irse
            // a segundo plano; si no, después de un rato bloqueado iOS no deja prenderlo cuando la PC lo pide.
            let standby = self.q.sync { self.started && self.mode != "walkie" }
            if standby {
                let task = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                self.audio.setMicNow(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { UIApplication.shared.endBackgroundTask(task) }
            }
            self.q.async { [weak self] in
                self?.active = false
                self?.pressed = false          // en Walkie, al bloquear se suelta el botón
                self?.update()
            }
            if self.dimmed { UIScreen.main.brightness = self.savedBrightness }
        }
    }

    // MARK: - desde la página
    func start(mode: String, muted: Bool) {
        q.async {
            self.mode = mode; self.muted = muted
            if self.started {             // la página se recargó: le contamos cómo estamos
                self.replay(); return
            }
            self.started = true
            self.audio.start()
            self.connectFlow()
        }
    }

    func setState(mode: String, muted: Bool, pressed: Bool) {
        q.async {
            self.mode = mode; self.muted = muted; self.pressed = pressed
            self.update()
        }
    }

    func sendText(_ s: String) { link.sendText(s) }
    func sendBinary(_ d: Data) { link.sendControlData(d) }

    func camera(on: Bool, facing: String, quality: String) {
        q.async {
            self.camOn = on
            if on { self.cam.start(facing: facing, quality: quality) } else { self.cam.stop() }
            self.idleTimer()
        }
    }

    func cameraQuality(_ quality: String) { cam.setQuality(quality) }

    func dim(_ on: Bool) {
        DispatchQueue.main.async {
            if on {
                if !self.dimmed { self.savedBrightness = UIScreen.main.brightness }
                UIScreen.main.brightness = 0
            } else if self.dimmed {
                UIScreen.main.brightness = self.savedBrightness
            }
            self.dimmed = on
            self.idleTimer()
        }
    }

    func manual(_ text: String) {
        q.async {
            self.page(["t": "conn", "state": "searching"])
            PCInfo.fromManual(text) { [weak self] pc in
                self?.q.async {
                    guard let self = self else { return }
                    if let pc = pc { self.tryConnect(pc) }
                    else { self.page(["t": "conn", "state": "notfound", "msg": "No pude conectar con esa dirección. Revisá que My Mic esté abierto en la PC."]) }
                }
            }
        }
    }

    // MARK: - conexión
    private func connectFlow() {
        page(["t": "conn", "state": "searching"])
        if let pc = PCInfo.saved { tryConnect(pc) }
        discovery.start()
        armNotFound()
    }

    private func armNotFound() {
        notFoundWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, !self.connected else { return }
            self.page(["t": "conn", "state": "notfound"])
        }
        notFoundWork = w
        q.asyncAfter(deadline: .now() + 8, execute: w)
    }

    private func found(_ pc: PCInfo) {
        if connected { return }
        // si ya estoy probando esa misma PC hace poco, no corto el intento
        if let cur = connecting, cur.host == pc.host, cur.https == pc.https,
           Date().timeIntervalSince(lastAttempt) < 5 { return }
        tryConnect(pc)
    }

    private var lastAttempt = Date.distantPast

    private func tryConnect(_ pc: PCInfo) {
        lastAttempt = Date()
        connecting = pc
        pc.ensureCA { [weak self] ready in
            self?.q.async {
                guard let self = self, let ready = ready, !self.connected else { return }
                self.connecting = ready
                self.link.connect(ready)
            }
        }
    }

    private func opened() {
        connected = true
        notFoundWork?.cancel()
        reconnectWork?.cancel()
        connecting?.save()
        discovery.stop()
        link.sendText("{\"type\":\"hello\",\"rate\":48000,\"mode\":\"\(mode)\"}")
        page(["t": "open"])
        if camOn { link.sendText("{\"type\":\"video\",\"on\":true}"); link.sendText("{\"type\":\"preview\",\"on\":true}") }
        sending = false
        update()
    }

    private func closed() {
        let was = connected
        connected = false
        if sending { sending = false; audio.transmitting = false; page(["t": "sending", "on": false]) }
        if was { page(["t": "close"]) }
        reconnectWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, !self.connected else { return }
            if let pc = PCInfo.saved { self.tryConnect(pc) }
            self.discovery.start()
            if !was { self.armNotFound() }
        }
        reconnectWork = w
        q.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func received(_ s: String) {
        guard let data = s.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = m["type"] as? String else { return }
        switch type {
        case "hello":
            pcMic = (m["pc_mic"] as? Bool) ?? false
        case "pcmic":
            pcMic = (m["on"] as? Bool) ?? false
        case "status":
            if let a = m["audio"] as? String { audioOK = (a == "ok") }
        case "mode":
            if let md = m["mode"] as? String { mode = md; pressed = false; muted = false }
        case "camcfg":
            applyCamCfg(m)
        default: break
        }
        lastMsgs[type] = s
        update()
        page(["t": "msg", "d": s])
    }

    /// Recorte "iPhone ★": el fondo lo pone el iPhone; si es una imagen, se baja de la PC.
    private var bgVersion = -1
    private func applyCamCfg(_ m: [String: Any]) {
        let bg = m["bg"] as? String ?? "none"
        let phone = (m["seg"] as? String) == "iphone"
        cam.setFx(bg: bg, phoneSeg: phone)
        let v = (m["bg_v"] as? Int) ?? 0
        guard phone, bg == "image", (m["has_bg"] as? Bool) == true, v != bgVersion,
              let pc = connecting,
              let url = URL(string: "http://\(PCInfo.urlHost(pc.host)):\(pc.http)/bg.jpg?v=\(v)") else { return }
        bgVersion = v
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            if let data = data, !data.isEmpty { self?.cam.setBackground(data) }
        }.resume()
    }

    private func receivedBinary(_ d: Data) {
        guard active, d.first == 9, d.count > 1 else { return }   // vista previa: solo si se está mirando
        page(["t": "prev", "b64": d.dropFirst().base64EncodedString()])
    }

    private func becameActive() {
        active = true
        if dimmed { DispatchQueue.main.async { UIScreen.main.brightness = 0 } }
        if started && !connected { link.close(); connectFlow() }
        replay()
        update()          // si iOS no dejó prender el mic en segundo plano, se reintenta ahora
    }

    /// Al volver a la app, la página se pone al día con lo que pasó mientras estaba bloqueada.
    private func replay() {
        page(connected ? ["t": "open"] : ["t": "conn", "state": "searching"])
        for k in ["hello", "status", "camcfg", "pcmic", "mode"] {
            if let s = lastMsgs[k] { page(["t": "msg", "d": s]) }
        }
        page(["t": "sending", "on": sending])
    }

    // MARK: - voz
    private func shouldSend() -> Bool {
        guard connected, audioOK else { return false }
        switch mode {
        case "walkie": return pressed
        case "auto": return pcMic && !muted
        default: return !muted
        }
    }

    private func update() {
        micControl()
        if shouldSend() {
            offWork?.cancel(); offWork = nil
            if !sending {
                sending = true
                audio.transmitting = true
                link.sendText("{\"type\":\"talk\",\"on\":true}")
                page(["t": "sending", "on": true])
            }
        } else if sending && offWork == nil {
            let w = DispatchWorkItem { [weak self] in      // un poquito de cola para no cortar la última sílaba
                guard let self = self else { return }
                self.offWork = nil
                if self.shouldSend() { return }
                self.sending = false
                self.audio.transmitting = false
                self.link.sendText("{\"type\":\"talk\",\"on\":false}")
                self.page(["t": "sending", "on": false])
            }
            offWork = w
            q.asyncAfter(deadline: .now() + 0.22, execute: w)
        }
    }

    /// El micrófono se abre solo cuando hay que transmitir y se cierra 4 s después
    /// (así en Walkie no se corta entre frase y frase, y el indicador de iOS desaparece solo).
    /// En segundo plano (Automático o Siempre) el micrófono se mantiene abierto en espera.
    private var standby: Bool { !active && started && mode != "walkie" }

    private func micControl() {
        if shouldSend() || standby {
            micOffWork?.cancel(); micOffWork = nil
            audio.setMic(true)
        } else if micOffWork == nil {
            let w = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.micOffWork = nil
                if !self.shouldSend() && !self.standby { self.audio.setMic(false) }
            }
            micOffWork = w
            q.asyncAfter(deadline: .now() + 4, execute: w)
        }
    }

    private func audioChunk(_ data: Data, _ level: Float) {
        guard sending else { return }
        var d = Data([1]); d.append(data)
        link.sendAudio(d)
        let now = Date().timeIntervalSince1970
        if active && now - lastLevelPush > 0.066 {
            lastLevelPush = now
            page(["t": "lvl", "v": Double(level)])
        }
    }

    // MARK: - varios
    private func idleTimer() {
        let keep = camOn || dimmed
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = keep }
    }

    private func page(_ obj: [String: Any]) {
        guard active || obj["t"] as? String == "sending" else { return }
        toPage?(obj)
    }
}
