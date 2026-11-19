//
//  HistoryLockTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Подставное подтверждение личности: отвечает по очереди заданными ошибками, считает вызовы.
final class TestPresence: PresenceAuthorizing {
    /// Ответы по порядку: `nil` — подтверждено. Когда очередь пуста — подтверждено.
    var outcomes: [Error?] = []
    /// Задержка перед ответом: для проверки слияния одновременных разлочек.
    var delay: UInt64 = 0
    private(set) var calls = 0
    private(set) var reasons: [String] = []

    func authorize(reason: String) async throws {
        calls += 1
        reasons.append(reason)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if !outcomes.isEmpty, let error = outcomes.removeFirst() { throw error }
    }
}

/// Подставные часы.
final class TestClock {
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

private struct OddError: Error {}

/// Правила замка: разлочка, отказ, потеря ключа, повторное запирание по сну и по времени.
@MainActor
struct HistoryLockTests {
    private final class ResetCounter { var count = 0 }

    private func makeLock(enabled: Bool = true,
                          key: TestHistoryKey = TestHistoryKey(),
                          presence: TestPresence = TestPresence(),
                          clock: TestClock = TestClock(),
                          resets: ResetCounter? = nil) -> HistoryLock {
        let lock = HistoryLock(enabled: enabled, key: key, presence: presence, now: { clock.date })
        let counter = resets ?? ResetCounter()
        lock.resetSession = { counter.count += 1 }
        return lock
    }

    @Test func startsLockedWhenEnabled() {
        #expect(makeLock().state == .locked)
    }

    @Test func offWhenDisabledAndUnlockDoesNothing() async {
        let presence = TestPresence()
        let lock = makeLock(enabled: false, presence: presence)
        #expect(lock.state == .off)
        await lock.unlock()
        #expect(lock.state == .off)
        #expect(presence.calls == 0)
    }

    @Test func unlockSucceedsWithPresence() async {
        let key = TestHistoryKey()
        let presence = TestPresence()
        let lock = makeLock(key: key, presence: presence)
        await lock.unlock()
        #expect(lock.state == .unlocked)
        #expect(presence.calls == 1)
        #expect(presence.reasons == [HistoryAuthSession.defaultReason])
        #expect(key.agreeCount == 1)
    }

    @Test func deniedPresenceKeepsLocked() async {
        let key = TestHistoryKey()
        let presence = TestPresence()
        presence.outcomes = [HistoryKeyError.denied]
        let lock = makeLock(key: key, presence: presence)
        await lock.unlock()
        #expect(lock.state == .locked)
        #expect(key.agreeCount == 0)
    }

    @Test func threeDenialsStillLockedNotUnavailable() async {
        let presence = TestPresence()
        presence.outcomes = [HistoryKeyError.denied, HistoryKeyError.denied, HistoryKeyError.denied]
        let lock = makeLock(presence: presence)
        for _ in 0..<3 {
            await lock.unlock()
            #expect(lock.state == .locked)
        }
        await lock.unlock()
        #expect(lock.state == .unlocked)
    }

    @Test func deniedKeyUseKeepsLocked() async {
        let key = TestHistoryKey()
        let lock = makeLock(key: key)
        key.failure = .denied
        await lock.unlock()
        #expect(lock.state == .locked)
    }

    @Test func missingKeyGivesKeyUnavailable() async {
        let lock = makeLock(key: TestHistoryKey(created: false))
        await lock.unlock()
        #expect(lock.state == .keyUnavailable)
    }

    @Test func unreadableKeyGivesKeyUnavailable() async {
        let key = TestHistoryKey()
        key.failure = .unavailable
        let lock = makeLock(key: key)
        await lock.unlock()
        #expect(lock.state == .keyUnavailable)
    }

    @Test func unknownErrorStaysLocked() async {
        let presence = TestPresence()
        presence.outcomes = [OddError()]
        let lock = makeLock(presence: presence)
        await lock.unlock()
        #expect(lock.state == .locked)
    }

    @Test func restoredKeyCanUnlockFromKeyUnavailable() async {
        let key = TestHistoryKey(created: false)
        let presence = TestPresence()
        let lock = makeLock(key: key, presence: presence)
        await lock.unlock()
        #expect(lock.state == .keyUnavailable)
        await lock.unlock()
        #expect(presence.calls == 0)
        #expect(lock.state == .keyUnavailable)
        try? key.create()
        await lock.unlock()
        #expect(lock.state == .unlocked)
    }

    @Test func concurrentUnlocksShareOneAttempt() async {
        let key = TestHistoryKey()
        let presence = TestPresence()
        presence.delay = 50_000_000
        let lock = makeLock(key: key, presence: presence)
        async let first: Void = lock.unlock()
        async let second: Void = lock.unlock()
        _ = await (first, second)
        #expect(presence.calls == 1)
        #expect(key.agreeCount == 1)
        #expect(lock.state == .unlocked)
    }

    @Test func unlockWhenUnlockedDoesNothing() async {
        let presence = TestPresence()
        let lock = makeLock(presence: presence)
        await lock.unlock()
        await lock.unlock()
        #expect(presence.calls == 1)
        #expect(lock.state == .unlocked)
    }

    @Test func sleepLocksImmediately() async {
        let lock = makeLock()
        lock.noteWindowVisibility(true)
        await lock.unlock()
        lock.noteSystemDidWake()
        #expect(lock.state == .locked)

        await lock.unlock()
        lock.noteSystemWillSleep()
        #expect(lock.state == .locked)
    }

    @Test func lockingResetsAuthSession() async {
        let resets = ResetCounter()
        let lock = makeLock(resets: resets)
        await lock.unlock()
        #expect(resets.count == 0)
        lock.noteSystemWillSleep()
        #expect(resets.count == 1)
    }

    @Test func sleepDuringUnlockAttemptKeepsLocked() async {
        let presence = TestPresence()
        presence.delay = 50_000_000
        let lock = makeLock(presence: presence)
        async let attempt: Void = lock.unlock()
        await Task.yield()
        lock.noteSystemWillSleep()
        await attempt
        #expect(lock.state == .locked)
    }

    @Test func fifteenMinutesHiddenLocks() async {
        let clock = TestClock()
        let lock = makeLock(clock: clock)
        lock.noteWindowVisibility(true)
        await lock.unlock()
        lock.noteWindowVisibility(false)
        clock.advance(HistoryLock.idleTimeout)
        lock.tick()
        #expect(lock.state == .locked)
    }

    @Test func tickBeforeFifteenMinutesKeepsUnlocked() async {
        let clock = TestClock()
        let lock = makeLock(clock: clock)
        lock.noteWindowVisibility(false)
        await lock.unlock()
        clock.advance(HistoryLock.idleTimeout - 1)
        lock.tick()
        #expect(lock.state == .unlocked)
    }

    @Test func visibleWindowNeverLocks() async {
        let clock = TestClock()
        let lock = makeLock(clock: clock)
        lock.noteWindowVisibility(true)
        await lock.unlock()
        clock.advance(HistoryLock.idleTimeout * 10)
        lock.tick()
        #expect(lock.state == .unlocked)
    }

    @Test func windowReappearingRestartsIdleClock() async {
        let clock = TestClock()
        let lock = makeLock(clock: clock)
        lock.noteWindowVisibility(true)
        await lock.unlock()
        lock.noteWindowVisibility(false)
        clock.advance(10 * 60)
        lock.noteWindowVisibility(true)
        clock.advance(60)
        lock.noteWindowVisibility(false)
        clock.advance(10 * 60)
        lock.tick()
        #expect(lock.state == .unlocked)
        clock.advance(5 * 60)
        lock.tick()
        #expect(lock.state == .locked)
    }

    @Test func idleClockStartsAtUnlock() async {
        let clock = TestClock()
        let lock = makeLock(clock: clock)
        lock.noteWindowVisibility(false)
        clock.advance(HistoryLock.idleTimeout * 2)
        await lock.unlock()
        lock.tick()
        #expect(lock.state == .unlocked)
    }

    @Test func repeatedUnlocksAllowedInOneRun() async {
        let presence = TestPresence()
        let clock = TestClock()
        let lock = makeLock(presence: presence, clock: clock)
        for _ in 0..<5 {
            await lock.unlock()
            #expect(lock.state == .unlocked)
            lock.noteSystemDidWake()
            #expect(lock.state == .locked)
        }
        #expect(presence.calls == 5)
    }

    // MARK: - Хранилище не прочитало конверты

    @Test func storeDowngradeToLockedFollows() async {
        let resets = ResetCounter()
        let lock = makeLock(resets: resets)
        await lock.unlock()
        lock.noteStoreDowngrade(to: .locked)
        #expect(lock.state == .locked)
        #expect(resets.count == 1)
    }

    @Test func storeDowngradeToKeyUnavailableFollows() async {
        let lock = makeLock()
        await lock.unlock()
        lock.noteStoreDowngrade(to: .keyUnavailable)
        #expect(lock.state == .keyUnavailable)
    }

    @Test func storeDowngradeIgnoredWhenNotUnlocked() async {
        let resets = ResetCounter()
        let lock = makeLock(resets: resets)
        lock.noteStoreDowngrade(to: .keyUnavailable)
        #expect(lock.state == .locked)
        let off = makeLock(enabled: false)
        off.noteStoreDowngrade(to: .locked)
        #expect(off.state == .off)
        #expect(resets.count == 0)
    }

    @Test func storeDowngradeIgnoresNonLockingStates() async {
        let lock = makeLock()
        await lock.unlock()
        lock.noteStoreDowngrade(to: .off)
        lock.noteStoreDowngrade(to: .unlocked)
        #expect(lock.state == .unlocked)
    }

    @Test func unlockAfterStoreDowngradeWorksAgain() async {
        let presence = TestPresence()
        let lock = makeLock(presence: presence)
        await lock.unlock()
        lock.noteStoreDowngrade(to: .locked)
        await lock.unlock()
        #expect(lock.state == .unlocked)
        #expect(presence.calls == 2)
    }
}
