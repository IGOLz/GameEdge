import Foundation

@main
struct LatestFrameChecks {
    static func main() {
        let frames = LatestFrame<Int>()
        precondition(frames.offer(1))
        precondition(frames.take() == 1)
        for i in 2...10_000 { precondition(!frames.offer(i)) }
        precondition(frames.take() == 10_000, "A stalled renderer must resume with the latest frame")
        precondition(frames.takeReplacementCount() == 9_998)
        precondition(frames.takeReplacementCount() == 0)
        precondition(frames.take() == nil)
        precondition(frames.offer(10_001), "An idle worker must be woken")
        frames.stop()
        precondition(frames.take() == nil)
        precondition(!frames.offer(10_002), "Late callbacks after stop must be ignored")

        let drawableWait = LatestFrame<Int>()
        precondition(drawableWait.offer(1))
        precondition(drawableWait.take() == 1)
        precondition(!drawableWait.offer(2))
        precondition(drawableWait.newest(or: 1) == 2)
        precondition(drawableWait.newest(or: 2) == 2)
        precondition(!drawableWait.offer(3), "Refreshing a sample must not release the worker")
        drawableWait.stop()
        precondition(drawableWait.newest(or: 3) == nil)

        // Race producers with a consumer, including the transition from busy to idle.
        let concurrent = LatestFrame<Int>()
        let worker = DispatchQueue(label: "consumer")
        let done = DispatchGroup()
        for _ in 0..<8 {
            done.enter()
            DispatchQueue.global().async {
                for value in 0..<5_000 {
                    if concurrent.offer(value) {
                        worker.async { while concurrent.take() != nil {} }
                    }
                }
                done.leave()
            }
        }
        done.wait()
        worker.sync {}
        precondition(concurrent.offer(42), "The final wakeup must not be lost")
        precondition(concurrent.take() == 42)
        concurrent.stop()
        print("Latest-frame checks passed (backpressure, stop, 40,000 concurrent offers)")
    }
}
