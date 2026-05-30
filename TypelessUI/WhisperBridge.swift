import Foundation

/// 与 Python AI 服务通信（通过子进程 stdin/stdout JSON 协议）
final class WhisperBridge {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private let queue = DispatchQueue(label: "com.typeless.whisper")
    private var isReady = false
    private let lock = NSLock()

    // MARK: - 初始化

    func initialize(model: String = "base", completion: @escaping (Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }

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
            log("] server.py not found")
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
            log("] Python service started: \(pythonPath) \(serverPath)")
            sendInitCommand(model: model, completion: completion)
        } catch {
            log("] Failed to start Python service: \(error)")
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
                    self?.log("Model '\(model)' initialized successfully")
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

    // MARK: - 查找路径（优先从 UserDefaults 读取，兼容自动检测）

    private func findPythonPath() -> String {
        if let customPath = UserDefaults.standard.string(forKey: Constants.Keys.pythonPath),
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            if validatePython(path: customPath) { return customPath }
        }

        let projectDir = findProjectDir()
        let candidates: [String] = [
            "/usr/bin/python3",
            "\(projectDir)/.venv/bin/python3",
            "/usr/local/bin/python3",
            "/Users/carylab/.workbuddy/binaries/python/envs/typelesspp/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path), validatePython(path: path) {
                return path
            }
        }
        return "/usr/bin/python3"
    }

    private func validatePython(path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["-c", "import faster_whisper; print('OK')"]
        task.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                return output.contains("OK")
            }
        } catch {}
        return false
    }

    private func log(_ message: String) {
        let msg = "[WhisperBridge] \(message)"
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

    private func findServerPath() -> String {
        let projectDir = findProjectDir()
        let paths: [String] = [
            "\(projectDir)/TypelessAI/server.py",
            Bundle.main.path(forResource: "server", ofType: "py") ?? "",
        ]
        for path in paths {
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return ""
    }

    /// 通过 Bundle 或可执行文件路径推算项目目录
    private func findProjectDir() -> String {
        if let customDir = UserDefaults.standard.string(forKey: Constants.Keys.projectDir),
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

    // MARK: - 转录

    func transcribe(audioData: Data, sampleRate: Int, language: String = "auto", completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        let ready = isReady
        lock.unlock()

        guard ready else {
            initialize { [weak self] success in
                if success {
                    self?.transcribe(audioData: audioData, sampleRate: sampleRate, language: language, completion: completion)
                } else {
                    completion(.failure(WhisperError.notInitialized))
                }
            }
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let audioPath = tempDir.appendingPathComponent("typeless_\(UUID().uuidString).wav")
        writeWAV(audioData, to: audioPath, sampleRate: sampleRate)

        let command: [String: Any] = [
            "command": "transcribe",
            "audio_path": audioPath.path,
            "language": language,
            "post_process": true,
        ]

        sendCommand(command) { result in
            try? FileManager.default.removeItem(at: audioPath)

            switch result {
            case .success(let dict):
                if let text = dict["text"] as? String, !text.isEmpty {
                    completion(.success(text))
                } else {
                    completion(.failure(WhisperError.serverError("Empty transcription result")))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - IPC 通信

    private func sendCommand(_ command: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let stdinPipe = stdinPipe, let stdoutPipe = stdoutPipe else {
            completion(.failure(WhisperError.processNotRunning))
            return
        }

        guard let proc = process, proc.isRunning else {
            completion(.failure(WhisperError.processNotRunning))
            return
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: command),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            completion(.failure(WhisperError.invalidCommand))
            return
        }

        let line = jsonString + "\n"

        queue.async { [weak self] in
            guard self != nil else { return }

            stdinPipe.fileHandleForWriting.write(line.data(using: .utf8)!)

            let timeout: TimeInterval = 30
            let startTime = Date()

            func readResponse() {
                let data = stdoutPipe.fileHandleForReading.availableData
                guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty else {
                    if Date().timeIntervalSince(startTime) > timeout {
                        completion(.failure(WhisperError.serverError("Request timed out after \(Int(timeout))s")))
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                    readResponse()
                    return
                }

                guard let responseData = line.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    completion(.failure(WhisperError.invalidResponse))
                    return
                }

                if let status = dict["status"] as? String, status == "error",
                   let message = dict["message"] as? String {
                    completion(.failure(WhisperError.serverError(message)))
                } else {
                    completion(.success(dict))
                }
            }

            readResponse()
        }
    }

    // MARK: - WAV 写入

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
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        lock.lock()
        isReady = false
        lock.unlock()
    }

    private func cleanup() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
    }
}

// MARK: - 错误类型

enum WhisperError: LocalizedError {
    case notInitialized
    case processNotRunning
    case invalidCommand
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "语音识别服务未初始化"
        case .processNotRunning: return "服务进程未运行"
        case .invalidCommand: return "命令格式无效"
        case .invalidResponse: return "服务响应无效"
        case .serverError(let msg): return "服务错误: \(msg)"
        }
    }
}