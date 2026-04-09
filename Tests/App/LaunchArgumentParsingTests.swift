import Testing
@testable import PreBabelLens

struct LaunchArgumentParsingTests {
    @Test
    func ignoresAppleLanguageRuntimeArguments() {
        let args = [
            "/Applications/PreBabelLens.app/Contents/MacOS/PreBabelLens",
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP"
        ]

        let launchText = PreBabelLens.extractLaunchInputText(from: args)
        #expect(launchText == nil)
    }

    @Test
    func keepsPositionalLaunchText() {
        let args = [
            "/Applications/PreBabelLens.app/Contents/MacOS/PreBabelLens",
            "Hello", "world"
        ]

        let launchText = PreBabelLens.extractLaunchInputText(from: args)
        #expect(launchText == "Hello world")
    }

    @Test
    func supportsDoubleDashSeparatorForText() {
        let args = [
            "/Applications/PreBabelLens.app/Contents/MacOS/PreBabelLens",
            "-AppleLanguages", "(ko)",
            "--",
            "--lang should be treated as text"
        ]

        let launchText = PreBabelLens.extractLaunchInputText(from: args)
        #expect(launchText == "--lang should be treated as text")
    }
}
