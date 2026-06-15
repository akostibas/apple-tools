import XCTest
@testable import AppleToolsLib

final class NotifierTests: XCTestCase {

    override func tearDown() {
        // Restore the real runner so other tests are unaffected.
        Notifier.runAppleScript = { source, env in
            _ = AppleScriptRunner.run(source: source, tool: "notify", deadline: 10, environment: env)
        }
        super.tearDown()
    }

    func testNotifyPassesTitleAndBodyViaEnvNotScriptSource() {
        var captured: (script: String, env: [String: String]) = ("", [:])
        Notifier.runAppleScript = { source, env in captured = (source, env) }

        let body = #"imessage send → "danger" sent (iMessage)"#
        Notifier.notify(title: "apple-tools", body: body)

        // Payload travels in env, verbatim.
        XCTAssertEqual(captured.env["APPLE_TOOLS_NOTIFY_TITLE"], "apple-tools")
        XCTAssertEqual(captured.env["APPLE_TOOLS_NOTIFY_BODY"], body)
        // ...and never appears in the script source (no injection surface).
        XCTAssertFalse(captured.script.contains("danger"))
        XCTAssertTrue(captured.script.contains("printenv APPLE_TOOLS_NOTIFY_BODY"))
        XCTAssertTrue(captured.script.contains("display notification"))
    }
}
