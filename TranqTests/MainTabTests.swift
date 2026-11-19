import Testing
@testable import Tranq

struct MainTabTests {
    @Test func sidebarOrder() {
        #expect(MainTab.allCases == [.vocabulary, .rules, .history, .settings])
    }

    @Test func everyTabHasTitle() {
        for tab in MainTab.allCases { #expect(!tab.title.isEmpty) }
    }
}
