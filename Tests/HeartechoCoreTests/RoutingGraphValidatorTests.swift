import XCTest
@testable import HeartechoCore

final class RoutingGraphValidatorTests: XCTestCase {
    func testStarterDeviceIsValid() {
        let device = VirtualAudioDevice.starterDevice()
        let issues = RoutingGraphValidator.validate(device: device)

        XCTAssertTrue(issues.filter { $0.severity == .error }.isEmpty)
    }

    func testMissingRouteSourceIsAnError() {
        let device = VirtualAudioDevice(
            name: "Broken Device",
            routes: [
                ChannelRoute(sourceID: UUID(), sourceChannelIndex: 1, outputChannelIndex: 1)
            ]
        )

        let issues = RoutingGraphValidator.validate(device: device)

        XCTAssertTrue(issues.contains { $0.severity == .error })
    }
}
