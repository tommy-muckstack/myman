import XCTest
@testable import MyMan

final class BackgroundMaintenanceTests: XCTestCase {
    func testOnlyOptionalWorkDefersWhenPowerHeatOrLoadRequiresIt() {
        XCTAssertFalse(BackgroundMaintenance.shouldDefer(load: 4, cores: 8, thermal: .nominal, lowPower: false))
        XCTAssertFalse(BackgroundMaintenance.shouldDefer(load: 10, cores: 8, thermal: .fair, lowPower: false))
        XCTAssertTrue(BackgroundMaintenance.shouldDefer(load: 20, cores: 8, thermal: .nominal, lowPower: false))
        XCTAssertTrue(BackgroundMaintenance.shouldDefer(load: 0, cores: 8, thermal: .serious, lowPower: false))
        XCTAssertTrue(BackgroundMaintenance.shouldDefer(load: 0, cores: 8, thermal: .critical, lowPower: false))
        XCTAssertTrue(BackgroundMaintenance.shouldDefer(load: 0, cores: 8, thermal: .nominal, lowPower: true))
    }

    func testBurstDuringRunningWorkProducesOnlyOneFollowUp() {
        let entered = expectation(description: "first pass")
        let followUp = expectation(description: "follow up")
        let extra = expectation(description: "no extra pass")
        extra.isInverted = true
        let release = DispatchSemaphore(value: 0)
        var count = 0 // Accessed only on the worker's serial queue.
        let worker = CoalescingMaintenance(label: "test.coalesce", delay: 0.01, shouldDefer: { false }) { _ in
            count += 1
            if count == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 3)
            } else if count == 2 { followUp.fulfill() }
            else { extra.fulfill() }
        }
        worker.request()
        wait(for: [entered], timeout: 2)
        for _ in 0..<100 { worker.request() }
        release.signal()
        wait(for: [followUp], timeout: 2)
        wait(for: [extra], timeout: 0.15)
        withExtendedLifetime(worker) {}
    }

    func testDeferredRequestsSurviveUntilPressureClears() {
        let checked = expectation(description: "pressure checked")
        let finished = expectation(description: "work resumes")
        let lock = NSLock()
        var busy = true
        var checks = 0
        let worker = CoalescingMaintenance(label: "test.defer", delay: 0.01, retryDelay: 0.05, shouldDefer: {
            lock.lock(); defer { lock.unlock() }
            checks += 1
            if checks == 1 { checked.fulfill() }
            return busy
        }) { _ in finished.fulfill() }
        worker.request()
        wait(for: [checked], timeout: 2)
        for _ in 0..<100 { worker.request() }
        lock.lock(); busy = false; lock.unlock()
        wait(for: [finished], timeout: 2)
        withExtendedLifetime(worker) {}
    }
}
