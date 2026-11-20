//
//  HistoryLockedViewTests.swift
//  TranqTests
//

import Testing
@testable import Tranq

/// Какие кнопки показывает заглушка запертой истории.
struct HistoryLockedViewTests {
    @Test func lockedShowsUnlockOnly() {
        #expect(HistoryLockedView.actions(for: .locked, keyExists: true) == [.unlock])
    }

    @Test func keyUnavailableWithoutKeyShowsEraseOnly() {
        #expect(HistoryLockedView.actions(for: .keyUnavailable, keyExists: false) == [.erase])
    }

    /// Ключ на месте, но не прочитался: можно повторить разлочку или стереть.
    @Test func keyUnavailableWithKeyShowsRetryAndErase() {
        #expect(HistoryLockedView.actions(for: .keyUnavailable, keyExists: true) == [.unlock, .erase])
    }
}
