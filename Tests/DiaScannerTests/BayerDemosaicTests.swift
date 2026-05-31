import XCTest
@testable import DiaScannerLib

final class BayerDemosaicTests: XCTestCase {

    // Minimal 2×2 RGGB Bayer grid — all pixels the same color
    func testUniformRedScene() throws {
        // 4×4 RGGB pattern filled so every R=200, G=100, B=50
        // RGGB pattern:
        //   R  G  R  G
        //   G  B  G  B
        //   R  G  R  G
        //   G  B  G  B
        let w = 4, h = 4
        var raw = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            for col in 0..<w {
                switch (row % 2, col % 2) {
                case (0, 0): raw[row * w + col] = 200  // R
                case (0, 1): raw[row * w + col] = 100  // G (R row)
                case (1, 0): raw[row * w + col] = 100  // G (B row)
                default:     raw[row * w + col] = 50   // B
                }
            }
        }
        let rawData = Data(raw)
        let rgb = BayerDemosaic.demosaic(rawData, width: w, height: h, pattern: .rggb)

        // Interior pixel (1,1) = B pixel; expect B≈50, G≈100, R≈200 after interpolation
        let pixelIndex = (1 * w + 1) * 3
        XCTAssertEqual(Int(rgb[pixelIndex + 0]), 200, accuracy: 20) // R
        XCTAssertEqual(Int(rgb[pixelIndex + 1]), 100, accuracy: 20) // G
        XCTAssertEqual(Int(rgb[pixelIndex + 2]), 50,  accuracy: 20) // B
    }

    func testOutputSize() {
        let w = 8, h = 6
        let raw = Data([UInt8](repeating: 128, count: w * h))
        let rgb = BayerDemosaic.demosaic(raw, width: w, height: h, pattern: .rggb)
        XCTAssertEqual(rgb.count, w * h * 3)
    }

    func testOutputSizeForFullResolution() {
        let w = 1600, h = 1200
        let raw = Data([UInt8](repeating: 0, count: w * h))
        let rgb = BayerDemosaic.demosaic(raw, width: w, height: h, pattern: .rggb)
        XCTAssertEqual(rgb.count, w * h * 3)
    }

    func testNSImageCreation() throws {
        let w = 8, h = 8
        let raw = Data([UInt8](repeating: 180, count: w * h))
        let rgb = BayerDemosaic.demosaic(raw, width: w, height: h, pattern: .rggb)
        let image = try XCTUnwrap(BayerDemosaic.nsImage(fromRGB: rgb, width: w, height: h))
        XCTAssertEqual(image.size.width,  CGFloat(w))
        XCTAssertEqual(image.size.height, CGFloat(h))
    }

    func testGreenChannelPatterns() {
        // On a G pixel, G should be directly sampled, R/B interpolated
        let w = 4, h = 4
        var raw = [UInt8](repeating: 0, count: w * h)
        // Set only green pixels to 255
        for row in 0..<h {
            for col in 0..<w {
                let isGreen = (row % 2 == 0 && col % 2 == 1) || (row % 2 == 1 && col % 2 == 0)
                if isGreen { raw[row * w + col] = 255 }
            }
        }
        let rgb = BayerDemosaic.demosaic(Data(raw), width: w, height: h, pattern: .rggb)
        // At G pixel (0,1): green channel should be close to 255
        let pixelIdx = (0 * w + 1) * 3
        XCTAssertGreaterThan(Int(rgb[pixelIdx + 1]), 200) // G dominant
    }
}
