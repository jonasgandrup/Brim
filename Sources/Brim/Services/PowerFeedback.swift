import Foundation

struct PowerSample: Equatable {
    let percent: Int?
    let externalPower: Bool
}

enum PowerFeedback: Equatable { case connected(Int), targetReached(Int), low(Int) }

struct PowerFeedbackTracker {
    private var previous: PowerSample?
    private var goal: Int?
    private var announced = false
    private var warnedLow = false
    /// `low` of 0 turns the low-battery warning off.
    mutating func receive(_ sample: PowerSample, target: Int, low: Int = 0) -> PowerFeedback? {
        guard let percent = sample.percent, (0...100).contains(percent) else { return nil }
        defer { previous = sample; goal = target }
        guard let previous, goal == target else {
            announced = sample.externalPower && percent >= target
            // Launching already below the threshold isn't news; warn on the next crossing.
            warnedLow = !sample.externalPower && low > 0 && percent <= low
            return nil // Starting the app or changing the target isn't a battery event.
        }
        if !sample.externalPower {
            announced = false
            // Warn once per discharge; a few percent of headroom keeps a reading that hovers from repeating it.
            if low > 0, percent <= low, !warnedLow { warnedLow = true; return .low(percent) }
            if low == 0 || percent > low + 3 { warnedLow = false }
            return nil
        }
        warnedLow = false
        if !previous.externalPower {
            announced = percent >= target
            return .connected(percent)
        }
        if percent >= target && !announced { announced = true; return .targetReached(target) }
        return nil
    }
}
