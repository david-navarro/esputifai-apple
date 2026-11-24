import AVFoundation
import Observation
import Speech

/// "Buscar por voz": listens with the microphone and turns speech into text with Apple's speech
/// recognizer, in the phone's first language.
///
/// Android hands this to the system's dictation dialog; iOS has none, so the app listens itself:
/// the text shows in the search box as it is heard, and listening ends after a short silence or
/// when the microphone is tapped again. Music that was playing pauses meanwhile (otherwise the
/// microphone hears it) and goes on afterwards. iOS asks for the microphone and speech recognition
/// the first time (texts in project.yml).
@MainActor
@Observable
final class VoiceSearch {
    private(set) var listening = false
    /// Why it couldn't listen (permission denied, no recognizer for the language…); for an alert.
    var problem: String?

    /// Silence that ends listening once something was heard; and how long to wait for a first word.
    private static let pause: Duration = .milliseconds(1500)
    private static let firstWord: Duration = .seconds(6)

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var heard = ""
    @ObservationIgnored private var onText: ((String) -> Void)?
    @ObservationIgnored private var onDone: ((String) -> Void)?
    @ObservationIgnored private var musicWasPlaying = false
    @ObservationIgnored private weak var player: Player?

    /// Starts listening, or stops if it already is. `onText` gets the text as it is heard;
    /// `onDone` the final text, only if something was heard.
    func toggle(player: Player, onText: @escaping (String) -> Void, onDone: @escaping (String) -> Void) {
        if listening { return stop() }
        Task {
            guard await Self.speechAllowed() else {
                problem = "Permite el reconocimiento de voz a Esputifai en Ajustes > Privacidad y seguridad."
                return
            }
            guard await AVAudioApplication.requestRecordPermission() else {
                problem = "Permite el micrófono a Esputifai en Ajustes > Privacidad y seguridad."
                return
            }
            start(player: player, onText: onText, onDone: onDone)
        }
    }

    /// Ends listening without searching (leaving the screen).
    func cancel() {
        heard = ""
        finish()
    }

    // MARK: Listening

    private func start(player: Player, onText: @escaping (String) -> Void, onDone: @escaping (String) -> Void) {
        guard !listening else { return }
        // The phone's language, not Locale.current: the app has no localizations, so iOS would
        // report its development language (English) there.
        let language = Locale(identifier: Locale.preferredLanguages.first ?? "es-ES")
        guard let recognizer = SFSpeechRecognizer(locale: language) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            problem = "El reconocimiento de voz no está disponible ahora. Comprueba que hay internet."
            return
        }

        self.player = player
        musicWasPlaying = player.isPlaying
        if musicWasPlaying { player.togglePlayPause() }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .search
        request.addsPunctuation = false // "Arctic Monkeys", not "Arctic Monkeys."
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.feed(request))
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            restoreAudio()
            if musicWasPlaying { player.togglePlayPause() }
            musicWasPlaying = false
            problem = "No se ha podido usar el micrófono (\(error.localizedDescription))."
            return
        }

        self.request = request
        self.onText = onText
        self.onDone = onDone
        heard = ""
        listening = true
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, ended in
            self?.received(text, ended: ended)
        })
        wait(Self.firstWord)
    }

    private func received(_ text: String?, ended: Bool) {
        guard listening else { return }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != heard {
            heard = text
            onText?(text)
            wait(Self.pause)
        }
        if ended { finish() }
    }

    /// Stops the microphone; the recognizer then sends its final text, which ends listening.
    private func stop() {
        guard listening else { return }
        if heard.isEmpty { return finish() }
        request?.endAudio()
        request = nil
        wait(.seconds(2)) // in case the final text never comes
    }

    /// After `delay` without new words: stop if something was heard, give up otherwise.
    private func wait(_ delay: Duration) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.listening else { return }
            if self.heard.isEmpty || self.request == nil { self.finish() } else {
                self.request?.endAudio()
                self.request = nil
                self.wait(.seconds(2))
            }
        }
    }

    private func finish() {
        guard listening else { return }
        listening = false
        timer?.cancel()
        timer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        restoreAudio()
        if musicWasPlaying { player?.togglePlayPause() }
        musicWasPlaying = false
        let text = heard
        let done = onDone
        onText = nil
        onDone = nil
        if !text.isEmpty { done?(text) }
    }

    /// Back to the player's audio setup (Player.init); it turns the session on again when it plays.
    private func restoreAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        if !musicWasPlaying { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
    }

    // MARK: Callbacks off the main thread
    // Built outside the main actor: the audio tap and the recognizer call them on their own threads.

    private nonisolated static func feed(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func results(
        _ sink: @escaping @MainActor (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let ended = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in sink(text, ended) }
        }
    }

    private nonisolated static func speechAllowed() async -> Bool {
        await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
    }
}
