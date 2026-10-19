import Foundation

struct PowerSample: Equatable {
    let percent: Int?
    let externalPower: Bool
}

enum PowerFeedback: Equatable { case connected(Int), targetReached(Int) }

struct PowerFeedbackTracker {
    private var previous: PowerSample?
    private var goal: Int?
    private var announced = false
    mutating func receive(_ sample: PowerSample, target: Int) -> PowerFeedback? {
        guard let percent = sample.percent, (0...100).contains(percent) else { return nil }
        defer { previous = sample; goal = target }
        guard let previous, goal == target else {
            announced = sample.externalPower && percent >= target
            return nil // Starting the app or changing the target isn't a battery event.
        }
        if !sample.externalPower { announced = false; return nil }
        if !previous.externalPower {
            announced = percent >= target
            return .connected(percent)
        }
        if percent >= target && !announced { announced = true; return .targetReached(target) }
        return nil
    }
}
