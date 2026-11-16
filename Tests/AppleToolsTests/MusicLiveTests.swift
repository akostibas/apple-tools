import XCTest
@testable import AppleToolsLib

/// Live tests against the real Music library. They create one labeled playlist
/// and delete it; they never touch playback. Run with
/// `bin/check --slow --tool music`.
final class MusicLiveTests: XCTestCase {

    private let tool = MusicTool()
    private let playlistName = "apple-tools live test \(UUID().uuidString.prefix(8))"
    private var createdByUs = false

    override func setUpWithError() throws {
        try LiveTest.writes("music", "playlist-create", "playlist-delete")
        try LiveTest.requireRunning("Music")
    }

    override func tearDown() {
        // Only ever clean up a playlist this run made.
        if createdByUs { _ = run("playlist-delete") }
        super.tearDown()
    }

    private func run(_ action: String) -> (obj: [String: Any], text: String, isError: Bool) {
        let (text, isError) = tool.handle(params: ["action": AnyCodable(action), "name": AnyCodable(playlistName)])
        let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (obj, text, isError)
    }

    func testCreateThenDeletePlaylistLeavesNothingBehind() throws {
        let made = run("playlist-create")
        XCTAssertFalse(made.isError, made.text)
        // A pre-existing playlist with our name is not ours to delete.
        try XCTSkipIf(made.obj["already_existed"] as? Bool == true, "\(playlistName) already exists")
        createdByUs = true
        XCTAssertEqual(made.obj["verified"] as? Bool, true, made.text)

        let deleted = run("playlist-delete")
        XCTAssertFalse(deleted.isError, deleted.text)
        XCTAssertEqual(deleted.obj["verified"] as? Bool, true, deleted.text)
        XCTAssertEqual(deleted.obj["playlist_id"] as? String, made.obj["playlist_id"] as? String)
        createdByUs = false

        let again = run("playlist-delete")
        XCTAssertTrue(again.isError, "playlist should be gone: \(again.text)")
        XCTAssertEqual(again.text, "no playlist named: \(playlistName)")
    }
}
