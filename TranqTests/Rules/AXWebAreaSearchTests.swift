//
//  AXWebAreaSearchTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Поиск веб-области страницы в дереве Accessibility: порядок, фильтр адресов, пределы по времени и числу узлов.
struct AXWebAreaSearchTests {

    final class Node {
        let role: String
        let url: URL?
        let children: [Node]
        init(_ role: String, url: String? = nil, _ children: [Node] = []) {
            self.role = role
            self.url = url.flatMap(URL.init(string:))
            self.children = children
        }
    }

    private func search(
        _ root: Node,
        maxVisited: Int = 400,
        budget: TimeInterval = 0.3,
        now: @escaping () -> Date = Date.init,
        onChildren: @escaping (Node) -> Void = { _ in },
        onRole: @escaping (Node) -> Void = { _ in }
    ) -> URL? {
        AXWebAreaSearch.firstPageURL(
            root: root, maxVisited: maxVisited, budget: budget, now: now,
            role: { onRole($0); return $0.role },
            children: { onChildren($0); return $0.children },
            url: { $0.url }
        )
    }

    @Test func findsWebAreaBelowToolbar() {
        let tree = Node("AXWindow", [
            Node("AXToolbar", [Node("AXButton"), Node("AXTextField", url: "https://not-this.ru")]),
            Node("AXGroup", [Node("AXGroup", [Node("AXWebArea", url: "https://mail.company.ru/inbox")])]),
        ])
        #expect(search(tree) == URL(string: "https://mail.company.ru/inbox"))
    }

    @Test func skipsDevToolsAndInspectorWebAreas() {
        let tree = Node("AXWindow", [
            Node("AXWebArea", url: "devtools://devtools/bundled/devtools_app.html"),
            Node("AXWebArea", url: "inspector://page"),
            Node("AXWebArea"),
            Node("AXGroup", [Node("AXWebArea", url: "https://chatgpt.com/c/1")]),
        ])
        #expect(search(tree) == URL(string: "https://chatgpt.com/c/1"))
    }

    @Test func noPageGivesNil() {
        #expect(search(Node("AXWindow", [Node("AXWebArea", url: "devtools://x")])) == nil)
        #expect(search(Node("AXWindow")) == nil)
    }

    @Test func givesUpWhenBudgetIsSpent() {
        // Каждое чтение детей «стоит» 0.1 с; бюджет 0.3 с, а страница лежит глубоко
        var clock = Date(timeIntervalSince1970: 0)
        var expanded = 0
        let deep = Node("AXWebArea", url: "https://deep.ru")
        let tree = Node("AXWindow", (0..<20).map { _ in Node("AXGroup", [Node("AXGroup", [deep])]) })
        let result = search(
            tree, budget: 0.3, now: { clock },
            onChildren: { _ in expanded += 1; clock = clock.addingTimeInterval(0.1) }
        )
        #expect(result == nil)
        #expect(expanded <= 4)
    }

    @Test func stopsAtNodeCap() {
        var visited = 0
        let tree = Node("AXWindow", (0..<50).map { _ in Node("AXGroup") })
        _ = search(tree, maxVisited: 5, onRole: { _ in visited += 1 })
        #expect(visited <= 5)
    }
}
