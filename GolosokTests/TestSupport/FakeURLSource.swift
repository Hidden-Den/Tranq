//
//  FakeURLSource.swift
//  GolosokTests
//

import Foundation
@testable import Golosok

/// Подмена чтения адреса вкладки: заданный адрес, необязательная задержка и счётчик вызовов.
final class FakeURLSource: FocusedURLSource, @unchecked Sendable {
    private let lock = NSLock()
    private var storedURL: URL?
    private var storedCalls = 0
    private let delay: TimeInterval

    init(url: URL?, delay: TimeInterval = 0) {
        self.storedURL = url
        self.delay = delay
    }

    var url: URL? {
        get { lock.withLock { storedURL } }
        set { lock.withLock { storedURL = newValue } }
    }

    var calls: Int { lock.withLock { storedCalls } }

    func focusedURL(pid: pid_t, bundleId: String) -> URL? {
        let current = lock.withLock { () -> URL? in
            storedCalls += 1
            return storedURL
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return current
    }
}
