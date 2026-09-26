import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UIKit

/// Micrófono nativo: sigue funcionando con el iPhone bloqueado (UIBackgroundModes: audio).
/// Entrega bloques de 10 ms en PCM 16 bits, 48 kHz, mono (el mismo formato que la app web).
final class AudioCapture {
    var onChunk: ((Data, Float) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
    private var pending = Data()
    private let chunkBytes = 960            // 480 muestras = 10 ms
    private var running = false

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended { self?.restart() }       // por ejemplo, después de una llamada
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            // se conectaron o desconectaron auriculares: el formato de entrada puede cambiar
            guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.restart() }
        }
    }

    func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted { self?.run() }
                else { self?.onError?("Permití el micrófono en Ajustes > MyMic") }
            }
        }
    }

    private func restart() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        run()
    }

    private func run() {
        guard !running else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try? s.setPreferredSampleRate(48000)
            try? s.setPreferredIOBufferDuration(0.01)
            try s.setActive(true)
        } catch {
            onError?("No pude abrir el micrófono del iPhone")
            return
        }
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)     // cancelación de eco y ruido, como en la app web
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { onError?("El micrófono no está disponible"); return }
        converter = AVAudioConverter(from: inFmt, to: outFmt)
        input.installTap(onBus: 0, bufferSize: 480, format: inFmt) { [weak self] buf, _ in self?.process(buf) }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
            onError?("No pude arrancar el micrófono del iPhone")
        }
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

/// Cámara nativa: manda JPEG verticales a la PC, como la app web (la PC aplica fondo y efectos).
/// Apple no deja usar la cámara con el iPhone bloqueado; al volver sigue sola.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((Data) -> Void)?
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
        let side = max(img.extent.width, img.extent.height)
        if side > maxSide {
            let k = maxSide / side
            img = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ci.jpegRepresentation(of: img, colorSpace: cs, options: [key: jpegQ]) else { return }
        onFrame?(jpeg)
    }
}
