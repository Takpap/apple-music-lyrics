import XCTest
@testable import AppleMusicLyrics

final class AirPlayDeviceTests: XCTestCase {
    func testParsesMusicAirPlayRows() {
        let d = "\u{1F}"
        let raw = "Hidden Device\(d)computer\(d)false\(d)true\nBedroom\(d)HomePod\(d)true\(d)true\n\nbroken row\n"
        let devices = MusicExtrasService.parseAirPlayDevices(raw, delimiter: d)
        XCTAssertEqual(devices, [
            MusicAirPlayDevice(name: "Hidden Device", kind: "computer", selected: false, available: true),
            MusicAirPlayDevice(name: "Bedroom", kind: "homepod", selected: true, available: true)
        ])
        XCTAssertTrue(devices[0].isComputer)
    }

    func testEscapesNamesForAppleScript() {
        XCTAssertEqual(MusicExtrasService.appleScriptEscaped(#"Tejas's "Den" \ TV"#), #"Tejas's \"Den\" \\ TV"#)
    }
}
