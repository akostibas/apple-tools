import XCTest
@testable import AppleToolsLib

/// Ports the registry-coverage half of the probe's AccessPolicyTests: every
/// tool must classify its operations (no implicit read/write). The probe's
/// read-only *enforcement* lived in ProbeClient, which this package drops.
final class AccessPolicyCoverageTests: XCTestCase {

    private func tools() -> [ProbeTool] { allAppleTools(fileSink: LocalFileSink()) }

    func testEveryPerActionToolClassifiesItsActions() {
        for tool in tools() {
            guard case .perAction(let map) = tool.accessPolicy else { continue }
            XCTAssertFalse(map.isEmpty, "\(tool.definition.name): perAction policy is empty")
        }
    }

    func testWholeToolPoliciesAreExplicit() {
        // Building the registry must not trap; every tool exposes a policy.
        for tool in tools() {
            switch tool.accessPolicy {
            case .whole, .perAction:
                continue
            }
        }
        XCTAssertFalse(tools().isEmpty)
    }
}
