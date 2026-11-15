import Testing
@testable import Memory

@Suite("Memory scaffolding")
struct MemoryScaffoldingTests {
    @Test func packageCompiles() {
        #expect(Bool(true))
    }
}
