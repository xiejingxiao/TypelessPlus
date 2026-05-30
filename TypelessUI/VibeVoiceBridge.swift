import Foundation

final class VibeVoiceBridge {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private let queue = DispatchQueue(label: "com.typeless.vibevoice")
    private var isReady = false
    private let lock = NSLock()

    private var watchdogTimer: Timer?
    private var restartCount: Int = 0
    private let maxRestartAttempts: Int = 3
    private var lastModel: String = "vibevoice-asr-q4_k.gguf"
    private static let backoffDelays: [UInt64] = [2_000_000_000, 4_000_000_000, 8_000_000_000]

    private var engineInfo: String = ""

    func initialize(model: String = "vibevoice-asr-q4_k.gguf", completion: @escaping (Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        lastModel = model

        if isReady {
            completion(true)
            return
        }

        if let p = process, p.isRunning {
            log("] Process already running, sending init...")
            sendInitCommand(model: model, completion: completion)
            return
        }

        let proc = Process()
        let serverPath = findServerPath()
        let pythonPath = findPythonPath()

        guard !serverPath.isEmpty else {
            log("] vibevoice_server.py not found")
            completion(false)
            return
        }

        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [serverPath]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_ENDPOINT"] = "https://hf-mirror.com"
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe

        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                self?.log(":Python] \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe

        do {
            try proc.run()
            log("] VibeVoice service started: \(pythonPath) \(serverPath)")
            sendInitCommand(model: model, completion: completion)
        } catch {
            log("] Failed to start VibeVoice service: \(error)")
            cleanup()
            completion(false)
        }
    }

    private func sendInitCommand(model: String, completion: @escaping (Bool) -> Void) {
        sendCommand(["command": "init", "model": model]) { [weak self] result in
            switch result {
            case .success(let dict):
                if dict["status"] as? String == "ok" {
                    self?.lock.lock()
                    self?.isReady = true
                    self?.lock.unlock()
                    self?.engineInfo = dict["engine"] as? String ?? "vibevoice"
                    self?.log("VibeVoice model '\(model)' initialized successfully")
                    self?.startWatchdog()
                    completion(true)
                } else {
                    let msg = dict["message"] as? String ?? "Unknown error"
                    self?.log("Init failed: \(msg)")
                    completion(false)
                }
            case .failure(let error):
                self?.log("Init command failed: \(error)")
                completion(false)
            }
        }
    }

    func startWatchdog() {
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self] _ in
            Task { await self?.checkProcessHealth() }
        }
        log("] Watchdog started (interval: 30s)")
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func checkProcessHealth() async {
        guard let proc = process else { return }

        if !proc.isRunning {
            log("] Watchdog: Process NOT running, attempting restart (attempt \(restartCount + 1)/\(maxRestartAttempts))")
            await attemptRestart()
            return
        }

        let isAlive = await sendPing()
        if !isAlive {
            log("] Watchdog: Process running but not responding, attempting restart (attempt \(restartCount + 1)/\(maxRestartAttempts))")
            await attemptRestart()
        }
    }

    private func sendPing() async -> Bool {
        return await withCheckedContinuation { continuation in
            sendCommand(["command": "ping"]) { result in
                switch result {
                case .success(let dict):
                    if dict["status"] as? String == "ok" {
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(returning: false)
                    }
                case .failure:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func attemptRestart() async {
        guard restartCount < maxRestartAttempts else {
            log("] Watchdog: Max restart attempts (\(maxRestartAttempts)) exceeded, giving up")
            stopWatchdog()
            lock.lock()
            isReady = false
            lock.unlock()
            return
        }

        let delay = VibeVoiceBridge.backoffDelays[min(restartCount, VibeVoiceBridge.backoffDelays.count - 1)]
        log("] Watchdog: Waiting \(delay / 1_000_000_000)s before restart...")

        try? await Task.sleep(nanoseconds: delay)

        cleanup()
        restartCount += 1

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            initialize(model: lastModel) { success in
                if success {
                    self.log("] Watchdog: Restart succeeded (attempt \(self.restartCount))")
                    self.restartCount = 0
                } else {
                    self.log("] Watchdog: Restart failed (attempt \(self.restartCount))")
                }
                continuation.resume()
            }
        }
    }

    private func findPythonPath() -> String {
        if let customPath = AppConfig.shared.pythonPath as String?,
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            return customPath
        }

        let projectDir = findProjectDir()
        let candidates: [String] = [
            "/usr/bin/python3",
            "\(projectDir)/.venv/bin/python3",
            "/usr/local/bin/python3",
            "/Users/carylab/.workbuddy/binaries/python/envs/typelesspp/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/bin/python3"
    }

    private func findServerPath() -> String {
        let projectDir = findProjectDir()
        let paths: [String] = [
            "\(projectDir)/TypelessAI/vibevoice_server.py",
            Bundle.main.path(forResource: "vibevoice_server", ofType: "py") ?? "",
        ]
        for path in paths {
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return ""
    }

    private func findProjectDir() -> String {
        if let customDir = AppConfig.shared.projectDir as String?,
           !customDir.isEmpty,
           FileManager.default.fileExists(atPath: customDir) {
            return customDir
        }

        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            return URL(fileURLWithPath: bundlePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
        }

        let execPath = Bundle.main.executablePath ?? ""
        if execPath.contains(".build") {
            var url = URL(fileURLWithPath: execPath)
            for _ in 0..<4 { url.deleteLastPathComponent() }
            return url.path
        }

        return ""
    }

    func transcribe(audioData: Data, sampleRate: Int, language: String = "auto",
                    hotwords: String = "",
                    completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        let ready = isReady
        lock.unlock()

        guard ready else {
            initialize { [weak self] success in
                if success {
                    self?.transcribe(audioData: audioData, sampleRate: sampleRate,
                                     language: language, hotwords: hotwords,
                                     completion: completion)
                } else {
                    completion(.failure(VibeVoiceError.notInitialized))
                }
            }
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let audioPath = tempDir.appendingPathComponent("typeless_vv_\(UUID().uuidString).wav")
        writeWAV(audioData, to: audioPath, sampleRate: sampleRate)

        var command: [String: Any] = [
            "command": "transcribe",
            "audio_path": audioPath.path,
            "language": language,
            "post_process": true,
        ]

        if !hotwords.isEmpty {
            command["hotwords"] = hotwords
        }

        sendCommand(command) { result in
            try? FileManager.default.removeItem(at: audioPath)

            switch result {
            case .success(let dict):
                if let text = dict["text"] as? String, !text.isEmpty {
                    completion(.success(text))
                } else {
                    completion(.failure(VibeVoiceError.serverError("Empty transcription result")))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func getEngineInfo() -> String {
        return engineInfo
    }

    private func sendCommand(_ command: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let stdinPipe = stdinPipe, let stdoutPipe = stdoutPipe else {
            completion(.failure(VibeVoiceError.processNotRunning))
            return
        }

        guard let proc = process, proc.isRunning else {
            completion(.failure(VibeVoiceError.processNotRunning))
            return
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: command),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            completion(.failure(VibeVoiceError.invalidCommand))
            return
        }

        let line = jsonString + "\n"

        queue.async { [weak self] in
            guard self != nil else { return }

            stdinPipe.fileHandleForWriting.write(line.data(using: .utf8)!)

            let timeout: TimeInterval = 120
            let startTime = Date()

            func readResponse() {
                let data = stdoutPipe.fileHandleForReading.availableData
                guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty else {
                    if Date().timeIntervalSince(startTime) > timeout {
                        completion(.failure(VibeVoiceError.serverError("Request timed out after \(Int(timeout))s")))
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                        readResponse()
                    }
                    return
                }

                guard let responseData = line.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    completion(.failure(VibeVoiceError.invalidResponse))
                    return
                }

                if let status = dict["status"] as? String, status == "error",
                   let message = dict["message"] as? String {
                    completion(.failure(VibeVoiceError.serverError(message)))
                } else {
                    completion(.success(dict))
                }
            }

            readResponse()
        }
    }

    private func writeWAV(_ data: Data, to url: URL, sampleRate: Int) {
        let header = createWAVHeader(dataSize: UInt32(data.count), sampleRate: UInt32(sampleRate))
        var fileData = Data(header)
        fileData.append(data)
        try? fileData.write(to: url)
    }

    private func createWAVHeader(dataSize: UInt32, sampleRate: UInt32) -> [UInt8] {
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let chunkSize: UInt32 = 36 + dataSize

        var header: [UInt8] = []
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }

    func shutdown() {
        stopWatchdog()
        restartCount = 0
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        lock.lock()
        isReady = false
        lock.unlock()
        log("] Shutdown complete, watchdog stopped")
    }

    private func cleanup() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
    }

    private func log(_ message: String) {
        let msg = "[VibeVoiceBridge] \(message)"
        print(msg)
        if let logPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("typeless_debug.log").path {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8), attributes: nil)
            }
        }
    }
}

enum VibeVoiceError: LocalizedError {
    case notInitialized
    case serviceNotRunning
    case permissionDenied
    case processNotRunning
    case invalidCommand
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "VibeVoice ASR 服务未初始化"
        case .serviceNotRunning: return "VibeVoice ASR 服务未启动"
        case .permissionDenied: return "缺少麦克风权限"
        case .processNotRunning: return "服务进程未运行"
        case .invalidCommand: return "命令格式无效"
        case .invalidResponse: return "服务响应无效"
        case .serverError(let msg): return "VibeVoice 服务错误: \(msg)"
        }
    }

    var friendlyMessage: String {
        switch self {
        case .notInitialized: return "语音识别引擎尚未就绪，请稍后再试"
        case .serviceNotRunning: return "VibeVoice ASR 服务未启动，请检查环境配置"
        case .permissionDenied: return "缺少麦克风权限，请在系统设置 → 隐私与安全中授权"
        case .processNotRunning: return "AI 服务进程异常退出，正在尝试重启..."
        case .invalidCommand: return "内部通信错误，请重启应用"
        case .invalidResponse: return "服务返回了无法解析的响应，请检查日志"
        case .serverError(let msg):
            if msg.contains("timeout") || msg.contains("timed out") {
                return "识别请求超时，音频可能过长，请缩短录音时长"
            } else if msg.contains("Model file not found") {
                return "模型文件未找到，请下载 vibevoice-asr-q4_k.gguf 到 models/ 目录"
            } else if msg.contains("crispasr") {
                return "crispasr 引擎未安装，请参考文档构建 CrispASR"
            } else if msg.contains("No speech") || msg.contains("empty") {
                return "未检测到有效语音，请靠近麦克风重试"
            }
            return "VibeVoice 识别服务报告错误: \(msg)"
        }
    }
}
