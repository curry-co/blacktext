import CoreGraphics
import Testing
@testable import BlackTextCore

/// The iPhone and iPad canvas follows the system Text Size: the saved size is what the user picked
/// at the standard setting, and the system setting scales it.
@Suite struct CanvasTextSizeTests {
    /// The system's body text sizes, from Extra Small to the largest accessibility size.
    static let bodySizes: [CGFloat] = [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53]

    @Test func theStandardSettingShowsTheSavedSize() {
        #expect(CanvasTextSize(base: 15, systemBodySize: 17).points == 15)
        #expect(CanvasTextSize(base: 22, systemBodySize: 17).points == 22)
        #expect(CanvasTextSize(base: 15, systemBodySize: 17).range == Preferences.fontSizeRange)
    }

    @Test func aLargerSystemSizeScalesTheDefault() {
        #expect(CanvasTextSize(base: 15, systemBodySize: 23).points == 20)
        #expect(CanvasTextSize(base: 15, systemBodySize: 53).points == 47)
        #expect(CanvasTextSize(base: 15, systemBodySize: 14).points == 12)
    }

    @Test func theLargestSizeGoesPastTheOldCap() {
        let size = CanvasTextSize(base: 15, systemBodySize: 53)
        #expect(size.range.upperBound > 100)
        #expect(size.range.lowerBound > Preferences.fontSizeRange.lowerBound)
    }

    @Test func pickingAShownSizeKeepsIt() {
        for body in Self.bodySizes {
            let size = CanvasTextSize(base: 15, systemBodySize: body)
            for points in stride(from: size.range.lowerBound, through: size.range.upperBound, by: 1) {
                let picked = CanvasTextSize(base: size.base(showing: points), systemBodySize: body)
                #expect(picked.points == points, "body \(body), \(points) pt")
            }
        }
    }

    @Test func pickedSizesStayInRange() {
        let size = CanvasTextSize(base: 15, systemBodySize: 40)
        #expect(CanvasTextSize(base: size.base(showing: 1000), systemBodySize: 40).points == size.range.upperBound)
        #expect(CanvasTextSize(base: size.base(showing: 1), systemBodySize: 40).points == size.range.lowerBound)
        #expect(Preferences.fontSizeRange.contains(size.base(showing: 1000)))
        #expect(Preferences.fontSizeRange.contains(size.base(showing: 1)))
    }

    @Test func stepsAPointAtATimeAtAnySetting() {
        for body in Self.bodySizes {
            let size = CanvasTextSize(base: 15, systemBodySize: body)
            #expect(size.stepped(by: 1).points == size.points + 1, "body \(body)")
            #expect(size.stepped(by: -1).points == size.points - 1, "body \(body)")
        }
    }

    @Test func aSizePickedAtOneSettingScalesWithTheNext() {
        // Pinched to 30 points at the standard setting, then the system size goes up a step.
        let picked = CanvasTextSize(base: 15, systemBodySize: 17).base(showing: 30)
        #expect(CanvasTextSize(base: picked, systemBodySize: 19).points == 34)
    }

    @Test func aMissingSystemSizeShowsTheSavedSize() {
        #expect(CanvasTextSize(base: 15, systemBodySize: 0).points == 15)
        #expect(CanvasTextSize(base: 15, systemBodySize: .nan).points == 15)
    }
}
