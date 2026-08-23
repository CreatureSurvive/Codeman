import Foundation

/// Buffers terminal output while an authoritative snapshot is in flight, then hands it back in
/// arrival order.
///
/// This is the mechanism that stops a reconnect from eating the last seconds of output. The
/// sequence is:
///
/// 1. `beginSnapshot()` — the pane asks for `GET …/terminal?full=1`.
/// 2. Frames that arrive from here on are **newer than the snapshot** and are held, in order.
/// 3. `release()` — the snapshot has been written to a cleared grid; the held frames are replayed
///    on top of it.
///
/// Dropping step 2 is the classic "reconnect wipes the last two seconds" bug; replaying the held
/// frames *before* the snapshot would be equally wrong, since the snapshot is the older state.
///
/// Pure and synchronous by design: the ordering guarantee is the whole point, so it is asserted
/// directly in `SnapshotGateTests` rather than inferred from a pane's state enum.
struct SnapshotGate: Sendable {
    /// Ceiling on held bytes. A snapshot that never returns must not grow this without bound on a
    /// 24-hour session; past the cap the gate gives up holding and says so.
    static let defaultCapacity = 2 * 1024 * 1024

    private let capacity: Int
    private(set) var isAwaitingSnapshot = false
    private var held: [Data] = []
    private var heldBytes = 0

    init(capacity: Int = SnapshotGate.defaultCapacity) {
        self.capacity = capacity
    }

    /// What the pane should do with a chunk of output.
    enum Decision: Equatable {
        /// Write it straight through.
        case passThrough
        /// It was buffered; nothing to write yet.
        case held
        /// The hold overflowed. The caller must replay `flushed` (which includes this chunk, last)
        /// and stop waiting for the snapshot — it is clearly not arriving usefully.
        case overflowed(flushed: [Data])
    }

    mutating func beginSnapshot() {
        isAwaitingSnapshot = true
    }

    mutating func ingest(_ data: Data) -> Decision {
        guard isAwaitingSnapshot else { return .passThrough }

        guard heldBytes + data.count <= capacity else {
            var flushed = held
            flushed.append(data)
            held.removeAll(keepingCapacity: false)
            heldBytes = 0
            isAwaitingSnapshot = false
            return .overflowed(flushed: flushed)
        }

        held.append(data)
        heldBytes += data.count
        return .held
    }

    /// Ends the hold and returns everything buffered, in arrival order.
    mutating func release() -> [Data] {
        isAwaitingSnapshot = false
        let pending = held
        held.removeAll(keepingCapacity: false)
        heldBytes = 0
        return pending
    }

    var heldByteCount: Int { heldBytes }
}
