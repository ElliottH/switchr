import Testing
@testable import SwitchrCore

@Suite
struct DeadlineTests {
    @Test
    func operationFinishingBeforeDeadlineReturnsItsResult() async {
        let result = await withDeadline(0.2) {
            "done"
        }
        #expect(result == "done")
    }

    @Test
    func operationExceedingDeadlineReturnsNil() async {
        let result = await withDeadline(0.05) { () -> String in
            try? await Task.sleep(for: .seconds(5))
            return "too slow"
        }
        #expect(result == nil)
    }
}
