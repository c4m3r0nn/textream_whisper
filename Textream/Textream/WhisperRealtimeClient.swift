//
//  WhisperRealtimeClient.swift
//  Textream
//
//  WebSocket client for OpenAI's Realtime transcription API.
//  Connects to wss://api.openai.com/v1/realtime?intent=transcription,
//  streams PCM16 audio at 24kHz mono, and receives transcribed text.
//

import Foundation
import AVFoundation

@Observable
class WhisperRealtimeClient {
    var isConnected: Bool = false
    var error: String?
    var lastTranscript: String = ""

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sessionID = ""
    private var sendCounter: Int = 0
    private var hasAudioSinceCommit: Bool = false
    private var currentDeltaBuffer: String = ""
    private var commitTimer: Timer?
    /// True when the session needs us to commit audio buffers manually
    /// (gpt-realtime-whisper has no server-side VAD).
    private var requiresManualCommit: Bool = false
    /// Seconds between manual commits. Short enough that finalised transcripts
    /// land while the reader is still speaking the next sentence.
    private let commitInterval: TimeInterval = 2.0
    private static let logPrefix = "[Whisper]"

    /// Called on main thread with the FINAL transcript for a speech segment
    /// (fires once per VAD-detected utterance after `speech_stopped`).
    var onTranscription: ((String) -> Void)?
    /// Called on main thread with the running partial transcript for the
    /// current speech segment. The string contains all delta tokens received
    /// since the last `onTranscription` fired (i.e. the in-progress sentence).
    var onPartialTranscription: ((String) -> Void)?
    /// Called on main thread when connection state changes
    var onConnectionChange: ((Bool) -> Void)?
    /// Called on main thread when speech is detected
    var onSpeechStarted: (() -> Void)?
    /// Called on main thread when speech ends
    var onSpeechStopped: (() -> Void)?

    // MARK: - Connection

    func connect(
        apiKey: String,
        transcriptionModel: String = "gpt-realtime-whisper",
        transcriptionDelay: String = "low",
        language: String = ""
    ) async throws {
        disconnect()

        guard !apiKey.isEmpty else {
            print("\(Self.logPrefix) connect failed: missing API key")
            throw WhisperError.missingAPIKey
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        // GA transcription-only sessions: `intent=transcription` selects the
        // transcription session type at connect time. No `model` query param
        // is needed (the transcription model is set via session.update below).
        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription"),
        ]

        guard let url = components.url else {
            print("\(Self.logPrefix) connect failed: invalid URL")
            throw WhisperError.invalidURL
        }

        print("\(Self.logPrefix) connecting intent=transcription transcriptionModel=\(transcriptionModel) language=\(language.isEmpty ? "auto" : language) keyPrefix=\(apiKey.prefix(7))…")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // GA Realtime API: do NOT send `OpenAI-Beta: realtime=v1` — the server
        // rejects it with `beta_api_shape_disabled`.

        let session = URLSession(configuration: .default)
        self.session = session
        let wsTask = session.webSocketTask(with: request)
        self.webSocketTask = wsTask
        wsTask.resume()
        sendCounter = 0

        // Wait for the first event. In GA this is `session.created`; we accept
        // any non-error event and surface the rest. An `error` first message
        // (e.g. auth failure) is thrown so the caller can show the reason.
        print("\(Self.logPrefix) waiting for session.created…")
        let firstMessage = try await wsTask.receive()
        if case .string(let text) = firstMessage {
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("\(Self.logPrefix) unexpected first message (not JSON): \(text.prefix(300))")
                throw WhisperError.unexpectedResponse(text)
            }
            let type = json["type"] as? String ?? ""
            if type == "error" {
                let message = (json["error"] as? [String: Any])?["message"] as? String ?? text
                print("\(Self.logPrefix) connect rejected: \(message)")
                throw WhisperError.unexpectedResponse(message)
            }
            if let session = json["session"] as? [String: Any] {
                self.sessionID = session["id"] as? String ?? ""
            }
            print("\(Self.logPrefix) first event: type=\(type) id=\(sessionID)")
        } else {
            print("\(Self.logPrefix) first message was non-string data")
        }

        // GA session.update for transcription-only sessions.
        // session.type = "transcription"; audio config nested under audio.input.
        // gpt-realtime-whisper streams deltas during speech and requires manual
        // commits (no turn_detection). The `delay` knob trades accuracy for
        // latency: minimal | low | medium | high | xhigh.
        let isStreamingWhisper = transcriptionModel == "gpt-realtime-whisper"
        var transcription: [String: Any] = ["model": transcriptionModel]
        if !language.isEmpty { transcription["language"] = language }
        if isStreamingWhisper && !transcriptionDelay.isEmpty {
            transcription["delay"] = transcriptionDelay
        }
        var inputConfig: [String: Any] = [
            "format": [
                "type": "audio/pcm",
                "rate": 24000,
            ],
            "transcription": transcription,
        ]
        if !isStreamingWhisper {
            inputConfig["turn_detection"] = [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500,
            ]
        }
        let configMsg: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": inputConfig,
                ],
            ],
        ]
        let configData = try JSONSerialization.data(withJSONObject: configMsg)
        try await wsTask.send(.string(String(data: configData, encoding: .utf8)!))
        print("\(Self.logPrefix) session.update sent (GA, model=\(transcriptionModel), \(isStreamingWhisper ? "streaming delay=\(transcriptionDelay), manual commit" : "server_vad"))")

        requiresManualCommit = isStreamingWhisper

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            self?.onConnectionChange?(true)
            if self?.requiresManualCommit == true {
                self?.startCommitTimer()
            }
        }

        // Start receiving messages
        receiveMessages()
    }

    private func startCommitTimer() {
        commitTimer?.invalidate()
        commitTimer = Timer.scheduledTimer(withTimeInterval: commitInterval, repeats: true) { [weak self] _ in
            self?.commitAudio()
        }
    }

    private func stopCommitTimer() {
        commitTimer?.invalidate()
        commitTimer = nil
    }

    func disconnect() {
        if webSocketTask != nil {
            print("\(Self.logPrefix) disconnect (sentChunks=\(sendCounter))")
        }
        DispatchQueue.main.async { [weak self] in self?.stopCommitTimer() }
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        hasAudioSinceCommit = false
        requiresManualCommit = false
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.onConnectionChange?(false)
        }
    }

    // MARK: - Audio Streaming

    /// Send a PCM audio buffer to the server. The server expects 16-bit PCM at 24kHz mono;
    /// `resampleTo24kHz` converts from the input sample rate.
    func sendAudio(_ buffer: AVAudioPCMBuffer) {
        guard let webSocketTask, isConnected else { return }

        let pcmData = Self.resampleTo24kHz(buffer)
        guard !pcmData.isEmpty else {
            if sendCounter == 0 {
                print("\(Self.logPrefix) sendAudio: resample produced empty data (srcRate=\(buffer.format.sampleRate) channels=\(buffer.format.channelCount) frames=\(buffer.frameLength))")
            }
            return
        }
        let base64Audio = pcmData.base64EncodedString()

        let msg: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: msg),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        sendCounter += 1
        hasAudioSinceCommit = true
        if sendCounter == 1 || sendCounter % 100 == 0 {
            print("\(Self.logPrefix) sent chunk #\(sendCounter) srcRate=\(Int(buffer.format.sampleRate)) ch=\(buffer.format.channelCount) frames=\(buffer.frameLength) → \(pcmData.count) bytes @24k")
        }

        webSocketTask.send(.string(jsonString)) { [weak self] error in
            if let error {
                print("\(Self.logPrefix) WebSocket send error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.error = "WebSocket send error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Commit the audio buffer, signaling end of speech segment.
    /// No-op if no audio has been appended since the last commit (the server
    /// rejects commits below 100ms of audio).
    func commitAudio() {
        guard let webSocketTask, isConnected, hasAudioSinceCommit else { return }
        hasAudioSinceCommit = false

        let msg: [String: Any] = ["type": "input_audio_buffer.commit"]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        webSocketTask.send(.string(str)) { error in
            if let error {
                print("\(Self.logPrefix) commit send error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Message Receiving

    private func receiveMessages() {
        guard let webSocketTask else { return }

        webSocketTask.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                if self.isConnected {
                    self.receiveMessages()
                }
            case .failure(let error):
                print("\(Self.logPrefix) WebSocket receive error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if self.isConnected {
                        self.error = "WebSocket receive error: \(error.localizedDescription)"
                        self.isConnected = false
                        self.onConnectionChange?(false)
                    }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let type = json["type"] as? String ?? ""

            switch type {
            case "conversation.item.input_audio_transcription.completed":
                if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                    print("\(Self.logPrefix) transcript: \(transcript)")
                    DispatchQueue.main.async { [weak self] in
                        self?.lastTranscript = transcript
                        self?.currentDeltaBuffer = ""
                        self?.onTranscription?(transcript)
                    }
                } else {
                    print("\(Self.logPrefix) transcript completed but empty")
                    DispatchQueue.main.async { [weak self] in
                        self?.currentDeltaBuffer = ""
                    }
                }

            case "conversation.item.input_audio_transcription.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.currentDeltaBuffer += delta
                        self.onPartialTranscription?(self.currentDeltaBuffer)
                    }
                }

            case "conversation.item.input_audio_transcription.failed":
                let message = (json["error"] as? [String: Any])?["message"] as? String ?? text
                print("\(Self.logPrefix) transcription failed: \(message)")
                DispatchQueue.main.async { [weak self] in
                    self?.error = "Transcription error: \(message)"
                }

            case "input_audio_buffer.speech_started":
                print("\(Self.logPrefix) speech_started")
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechStarted?()
                }

            case "input_audio_buffer.speech_stopped":
                print("\(Self.logPrefix) speech_stopped")
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechStopped?()
                }

            case "input_audio_buffer.committed":
                print("\(Self.logPrefix) input_audio_buffer.committed")

            case "session.created":
                print("\(Self.logPrefix) session.created (followup)")

            case "session.updated", "transcription_session.updated":
                print("\(Self.logPrefix) \(type) (config accepted)")

            case "error":
                let detail = (json["error"] as? [String: Any]) ?? [:]
                let message = detail["message"] as? String ?? text
                print("\(Self.logPrefix) API error: \(detail)")
                DispatchQueue.main.async { [weak self] in
                    self?.error = "API error: \(message)"
                    self?.isConnected = false
                    self?.onConnectionChange?(false)
                }

            default:
                print("\(Self.logPrefix) unhandled event type=\(type)")
            }

        case .data(let data):
            // Binary messages not expected for transcription
            break

        @unknown default:
            break
        }
    }

    // MARK: - Audio Conversion

    /// Convert AVAudioPCMBuffer (float32) to Int16 PCM Data
    static func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data {
        pcmBufferToInt16Data(buffer)
    }

    /// Resample audio to 24kHz mono PCM16
    static func resampleTo24kHz(_ buffer: AVAudioPCMBuffer) -> Data {
        let srcRate = buffer.format.sampleRate
        let srcChannels = Int(buffer.format.channelCount)
        let targetRate: Double = 24000.0
        let ratio = targetRate / srcRate

        guard let channelData = buffer.floatChannelData?[0] else { return Data() }
        let frameLength = Int(buffer.frameLength)

        let outputFrames = Int(Double(frameLength) * ratio)
        var pcmData = Data()
        pcmData.reserveCapacity(outputFrames * 2)

        for i in 0..<outputFrames {
            let srcIndex = Double(i) / ratio
            let srcFloor = Int(srcIndex)
            let frac = Float(srcIndex - Double(srcFloor))

            let sample: Float
            if srcFloor + 1 < frameLength {
                sample = channelData[srcFloor] * (1 - frac) + channelData[srcFloor + 1] * frac
            } else {
                sample = channelData[min(srcFloor, frameLength - 1)]
            }

            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0).littleEndian
            pcmData.append(Data(bytes: &int16, count: 2))
        }

        return pcmData
    }

    // MARK: - Errors

    enum WhisperError: LocalizedError {
        case missingAPIKey
        case invalidURL
        case unexpectedResponse(String)
        case notConnected

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "OpenAI API key is required"
            case .invalidURL: return "Invalid WebSocket URL"
            case .unexpectedResponse(let text): return "Unexpected response: \(text)"
            case .notConnected: return "Not connected to OpenAI"
            }
        }
    }
}

// MARK: - Private Helpers

private func pcmBufferToInt16Data(_ buffer: AVAudioPCMBuffer) -> Data {
    guard let channelData = buffer.floatChannelData?[0] else { return Data() }
    let frameLength = Int(buffer.frameLength)
    var data = Data()
    data.reserveCapacity(frameLength * 2)

    for i in 0..<frameLength {
        let clamped = max(-1.0, min(1.0, channelData[i]))
        var int16 = Int16(clamped * 32767.0).littleEndian
        data.append(Data(bytes: &int16, count: 2))
    }
    return data
}
