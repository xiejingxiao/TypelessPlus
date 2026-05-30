import AVFoundation
import Foundation

enum StopReason {
    case userReleased
    case timeout
    case sizeLimitExceeded
    case error(Error)
}

/// 音频录制器：使用 AVAudioEngine 采集麦克风输入，降采样到 16kHz
final class AudioRecorder: NSObject {
    private let engine = AVAudioEngine()
    private var audioBuffer = Data()
    private var sampleRate: Double = 16000
    private let bufferQueue = DispatchQueue(label: "com.typeless.audio")

    // MARK: - Timeout & Size Protection
    var maxDuration: TimeInterval = 120
    private var startTime: Date?
    private var timeoutTimer: Timer?
    private var sizeCheckTimer: Timer?
    let maxFileSize: Int = 50 * 1024 * 1024

    var currentFileSize: Int {
        bufferQueue.sync { audioBuffer.count }
    }

    func startRecording() {
        audioBuffer = Data()
        startTime = Date()
        startTimeoutTimer()
        startSizeCheckTimer()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // whisper 需要 16kHz, 16-bit PCM, 单声道
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            print("[AudioRecorder] Failed to create output format")
            return
        }

        // 如果输入格式已经是 16kHz 单声道 Int16，直接采集无需转换
        if formatsMatch(inputFormat, outputFormat) {
            installDirectTap(inputNode: inputNode, format: inputFormat)
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                print("[AudioRecorder] Failed to create converter")
                return
            }
            installConvertingTap(inputNode: inputNode, inputFormat: inputFormat, outputFormat: outputFormat, converter: converter)
        }

        do {
            try engine.start()
            print("[AudioRecorder] Engine started, input rate: \(inputFormat.sampleRate)Hz")
        } catch {
            print("[AudioRecorder] Engine start failed: \(error)")
        }
    }

    // MARK: - 直接采集（格式已匹配）

    private func installDirectTap(inputNode: AVAudioInputNode, format: AVAudioFormat) {
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self = self, let channelData = buffer.int16ChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let data = Data(bytes: channelData.pointee, count: frameLength * 2)
            self.bufferQueue.async {
                self.audioBuffer.append(data)
            }
            self.calculateVolume(from: buffer)
        }
    }

    // MARK: - 带格式转换的采集

    private func installConvertingTap(
        inputNode: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) {
        // 用 Float32 格式安装 tap（AVAudioEngine 原生格式），手动降采样
        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) ?? inputFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // 计算目标帧数
            let ratio = outputFormat.sampleRate / tapFormat.sampleRate
            let targetFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: targetFrames
            ) else { return }

            var inputPosition: Int = 0
            let inputLength = Int(buffer.frameLength)

            // 正确的 converter inputBlock：返回源 buffer 数据
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if inputPosition >= inputLength {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                let remaining = AVAudioFrameCount(inputLength - inputPosition)
                let result = AVAudioPCMBuffer(
                    pcmFormat: buffer.format,
                    frameCapacity: remaining
                )!
                result.frameLength = min(inNumPackets, remaining)

                // 拷贝 float32 数据
                if let srcData = buffer.floatChannelData?[0],
                   let dstData = result.floatChannelData?[0] {
                    memcpy(dstData, srcData.advanced(by: inputPosition),
                           Int(result.frameLength) * MemoryLayout<Float>.size)
                }
                inputPosition += Int(result.frameLength)
                return result
            }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

            if status == .error, let error = error {
                print("[AudioRecorder] Conversion error: \(error)")
                return
            }

            guard let channelData = convertedBuffer.int16ChannelData else { return }
            let frameLength = Int(convertedBuffer.frameLength)
            guard frameLength > 0 else { return }
            let data = Data(bytes: channelData.pointee, count: frameLength * 2)

            self.bufferQueue.async {
                self.audioBuffer.append(data)
            }
            self.calculateVolume(from: convertedBuffer)
        }
    }

    // MARK: - 停止录音

    func stopRecording(completion: @escaping (Data, Int, StopReason) -> Void) {
        stopProtectionTimers()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        DispatchQueue.main.async {
            self.volumeLevel = 0.0
            self.smoothedVolume = 0.0
        }

        bufferQueue.async { [weak self] in
            guard let self = self else { return }
            let data = self.audioBuffer
            let sr = 16000
            let reason: StopReason
            if let start = self.startTime, Date().timeIntervalSince(start) >= self.maxDuration {
                reason = .timeout
            } else if data.count >= self.maxFileSize {
                reason = .sizeLimitExceeded
            } else {
                reason = .userReleased
            }
            print("[AudioRecorder] Stopped, reason: \(reason), captured \(data.count) bytes (\(Double(data.count) / 2.0 / 16000.0)s)")
            DispatchQueue.global().async {
                completion(data, sr, reason)
            }
        }
    }

    // MARK: - Protection Timers

    private func startTimeoutTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: maxDuration,
            repeats: false
        ) { [weak self] _ in
            guard let self = self, self.engine.isRunning else { return }
            print("[AudioRecorder] Max duration (\(self.maxDuration)s) reached, auto-stopping")
            self.stopRecording { _, _, reason in
                print("[AudioRecorder] Auto-stopped due to: \(reason)")
            }
        }
    }

    private func startSizeCheckTimer() {
        sizeCheckTimer?.invalidate()
        sizeCheckTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            guard let self = self, self.engine.isRunning else { return }
            let size = self.currentFileSize
            if size >= self.maxFileSize {
                print("[AudioRecorder] File size limit (\(self.maxFileSize / 1024 / 1024)MB) exceeded (\(size / 1024 / 1024)MB), auto-stopping")
                self.stopRecording { _, _, reason in
                    print("[AudioRecorder] Auto-stopped due to: \(reason)")
                }
            }
        }
    }

    private func stopProtectionTimers() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        sizeCheckTimer?.invalidate()
        sizeCheckTimer = nil
    }

    var isRecording: Bool {
        engine.isRunning
    }

    @Published var volumeLevel: Double = 0.0
    private var smoothedVolume: Double = 0.0
    private let smoothingFactor: Double = 0.3

    private func calculateVolume(from buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0
        for i in 0..<frameLength {
            sum += floatData[i] * floatData[i]
        }
        let rms = sqrt(sum / Float(frameLength))
        let normalizedVolume = min(Double(rms) * 5.0, 1.0)

        smoothedVolume = smoothingFactor * normalizedVolume + (1 - smoothingFactor) * smoothedVolume
        DispatchQueue.main.async {
            self.volumeLevel = self.smoothedVolume
        }
    }

    // MARK: - Helpers

    private func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        return a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
    }
}
