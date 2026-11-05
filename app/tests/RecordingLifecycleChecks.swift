@main
enum RecordingLifecycleChecks {
    static func main() {
        var checked = 0
        func expect(_ name: String, _ mode: RecordingMode, _ ready: Bool, _ expected: RecordingMode) {
            precondition(RecordingLifecycle.stateAfterCancellation(mode, workerReady: ready) == expected, name)
            checked += 1
        }
        expect("closing startup HUD preserves real startup", .loading, false, .loading)
        expect("loading state is not inferred from ready flag", .loading, true, .loading)
        expect("closing an error does not invent startup", .failed, false, .failed)
        expect("closing an error preserves failure", .failed, true, .failed)
        expect("cancel idle result with live worker", .ready, true, .ready)
        expect("idle but unavailable worker cannot record", .ready, false, .failed)
        expect("cancel recording with live worker", .recording, true, .ready)
        expect("cancel recording with unavailable worker", .recording, false, .failed)
        expect("cancel recognition with live worker", .processing, true, .ready)
        expect("cancel recognition with unavailable worker", .processing, false, .failed)
        print("Recording lifecycle: \(checked) checks passed")
    }
}
