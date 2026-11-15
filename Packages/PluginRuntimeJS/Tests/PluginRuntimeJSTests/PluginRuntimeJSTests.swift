import Testing
@testable import PluginRuntimeJS

@Suite("PluginRuntimeJS scaffolding")
struct PluginRuntimeJSScaffoldingTests {
    @Test func packageCompiles() {
        #expect(Bool(true))
    }
}
