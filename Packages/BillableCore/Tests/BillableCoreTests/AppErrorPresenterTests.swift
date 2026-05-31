import Testing
@testable import BillableCore

@MainActor
struct AppErrorPresenterTests {

    @Test("present(_:) sets message")
    func presentSetsMessage() {
        let presenter = AppErrorPresenter()
        presenter.present("Something went wrong")
        #expect(presenter.message == "Something went wrong")
    }

    @Test("present(_:) overwrites a previous message")
    func presentOverwritesPreviousMessage() {
        let presenter = AppErrorPresenter()
        presenter.present("First error")
        presenter.present("Second error")
        #expect(presenter.message == "Second error")
    }

    @Test("init with no message starts nil")
    func initDefaultsToNil() {
        let presenter = AppErrorPresenter()
        #expect(presenter.message == nil)
    }

    @Test("clearing message sets it back to nil")
    func clearMessageSetsNil() {
        let presenter = AppErrorPresenter()
        presenter.present("An error")
        presenter.message = nil
        #expect(presenter.message == nil)
    }
}
