import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UIKit
import Vision

/// Micrófono nativo. El micrófono SOLO se abre mientras transmite (así el indicador naranja /
/// la isla dinámica no aparece todo el tiempo). Para seguir viva con el iPhone bloqueado sin usar
/// el micrófono, la app reproduce silencio (UIBackgroundModes: audio), que no muestra indicador.
/// Entrega bloques de 10 ms en PCM 16 bits, 48 kHz, mono (el mismo formato que la app web).
final class AudioCapture {
    var onChunk: ((Data, Float) -> Void)?
    var onError: ((String) -> Void)?
    var onMicState: ((Bool) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
    private var pending = Data()
    private let chunkBytes = 960            // 480 muestras = 10 ms
    private var running = false             // micrófono abierto
    private var wanted = false              // alguien pidió el micrófono
    private var allowed = false
    private var keepAlive: AVAudioPlayer?

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended { self?.recover() }       // por ejemplo, después de una llamada
            else { self?.running = false }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.running = false
            self?.recover()
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            // se conectaron o desconectaron auriculares: el formato de entrada puede cambiar
            guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self = self, self.running else { return }
                self.stopMic(); self.startMic()
            }
        }
    }

    /// Pide permiso y deja la app lista (y viva en segundo plano) sin abrir el micrófono.
    func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted { self.allowed = true; self.activateSession(); if self.wanted { self.startMic() } }
                else { self.onError?("Permití el micrófono en Ajustes > MyMic") }
            }
        }
    }

    /// Prende o apaga el micrófono de verdad.
    func setMic(_ on: Bool) {
        DispatchQueue.main.async {
            self.wanted = on
            guard self.allowed else { return }
            if on && !self.running { self.startMic() }
            if !on && self.running { self.stopMic() }
        }
    }

    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try? s.setPreferredSampleRate(48000)
            try? s.setPreferredIOBufferDuration(0.01)
            try s.setActive(true)
        } catch {
            onError?("No pude preparar el audio del iPhone")
            return
        }
        startKeepAlive()
    }

    /// Silencio en loop: mantiene la app despierta con el iPhone bloqueado, sin indicador de micrófono.
    private func startKeepAlive() {
        if keepAlive == nil {
            keepAlive = try? AVAudioPlayer(data: AudioCapture.silentWav())
            keepAlive?.numberOfLoops = -1
            keepAlive?.volume = 0
        }
        if keepAlive?.isPlaying != true { keepAlive?.play() }
    }

    private func recover() {
        guard allowed else { return }
        activateSession()
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if wanted { startMic() }
    }

    private func startMic() {
        guard !running else { return }
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)     // cancelación de eco y ruido, como en la app web
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { onError?("El micrófono no está disponible"); return }
        converter = AVAudioConverter(from: inFmt, to: outFmt)
        pending.removeAll()
        input.installTap(onBus: 0, bufferSize: 480, format: inFmt) { [weak self] buf, _ in self?.process(buf) }
        engine.prepare()
        do {
            try engine.start()
            running = true
            onMicState?(true)
        } catch {
            input.removeTap(onBus: 0)
            onMicState?(false)
            // iOS a veces no deja abrir el micrófono con la app en segundo plano: se reintenta al volver
            onError?("iOS no dejó prender el micrófono. Abrí MyMic un momento.")
        }
    }

    private func stopMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        running = false
        onMicState?(false)
    }

    /// WAV de 1 segundo de silencio (se genera acá, no ocupa archivos).
    private static func silentWav() -> Data {
        let rate: UInt32 = 8000, samples: UInt32 = 8000
        let dataBytes = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        d.append(Data(count: Int(dataBytes)))
        return d
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let conv = converter, buf.frameLength > 0 else { return }
        // nivel de volumen
        var level: Float = 0
        if let ch = buf.floatChannelData?[0] {
            var sum: Float = 0
            let n = Int(buf.frameLength)
            for i in 0..<n { sum += ch[i] * ch[i] }
            level = sqrt(sum / Float(n))
        }
        // a 48 kHz mono 16 bits
        let ratio = outFmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
        pending.append(Data(bytes: p, count: Int(out.frameLength) * 2))
        while pending.count >= chunkBytes {
            let chunk = pending.prefix(chunkBytes)
            pending.removeFirst(chunkBytes)
            onChunk?(Data(chunk), level)
        }
    }
}

/// Cámara nativa. Manda JPEG a la PC:
///  - tipo 2: la imagen tal cual (la PC pone fondo y efectos), igual que la app web.
///  - tipo 5: con el fondo ya puesto acá con Apple Vision (recorte "iPhone ★", como Camo),
///            en 16:9; la PC solo aplica zoom, espejo y color.
/// Apple no deja usar la cámara con el iPhone bloqueado; al volver sigue sola.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((UInt8, Data) -> Void)?
    var onError: ((String) -> Void)?
    var canSend: () -> Bool = { true }

    private let session = AVCaptureSession()
    private let q = DispatchQueue(label: "mymic.camera")
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private let output = AVCaptureVideoDataOutput()
    private var configured = false
    private var position: AVCaptureDevice.Position = .front
    private var maxSide: CGFloat = 960
    private var jpegQ: CGFloat = 0.7
    private var interval: CFTimeInterval = 1.0 / 18
    private var last: CFTimeInterval = 0

    // recorte en el iPhone
    private var bgMode = "none"
    private var phoneSeg = false
    private var bgImage: CIImage?
    private let seq = VNSequenceRequestHandler()
    private lazy var segReq: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced                 // tiempo real, corre en el chip de IA del iPhone
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    func setFx(bg: String, phoneSeg: Bool) { q.async { self.bgMode = bg; self.phoneSeg = phoneSeg } }
    func setBackground(_ data: Data) { q.async { self.bgImage = CIImage(data: data) } }

    func start(facing: String, quality: String) {
        setQuality(quality)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
            guard let self = self else { return }
            guard ok else { self.onError?("Permití la cámara en Ajustes > MyMic"); return }
            self.q.async {
                self.position = facing == "environment" ? .back : .front
                if !self.configure() { self.onError?("No pude usar la cámara"); return }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        q.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func setQuality(_ quality: String) {
        q.async {
            switch quality {
            case "low": self.maxSide = 640; self.jpegQ = 0.6; self.interval = 1.0 / 12
            case "high": self.maxSide = 1280; self.jpegQ = 0.8; self.interval = 1.0 / 24
            default: self.maxSide = 960; self.jpegQ = 0.7; self.interval = 1.0 / 18
            }
        }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        session.inputs.forEach { session.removeInput($0) }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return false }
        session.addInput(input)
        if !configured {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: q)
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            configured = true
        }
        if let c = output.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            } else if c.isVideoOrientationSupported {
                c.videoOrientation = .portrait
            }
            if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
        }
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - last >= interval, canSend(), let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        last = now
        var img = CIImage(cvPixelBuffer: pb)
        var kind: UInt8 = 2
        if phoneSeg && bgMode != "none", let out = composite(pb, img) {
            img = out; kind = 5
        } else {
            let side = max(img.extent.width, img.extent.height)
            if side > maxSide {
                let k = maxSide / side
                img = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
            }
        }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ci.jpegRepresentation(of: img, colorSpace: cs, options: [key: jpegQ]) else { return }
        onFrame?(kind, jpeg)
    }

    /// Recorta a la persona con Apple Vision y la pone sobre el fondo, en un lienzo 16:9.
    private func composite(_ pb: CVPixelBuffer, _ frame: CIImage) -> CIImage? {
        do { try seq.perform([segReq], on: pb) } catch { return nil }
        guard let maskPB = segReq.results?.first?.pixelBuffer else { return nil }
        let W = maxSide, H = (maxSide * 9 / 16).rounded()
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let k = H / frame.extent.height
        let fw = frame.extent.width * k
        let dx = ((W - fw) / 2).rounded()
        let fg = frame.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: dx, y: 0)))
        var mask = CIImage(cvPixelBuffer: maskPB)
        mask = mask.transformed(by: CGAffineTransform(scaleX: fw / mask.extent.width, y: H / mask.extent.height)
            .concatenating(CGAffineTransform(translationX: dx, y: 0)))
        let bg: CIImage
        if bgMode == "image", let b = bgImage {
            bg = aspectFill(b, canvas)
        } else {
            let small = aspectFill(frame, canvas).transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
            bg = small.clampedToExtent().applyingGaussianBlur(sigma: 6)
                .transformed(by: CGAffineTransform(scaleX: 4, y: 4)).cropped(to: canvas)
        }
        let out = fg.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bg,
            kCIInputMaskImageKey: mask,
        ])
        return out.cropped(to: canvas)
    }

    private func aspectFill(_ i: CIImage, _ r: CGRect) -> CIImage {
        let base = i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
        let s = max(r.width / base.extent.width, r.height / base.extent.height)
        let t = base.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let dx = (r.width - t.extent.width) / 2, dy = (r.height - t.extent.height) / 2
        return t.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: r)
    }
}
