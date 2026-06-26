import Foundation
@testable import AppleToolsLib

/// Convenience `ToolHost` for tests: local file sink, no confirmation prompts.
extension ToolHost {
    static func test(fileSink: FileSink = LocalFileSink()) -> ToolHost {
        ToolHost(fileSink: fileSink, confirmer: AllowAllConfirmer(), appName: "apple-tools")
    }
}
