import Foundation

/// Bounded exponential backoff with full jitter.
///
/// Used by both the SSE stream and the terminal WebSocket. Full jitter (rather than
/// "base ± 10 %") is deliberate: several sessions reconnect at once after a tunnel flap, and
/// correlated retries are what turn one blip into a thundering herd against a server whose
/// per-session socket cap is five.
struct Backoff: Sendable {
    let initial: Duration
    let maximum: Duration
    let multiplier: Double

    private(set) var attempt: Int = 0

    init(initial: Duration = .milliseconds(500),
         maximum: Duration = .seconds(30),
         multiplier: Double = 2.0) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
    }

    mutating func reset() { attempt = 0 }

    /// Returns the next delay and advances the attempt counter.
    mutating func next(randomness: @Sendable (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> Duration {
        let exponent = pow(multiplier, Double(attempt))
        attempt += 1

        let initialSeconds = initial.seconds
        let maximumSeconds = maximum.seconds
        let ceiling = min(maximumSeconds, initialSeconds * exponent)
        // Full jitter: uniform in [0, ceiling]. Floored at the initial delay so a retry storm
        // cannot collapse into an effectively immediate loop.
        let jittered = max(initialSeconds, randomness(0...ceiling))
        return .seconds(jittered)
    }
}

extension Duration {
    var seconds: Double {
        let (secs, attos) = components
        return Double(secs) + Double(attos) / 1e18
    }
}
