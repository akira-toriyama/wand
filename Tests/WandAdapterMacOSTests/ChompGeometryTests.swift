// Pins ChompGeometry's value → value contracts so the renderer split
// (and any later edit to the math) is measured, not eyeballed: the
// capsule wand driver never draws a chomp stroke, so these are the
// only automated check on the chomp trail's layout.

import XCTest
import CoreGraphics
import WandCore
@testable import WandAdapterMacOS

final class ChompGeometryTests: XCTestCase {

    // MARK: snap

    func testSnapKeepsTheAxisOfTheLastDirection() {
        let from = CGPoint(x: 3, y: 0)
        XCTAssertEqual(ChompGeometry.snap(CGPoint(x: 10, y: 7), to: .right, from: from),
                       CGPoint(x: 10, y: 0))
        XCTAssertEqual(ChompGeometry.snap(CGPoint(x: 10, y: 7), to: .left, from: from),
                       CGPoint(x: 10, y: 0))
        XCTAssertEqual(ChompGeometry.snap(CGPoint(x: 10, y: 7), to: .up, from: from),
                       CGPoint(x: 3, y: 7))
        XCTAssertEqual(ChompGeometry.snap(CGPoint(x: 10, y: 7), to: .down, from: from),
                       CGPoint(x: 3, y: 7))
    }

    // MARK: snappedPoints

    func testSnappedPointsProjectsTheLiveCursorOntoLastDir() {
        let pts = ChompGeometry.snappedPoints(
            origin: .zero,
            corners: [CGPoint(x: 100, y: 0)],
            cursor: CGPoint(x: 130, y: 9),
            lastDir: .up,
            straightenOnTurn: true,
            rawTrail: [])
        XCTAssertEqual(pts, [.zero, CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 9)])
    }

    func testSnappedPointsDropsATailThatCollapsesOntoTheLastCorner() {
        let pts = ChompGeometry.snappedPoints(
            origin: .zero,
            corners: [CGPoint(x: 100, y: 0)],
            cursor: CGPoint(x: 100, y: 5),
            lastDir: .right,
            straightenOnTurn: true,
            rawTrail: [])
        XCTAssertEqual(pts, [.zero, CGPoint(x: 100, y: 0)])
    }

    func testSnappedPointsFallsBackToRawTrailWhenNotStraightening() {
        let raw = [CGPoint.zero, CGPoint(x: 3, y: 4), CGPoint(x: 7, y: 2)]
        let pts = ChompGeometry.snappedPoints(
            origin: .zero, corners: [CGPoint(x: 50, y: 0)],
            cursor: CGPoint(x: 60, y: 1), lastDir: .right,
            straightenOnTurn: false, rawTrail: raw)
        XCTAssertEqual(pts, raw)
    }

    // MARK: walkPolyline

    private struct Emit: Equatable {
        let point: CGPoint
        let tangent: CGPoint
        let arc: CGFloat
    }

    private func walk(_ pts: [CGPoint], interval: CGFloat,
                      trimTail: CGFloat = 0) -> [Emit] {
        var out: [Emit] = []
        ChompGeometry.walkPolyline(points: pts, interval: interval,
                                   trimTail: trimTail) { p, t, arc in
            out.append(Emit(point: p, tangent: t, arc: arc))
        }
        return out
    }

    func testWalkEmitsOriginThenEveryIntervalThenTheHead() {
        let emits = walk([.zero, CGPoint(x: 100, y: 0)], interval: 30)
        XCTAssertEqual(emits.map(\.arc), [0, 30, 60, 90, 100])
        XCTAssertEqual(emits.map(\.point.x), [0, 30, 60, 90, 100])
        XCTAssertTrue(emits.allSatisfy { $0.tangent == CGPoint(x: 1, y: 0) })
    }

    func testWalkTrimTailStopsExactlyAtTheCutoff() {
        let emits = walk([.zero, CGPoint(x: 100, y: 0)], interval: 30,
                         trimTail: 25)
        XCTAssertEqual(emits.map(\.arc), [0, 30, 60, 75])
        XCTAssertEqual(emits.last?.point, CGPoint(x: 75, y: 0))
    }

    func testWalkTrimTailLongerThanThePathEmitsNothing() {
        XCTAssertTrue(walk([.zero, CGPoint(x: 100, y: 0)], interval: 30,
                           trimTail: 100).isEmpty)
    }

    func testWalkCarriesTheIntervalRemainderAcrossACorner() {
        let emits = walk([.zero, CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)],
                         interval: 20)
        XCTAssertEqual(Array(emits.prefix(4)), [
            Emit(point: .zero, tangent: CGPoint(x: 1, y: 0), arc: 0),
            Emit(point: CGPoint(x: 20, y: 0), tangent: CGPoint(x: 1, y: 0), arc: 20),
            Emit(point: CGPoint(x: 40, y: 0), tangent: CGPoint(x: 1, y: 0), arc: 40),
            Emit(point: CGPoint(x: 50, y: 10), tangent: CGPoint(x: 0, y: 1), arc: 60),
        ])
        XCTAssertEqual(emits.map(\.arc), emits.map(\.arc).sorted())
    }

    // MARK: innerCornerPoints

    func testInnerCornerSitsInsideTheElbowForBothTurnDirections() {
        let leftTurn = ChompGeometry.innerCornerPoints(
            snappedPts: [.zero, CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)],
            wallOffset: 16)
        XCTAssertEqual(leftTurn.count, 1)
        XCTAssertEqual(leftTurn[0].x, 34, accuracy: 1e-9)
        XCTAssertEqual(leftTurn[0].y, 16, accuracy: 1e-9)

        let rightTurn = ChompGeometry.innerCornerPoints(
            snappedPts: [.zero, CGPoint(x: 50, y: 0), CGPoint(x: 50, y: -50)],
            wallOffset: 16)
        XCTAssertEqual(rightTurn.count, 1)
        XCTAssertEqual(rightTurn[0].x, 34, accuracy: 1e-9)
        XCTAssertEqual(rightTurn[0].y, -16, accuracy: 1e-9)
    }

    func testInnerCornerSkipsStraightRunsAndShortPolylines() {
        XCTAssertTrue(ChompGeometry.innerCornerPoints(
            snappedPts: [.zero, CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0)],
            wallOffset: 16).isEmpty)
        XCTAssertTrue(ChompGeometry.innerCornerPoints(
            snappedPts: [.zero, CGPoint(x: 50, y: 0)],
            wallOffset: 16).isEmpty)
    }

    // MARK: positionHash01

    func testPositionHashIsStableRoundedAndInUnitRange() {
        XCTAssertEqual(ChompGeometry.positionHash01(.zero), 0)
        XCTAssertEqual(ChompGeometry.positionHash01(CGPoint(x: 1, y: 0)), 0.5761)
        XCTAssertEqual(ChompGeometry.positionHash01(CGPoint(x: 10.4, y: 20.4)),
                       ChompGeometry.positionHash01(CGPoint(x: 10, y: 20)))
        for x in stride(from: -300, through: 300, by: 37) {
            for y in stride(from: -300, through: 300, by: 41) {
                let h = ChompGeometry.positionHash01(CGPoint(x: x, y: y))
                XCTAssertGreaterThanOrEqual(h, 0)
                XCTAssertLessThan(h, 1)
            }
        }
    }

    // MARK: centerline

    func testCenterlineIsAStraightPolylineThroughEveryPoint() {
        let path = ChompGeometry.centerline(
            points: [.zero, CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50)])
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingBox, CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertTrue(ChompGeometry.centerline(points: []).isEmpty)
    }
}
