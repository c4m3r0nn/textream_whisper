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

    /// Called on main thread with transcribed text from the server
    var onTranscription: ((String) -> Void)?
    /// Called on main thread when connection state changes
    var onConnectionChange: ((Bool) -> Void)?
    /// Called on main thread when speech is detected
    var onSpeechStarted: (() -> Void)?
    /// Called on main thread when speech ends
    var onSpeechStopped: (() -> Void)?

    // MARK: - Connection

    func connect(apiKey: String, model: String = "gpt-4o-transcribe", language: String = "") async throws {
        disconnect()

        guard !apiKey.isEmpty else {
            throw WhisperError.missingAPIKey
        }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [
            URLQueryItem(name: "intent", value: "transcription"),
        ]

        guard let url = components.url else {
            throw WhisperError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let session = URLSession(configuration: .default)
        self.session = session
        let wsTask = session.webSocketTask(with: request)
        self.webSocketTask = wsTask
        wsTask.resume()

        // Wait for session.created event
        let firstMessage = try await wsTask.receive()
        if case .string(let text) = firstMessage {
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "transcription_session.created" else {
                throw WhisperError.unexpectedResponse(text)
            }
            if let session = json["session"] as? [String: Any] {
                self.sessionID = session["id"] as? String ?? ""
            }
        }

        // Configure the session
        let configMsg: [String: Any] = [
            "type": "transcription_session.update",
            "input_audio_format": "pcm16",
            "input_audio_transcription": [
                "model": model,
                "language": language,
            ],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500,
            ],
        ]
        let configData = try JSONSerialization.data(withJSONObject: configMsg)
        try await wsTask.send(.string(String(data: configData, encoding: .utf8)!))

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = true
            self?.onConnectionChange?(true)
        }

        // Start receiving messages
        receiveMessages()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.onConnectionChange?(false)
        }
    }

    // MARK: - Audio Streaming

    /// Send a PCM audio buffer to the server. Audio must be 16-bit PCM at 24kHz mono.
    func sendAudio(_ buffer: AVAudioPCMBuffer) {
        guard let webSocketTask, isConnected else { return }

        let pcmData = pcmBufferToInt16Data(buffer)
        let base64Audio = pcmData.base64EncodedString()

        let msg: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: msg),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        webSocketTask.send(.string(jsonString)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.error = "WebSocket send error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Commit the audio buffer, signaling end of speech segment
    func commitAudio() {
        guard let webSocketTask, isConnected else { return }

        let msg: [String: Any] = ["type": "input_audio_buffer.commit"]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }

        webSocketTask.send(.string(str)) { _ in }
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
                    DispatchQueue.main.async { [weak self] in
                        self?.lastTranscript = transcript
                        self?.onTranscription?(transcript)
                    }
                }

            case "conversation.item.input_audio_transcription.failed":
                if let errorDetail = json["error"] as? [String: Any],
                   let message = errorDetail["message"] as? String {
                    DispatchQueue.main.async { [weak self] in
                        self?.error = "Transcription error: \(message)"
                    }
                }

            case "input_audio_buffer.speech_started":
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechStarted?()
                }

            case "input_audio_buffer.speech_stopped":
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechStopped?()
                }

            case "error":
                if let errorDetail = json["error"] as? [String: Any],
                   let message = errorDetail["message"] as? String {
                    DispatchQueue.main.async { [weak self] in
                        self?.error = "API error: \(message)"
                        self?.isConnected = false
                        self?.onConnectionChange?(false)
                    }
                }

            default:
                break
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
