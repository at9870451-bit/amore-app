import Testing
@testable import PluginManager

@Suite("PluginManager scaffolding")
struct PluginManagerScaffoldingTests {
    @Test func packageCompiles() {
        #expect(Bool(true))
    }
}
