import Testing
@testable import SwitchrCore

@Suite
struct HotkeyConfigParserTests {
    @Test
    func parsesTheDesignDocExample() {
        let text = """
        [[hotkey]]
        key = "space"
        modifiers = ["command", "option"]
        scope = "global"

        [[hotkey]]
        key = "c"
        modifiers = ["command", "option"]
        scope = { apps = ["com.google.Chrome"] }
        """

        let bindings = HotkeyConfigParser.parse(text)

        #expect(bindings == [
            HotkeyBinding(key: "space", modifiers: ["command", "option"], scope: .global),
            HotkeyBinding(key: "c", modifiers: ["command", "option"], scope: .apps(["com.google.Chrome"]))
        ])
    }

    @Test
    func ignoresCommentsAndBlankLines() {
        let text = """
        # a leading comment
        [[hotkey]]
        key = "c" # trailing comment
        modifiers = ["command"]

        scope = "global"
        """

        let bindings = HotkeyConfigParser.parse(text)

        #expect(bindings == [
            HotkeyBinding(key: "c", modifiers: ["command"], scope: .global)
        ])
    }

    @Test
    func skipsEntriesMissingKeyOrScope() {
        let text = """
        [[hotkey]]
        modifiers = ["command"]

        [[hotkey]]
        key = "v"
        modifiers = ["command"]
        scope = "global"
        """

        let bindings = HotkeyConfigParser.parse(text)

        #expect(bindings == [
            HotkeyBinding(key: "v", modifiers: ["command"], scope: .global)
        ])
    }

    @Test
    func emptyAppsArrayIsRejectedNotTreatedAsGlobal() {
        let text = """
        [[hotkey]]
        key = "v"
        modifiers = ["command"]
        scope = { apps = [] }
        """

        #expect(HotkeyConfigParser.parse(text).isEmpty)
    }

    @Test
    func multipleAppsInOneScope() {
        let text = """
        [[hotkey]]
        key = "t"
        modifiers = ["command", "shift"]
        scope = { apps = ["com.googlecode.iterm2", "com.apple.Terminal"] }
        """

        let bindings = HotkeyConfigParser.parse(text)

        #expect(bindings == [
            HotkeyBinding(
                key: "t",
                modifiers: ["command", "shift"],
                scope: .apps(["com.googlecode.iterm2", "com.apple.Terminal"])
            )
        ])
    }

    @Test
    func emptyInputProducesNoBindings() {
        #expect(HotkeyConfigParser.parse("").isEmpty)
    }
}
