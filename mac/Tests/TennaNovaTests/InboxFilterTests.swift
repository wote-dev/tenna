import Testing
@testable import TennaNova

struct InboxFilterTests {

    @Test func emptyQueryKeepsEveryThreadInOrder() {
        let first = makeSearchThread(id: 1, title: "First")
        let second = makeSearchThread(id: 2, title: "Second")

        #expect(InboxFilter.apply([first, second], query: "") == [first, second])
        #expect(InboxFilter.apply([first, second], query: "   ") == [first, second])
    }

    @Test func matchingIsCaseAndDiacriticInsensitive() {
        let thread = makeSearchThread(title: "Café Central")

        #expect(InboxFilter.matches(thread, query: "CAFE"))
    }

    @Test func searchesTitlePreviewAppPackageAndAddress() {
        let thread = makeSearchThread(pkg: "org.signal.secure",
                                      appLabel: "Signal",
                                      title: "Weekend plans",
                                      body: "Bring the blue umbrella",
                                      address: "+61 491 570 006")

        #expect(InboxFilter.matches(thread, query: "weekend"))
        #expect(InboxFilter.matches(thread, query: "umbrella"))
        #expect(InboxFilter.matches(thread, query: "signal"))
        #expect(InboxFilter.matches(thread, query: "secure"))
        #expect(InboxFilter.matches(thread, query: "570 006"))
        #expect(!InboxFilter.matches(thread, query: "telegram"))
    }

    @Test func searchStaysInsideTheSelectedInboxTab() {
        let message = makeSearchThread(id: 1, title: "Shared term")
        let notification = makeSearchThread(id: 2, title: "Shared term",
                                            isConversation: false)

        #expect(InboxFilter.apply(tab: .messages,
                                 messages: [message], notifications: [notification],
                                 query: "shared") == [message])
        #expect(InboxFilter.apply(tab: .notifications,
                                 messages: [message], notifications: [notification],
                                 query: "shared") == [notification])
    }

    @Test func aNoResultQueryReturnsAnEmptyList() {
        let thread = makeSearchThread(title: "Sam")
        #expect(InboxFilter.apply([thread], query: "No one here").isEmpty)
    }
}
