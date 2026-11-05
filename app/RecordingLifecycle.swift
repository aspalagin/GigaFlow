enum RecordingMode: Equatable {
    case loading, ready, recording, processing, failed
}

enum RecordingLifecycle {
    /// Closing an error or loading HUD must not invent a new worker startup.
    static func stateAfterCancellation(_ mode: RecordingMode, workerReady: Bool) -> RecordingMode {
        if mode == .loading || mode == .failed { return mode }
        return workerReady ? .ready : .failed
    }
}
