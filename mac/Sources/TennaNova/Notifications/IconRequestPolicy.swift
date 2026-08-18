import Foundation

/// Decides whether to ask the phone for a PNG again.
///
/// Needed because a request can go unanswered forever with no way to tell. The phone keeps
/// its icons and avatars in one access-ordered cache of 128 entries, and an `icon.request`
/// for a hash that has been evicted returns *nothing at all* — not an error, not an empty
/// reply. Without a bound, every notification carrying that hash would ask again.
///
/// Contact photos make this concrete: there is one per sender, so a busy phone evicts them
/// steadily, and the Mac only started asking for them when the window began showing them.
struct IconRequestPolicy {

    static let maxAttempts = 3
    static let backoff: TimeInterval = 30
    /// Ceiling on the bookkeeping itself, so a long session cannot grow it without limit.
    static let maxTracked = 512

    private var attempts: [String: Int] = [:]
    private var lastAttempt: [String: Date] = [:]
    private var knownMissing: Set<String> = []

    mutating func shouldRequest(_ hash: String, at now: Date = Date()) -> Bool {
        if knownMissing.contains(hash) { return false }

        let count = attempts[hash] ?? 0
        if count >= Self.maxAttempts {
            // Give up for this session rather than retrying a hash the phone no longer has.
            knownMissing.insert(hash)
            attempts[hash] = nil
            lastAttempt[hash] = nil
            return false
        }
        if let last = lastAttempt[hash], now.timeIntervalSince(last) < Self.backoff {
            return false
        }

        attempts[hash] = count + 1
        lastAttempt[hash] = now
        evictIfNeeded()
        return true
    }

    /// The bytes arrived, so the hash starts fresh if it is ever needed again.
    mutating func received(_ hash: String) {
        attempts[hash] = nil
        lastAttempt[hash] = nil
        knownMissing.remove(hash)
    }

    /// A new session may be a different phone, or the same one with a refilled cache.
    mutating func reset() {
        attempts.removeAll()
        lastAttempt.removeAll()
        knownMissing.removeAll()
    }

    private mutating func evictIfNeeded() {
        guard attempts.count > Self.maxTracked else { return }
        let doomed = lastAttempt.sorted { $0.value < $1.value }
            .prefix(attempts.count - Self.maxTracked)
        for (hash, _) in doomed {
            attempts[hash] = nil
            lastAttempt[hash] = nil
        }
    }
}
