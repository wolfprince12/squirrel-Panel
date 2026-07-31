import XCTest
@testable import SquirrelPanel

final class RimeColorTests: XCTestCase {
  func testAqua() throws {
    let c = try XCTUnwrap(RimeColor(yamlValue: "0xEEECEEEE"))
    // 颜色分量在 RimeColor 内以 0...1 存储
    XCTAssertEqual(c.red, 238.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(c.green, 236.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(c.blue, 238.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(c.alpha, 238.0 / 255.0, accuracy: 0.01)
  }

  func testSixDigitOpaque() throws {
    let c = try XCTUnwrap(RimeColor(yamlValue: "0x123456"))
    XCTAssertEqual(c.red, 86.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(c.green, 52.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(c.blue, 18.0 / 255.0, accuracy: 0.01)
    XCTAssertEqual(c.alpha, 1)
  }

  func testLiteralRoundTrip() throws {
    let c = RimeColor(red: 1.0, green: 128.0 / 255.0, blue: 64.0 / 255.0, alpha: 0.8)
    let value = c.literal
    XCTAssertTrue(value.starts(with: "0x"))
    let re = try XCTUnwrap(RimeColor(yamlValue: value))
    XCTAssertEqual(re.red, c.red, accuracy: 0.01)
    XCTAssertEqual(re.green, c.green, accuracy: 0.01)
    XCTAssertEqual(re.blue, c.blue, accuracy: 0.01)
    XCTAssertEqual(re.alpha, c.alpha, accuracy: 0.01)
  }
}
