import AppKit
import XCTest

final class TiledResizePreviewTests: XCTestCase {
    func testPanelPolicyCannotActivateCaptureMouseOrEnterWindowCycle() {
        let policy = TiledResizePreviewPanelPolicy.nonActivating

        XCTAssertFalse(policy.canBecomeKey)
        XCTAssertFalse(policy.canBecomeMain)
        XCTAssertTrue(policy.ignoresMouseEvents)
        XCTAssertFalse(policy.participatesInWindowCycle)
    }

    func testMoveTransitionAnimatesOnlyAnExistingPreview() {
        XCTAssertFalse(TiledResizePreviewTransition.immediate.shouldAnimate(isContinuation: true))
        XCTAssertFalse(TiledResizePreviewTransition.animated.shouldAnimate(isContinuation: false))
        XCTAssertTrue(TiledResizePreviewTransition.animated.shouldAnimate(isContinuation: true))
        XCTAssertGreaterThan(TiledResizePreviewPolicy.moveAnimationDuration, 0)
    }

    func testAccessibilityFrameConversionUsesMainDisplayTopAcrossGlobalDesktop() {
        let frame = WindowFrame(
            position: CGPoint(x: -800, y: -300),
            size: CGSize(width: 640, height: 480)
        )

        XCTAssertEqual(
            TiledResizePreviewPolicy.appKitFrame(for: frame, mainScreenTop: 1_000),
            CGRect(x: -800, y: 820, width: 640, height: 480)
        )
    }

    func testTileFrameIsRelativeToCurtainAndReservesVisibleSeparation() {
        let frame = WindowFrame(
            position: CGPoint(x: 110, y: 120),
            size: CGSize(width: 300, height: 240)
        )
        let panelFrame = CGRect(x: 100, y: 640, width: 800, height: 500)

        XCTAssertEqual(
            TiledResizePreviewPolicy.localTileFrame(
                frame,
                panelFrame: panelFrame,
                mainScreenTop: 1_000
            ),
            CGRect(x: 12, y: 2, width: 296, height: 236)
        )
    }

    func testDraggedEdgesInferInternalLeadingAndTrailingChanges() {
        let expected = WindowFrame(
            position: CGPoint(x: 100, y: 200),
            size: CGSize(width: 500, height: 400)
        )

        XCTAssertEqual(
            TiledResizeDraggedEdges.inferred(
                expectedFrame: expected,
                observedFrame: WindowFrame(
                    position: CGPoint(x: 160, y: 200),
                    size: CGSize(width: 440, height: 470)
                )
            ),
            [.left, .bottom]
        )
        XCTAssertEqual(
            TiledResizeDraggedEdges.inferred(
                expectedFrame: expected,
                observedFrame: WindowFrame(
                    position: CGPoint(x: 100, y: 150),
                    size: CGSize(width: 560, height: 450)
                )
            ),
            [.right, .top]
        )
    }

    func testTitleBarMoveWithTransientSizeNoiseIsNotClaimedAsResize() {
        let expected = WindowFrame(
            position: CGPoint(x: 100, y: 200),
            size: CGSize(width: 500, height: 400)
        )
        let observed = WindowFrame(
            position: CGPoint(x: 180, y: 250),
            size: CGSize(width: 506, height: 404)
        )

        XCTAssertEqual(
            TiledManualDragClassifier.classify(
                expectedFrame: expected,
                observedFrame: observed,
                pointer: CGPoint(x: 430, y: 278)
            ),
            .move
        )
    }

    func testPointerOnChangedEdgeClassifiesRightAndLeftResize() {
        let expected = WindowFrame(
            position: CGPoint(x: 100, y: 200),
            size: CGSize(width: 500, height: 400)
        )

        XCTAssertEqual(
            TiledManualDragClassifier.classify(
                expectedFrame: expected,
                observedFrame: WindowFrame(
                    position: expected.position,
                    size: CGSize(width: 560, height: 400)
                ),
                pointer: CGPoint(x: 660, y: 400)
            ),
            .resize(.right)
        )
        XCTAssertEqual(
            TiledManualDragClassifier.classify(
                expectedFrame: expected,
                observedFrame: WindowFrame(
                    position: CGPoint(x: 160, y: 200),
                    size: CGSize(width: 440, height: 400)
                ),
                pointer: CGPoint(x: 160, y: 400)
            ),
            .resize(.left)
        )
    }

    func testCapturedClaudeLeftEdgeResizesDoNotBecomeMovesWhenPointerAndFrameDisagree() {
        let expected = WindowFrame(
            position: CGPoint(x: 1923, y: 30), size: CGSize(width: 1917, height: 1531)
        )
        // Frames are from the live failure. Pointer offsets model asynchronous sampling;
        // the reports did not record the actual pointer coordinates.
        for left: CGFloat in [1685, 1537, 2430] {
            let observed = WindowFrame(
                position: CGPoint(x: left, y: 30), size: CGSize(width: 3840 - left, height: 1531)
            )
            for offset: CGFloat in [-24, 24] {
                XCTAssertNil(TiledManualDragClassifier.classify(
                    expectedFrame: expected, observedFrame: observed,
                    pointer: CGPoint(x: left + offset, y: 700)
                ), "An uncertain resize must not start a move that restores the old width")
            }
            XCTAssertEqual(TiledManualDragClassifier.classify(
                expectedFrame: expected, observedFrame: observed,
                pointer: CGPoint(x: left, y: 700)
            ), .resize(.left))
        }
    }

    func testAnchoredTopResizeWithUnsynchronisedPointerDoesNotBecomeMove() {
        XCTAssertNil(TiledManualDragClassifier.classify(
            expectedFrame: WindowFrame(position: CGPoint(x: 100, y: 200), size: CGSize(width: 500, height: 400)),
            observedFrame: WindowFrame(position: CGPoint(x: 100, y: 260), size: CGSize(width: 500, height: 340)),
            pointer: CGPoint(x: 350, y: 284)
        ))
    }

    func testAnchoredTopLeftResizeWithPointerOnOnlyOneEdgeDoesNotBecomeMove() {
        XCTAssertNil(TiledManualDragClassifier.classify(
            expectedFrame: WindowFrame(position: CGPoint(x: 100, y: 200), size: CGSize(width: 500, height: 400)),
            observedFrame: WindowFrame(position: CGPoint(x: 160, y: 260), size: CGSize(width: 440, height: 340)),
            pointer: CGPoint(x: 160, y: 284)
        ))
    }

    func testCornerResizeRequiresPointerOnBothChangedEdges() {
        let expected = WindowFrame(
            position: CGPoint(x: 100, y: 200),
            size: CGSize(width: 500, height: 400)
        )
        let observed = WindowFrame(
            position: expected.position,
            size: CGSize(width: 560, height: 460)
        )

        XCTAssertEqual(
            TiledManualDragClassifier.classify(
                expectedFrame: expected,
                observedFrame: observed,
                pointer: CGPoint(x: 660, y: 660)
            ),
            .resize([.right, .bottom])
        )
        XCTAssertNil(TiledManualDragClassifier.classify(
            expectedFrame: expected,
            observedFrame: observed,
            pointer: CGPoint(x: 660, y: 400)
        ))
    }

    func testChangedEdgeDoesNotMatchPointerBeyondItsSpan() {
        let expected = WindowFrame(
            position: CGPoint(x: 100, y: 200),
            size: CGSize(width: 500, height: 400)
        )
        let observed = WindowFrame(
            position: expected.position,
            size: CGSize(width: 560, height: 400)
        )

        XCTAssertNil(TiledManualDragClassifier.classify(
            expectedFrame: expected,
            observedFrame: observed,
            pointer: CGPoint(x: 660, y: 1_600)
        ))
    }

    func testManagedWorkspaceCapturesOnlyStationaryWindowMovesInStableContext() {
        XCTAssertTrue(ManagedWorkspaceStationaryMoveCapturePolicy.shouldCapture(
            sourceLayout: .tiled,
            currentLayout: .tiled,
            isWorkspaceActive: true,
            isIncludedInLayout: false,
            contextMatches: true
        ))
        XCTAssertFalse(ManagedWorkspaceStationaryMoveCapturePolicy.shouldCapture(
            sourceLayout: .tiled,
            currentLayout: .tiled,
            isWorkspaceActive: true,
            isIncludedInLayout: true,
            contextMatches: true
        ))
        XCTAssertFalse(ManagedWorkspaceStationaryMoveCapturePolicy.shouldCapture(
            sourceLayout: .none,
            currentLayout: .none,
            isWorkspaceActive: true,
            isIncludedInLayout: false,
            contextMatches: true
        ))
        XCTAssertTrue(ManagedWorkspaceStationaryMoveCapturePolicy.shouldCapture(
            sourceLayout: .none,
            currentLayout: .none,
            isWorkspaceActive: false,
            keepsOnAllWorkspaces: true,
            isIncludedInLayout: false,
            contextMatches: true
        ))
        XCTAssertFalse(ManagedWorkspaceStationaryMoveCapturePolicy.shouldCapture(
            sourceLayout: .accordion,
            currentLayout: .tiled,
            isWorkspaceActive: true,
            isIncludedInLayout: false,
            contextMatches: true
        ))
        XCTAssertFalse(ManagedWorkspaceStationaryMoveCapturePolicy.shouldCapture(
            sourceLayout: .tiled,
            currentLayout: .tiled,
            isWorkspaceActive: true,
            isIncludedInLayout: false,
            contextMatches: false
        ))
        XCTAssertTrue(ManagedWorkspaceStationaryMoveCapturePolicy.shouldCapture(
            sourceLayout: .tiled,
            currentLayout: .tiled,
            isWorkspaceActive: false,
            keepsOnAllWorkspaces: true,
            isIncludedInLayout: false,
            contextMatches: true
        ))
    }

    func testPointerRecoveryUsesLiveTargetInsteadOfStaleFocusedWindow() {
        let focused = WindowKey(processIdentifier: 101, windowIdentifier: 1)
        let pointerTarget = WindowKey(processIdentifier: 202, windowIdentifier: 2)

        XCTAssertEqual(ManualPointerRecoveryPolicy.recoveryWindow(
            focusedWindow: focused,
            pointerTargetWindow: pointerTarget
        ), pointerTarget)
        XCTAssertNil(ManualPointerRecoveryPolicy.recoveryWindow(
            focusedWindow: focused,
            pointerTargetWindow: nil
        ))
        XCTAssertEqual(ManualPointerRecoveryPolicy.recoveryWindow(
            focusedWindow: focused,
            pointerTargetWindow: focused
        ), focused)
    }

    func testDraggedEdgesProjectFrameFromPointerAfterRealWindowIsParked() throws {
        let edges: TiledResizeDraggedEdges = [.left, .bottom]
        let projected = try XCTUnwrap(
            edges.projectedFrame(
                from: WindowFrame(
                    position: CGPoint(x: 300, y: 100),
                    size: CGSize(width: 500, height: 400)
                ),
                anchorPointer: CGPoint(x: 300, y: 500),
                pointer: CGPoint(x: 250, y: 560)
            )
        )

        XCTAssertEqual(projected.position, CGPoint(x: 250, y: 100))
        XCTAssertEqual(projected.size, CGSize(width: 550, height: 460))
    }

    @MainActor
    func testGlassTileUsesNativeGlassWhenAvailableAndHUDMaterialOtherwise() throws {
        let surface = TiledResizeGlassSurfaceFactory.make(
            frame: CGRect(x: 0, y: 0, width: 300, height: 240)
        )

        if #available(macOS 26.0, *) {
            let glass = try XCTUnwrap(surface as? NSGlassEffectView)
            XCTAssertEqual(glass.style, .clear)
            XCTAssertEqual(glass.cornerRadius, TiledResizePreviewPolicy.tileCornerRadius)
            XCTAssertNil(glass.tintColor)
            XCTAssertNil(glass.contentView)
        } else {
            let material = try XCTUnwrap(surface as? NSVisualEffectView)
            XCTAssertEqual(material.material, .hudWindow)
            XCTAssertEqual(material.blendingMode, .withinWindow)
            XCTAssertEqual(
                material.layer?.cornerRadius,
                TiledResizePreviewPolicy.tileCornerRadius
            )
        }
        XCTAssertFalse(surface.isAccessibilityElement())
    }

    @MainActor
    func testNativeCanvasLeavesDesktopTransparentAndBatchesGlassTiles() throws {
        let canvas = TiledResizePreviewCanvas(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )

        if #available(macOS 26.0, *) {
            XCTAssertTrue(canvas.usesNativeGlassContainer)
            let container = try XCTUnwrap(canvas.subviews.first as? NSGlassEffectContainerView)
            XCTAssertEqual(container.spacing, 0)
            XCTAssertNil(canvas.layer?.backgroundColor)
            XCTAssertTrue(canvas.layer?.sublayers?.isEmpty ?? true)
        } else {
            XCTAssertFalse(canvas.usesNativeGlassContainer)
            XCTAssertNil(canvas.layer?.backgroundColor)
        }
    }

    @MainActor
    func testNativeTileUsesClearGlassAndPlacesBorderInsideGlass() throws {
        let tile = TiledResizePreviewTileView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        if #available(macOS 26.0, *) {
            let glass = try XCTUnwrap(tile.surface as? NSGlassEffectView)
            XCTAssertEqual(glass.style, .clear)
            XCTAssertTrue(tile.subviews.first === glass)
            let border = try XCTUnwrap(glass.contentView)
            XCTAssertEqual(
                border.layer?.borderWidth,
                TiledResizePreviewPolicy.nativeBorderWidth
            )
            XCTAssertEqual(border.layer?.cornerRadius, TiledResizePreviewPolicy.tileCornerRadius)
        } else {
            XCTAssertTrue(tile.surface is NSVisualEffectView)
        }
    }

    @MainActor
    func testLandingTileUsesAccentTintAndStrongerBorder() throws {
        let tile = TiledResizePreviewTileView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            role: .landing
        )

        if #available(macOS 26.0, *) {
            let glass = try XCTUnwrap(tile.surface as? NSGlassEffectView)
            XCTAssertNotNil(glass.tintColor)
            let border = try XCTUnwrap(glass.contentView)
            XCTAssertGreaterThan(
                border.layer?.borderWidth ?? 0,
                TiledResizePreviewPolicy.nativeBorderWidth
            )
        } else {
            XCTAssertGreaterThan(tile.surface.layer?.borderWidth ?? 0, 1)
        }
    }

    @MainActor
    func testStaleDismissCannotRemoveNewerPreview() {
        let firstToken = UUID()
        let secondToken = UUID()
        let key = WindowKey(processIdentifier: 42, windowIdentifier: 7)
        let controller = TiledResizePreviewController(mainScreenTopProvider: { 1_000 })

        func presentation(_ token: UUID) -> TiledResizePreviewPresentation {
            TiledResizePreviewPresentation(
                token: token,
                displayIdentifier: "display",
                layoutBounds: WindowFrame(
                    position: CGPoint(x: 0, y: 0),
                    size: CGSize(width: 800, height: 600)
                ),
                frames: [
                    key: WindowFrame(
                        position: CGPoint(x: 0, y: 0),
                        size: CGSize(width: 800, height: 600)
                    ),
                ],
                transition: .immediate,
                role: .layout
            )
        }

        controller.present(presentation(firstToken))
        controller.present(presentation(secondToken))
        XCTAssertFalse(controller.dismiss(token: firstToken, reason: "stale"))
        XCTAssertEqual(controller.presentedToken, secondToken)

        XCTAssertTrue(controller.dismiss(token: secondToken, reason: "current"))
        XCTAssertNil(controller.presentedToken)
        controller.shutdown()
    }

    @MainActor
    func testDisplayChangeReportsWhetherItDismissedAnActivePreview() {
        let token = UUID()
        let key = WindowKey(processIdentifier: 42, windowIdentifier: 7)
        let controller = TiledResizePreviewController(mainScreenTopProvider: { 1_000 })
        controller.present(TiledResizePreviewPresentation(
            token: token,
            displayIdentifier: "display",
            layoutBounds: WindowFrame(
                position: CGPoint(x: 0, y: 0),
                size: CGSize(width: 800, height: 600)
            ),
            frames: [
                key: WindowFrame(
                    position: CGPoint(x: 0, y: 0),
                    size: CGSize(width: 800, height: 600)
                ),
            ],
            transition: .immediate,
            role: .layout
        ))

        XCTAssertTrue(controller.screenParametersDidChange())
        XCTAssertNil(controller.presentedToken)
        XCTAssertFalse(controller.screenParametersDidChange())
        controller.shutdown()
    }

    @MainActor
    func testOffscreenProductionPreviewRender() throws {
        let environment = ProcessInfo.processInfo.environment
        let resizePath = environment["WINDOWRANGER_TILED_RESIZE_PREVIEW_PATH"]
        let landingPath = environment["WINDOWRANGER_TILED_LANDING_PREVIEW_PATH"]
        guard let outputPath = [landingPath, resizePath].compactMap({ $0 }).first,
              !outputPath.isEmpty
        else { return }

        let size = CGSize(width: 1_200, height: 800)
        let canvas = TiledResizePreviewCanvas(frame: CGRect(origin: .zero, size: size))
        let keys = (1...3).map {
            WindowKey(processIdentifier: 42, windowIdentifier: CGWindowID($0))
        }
        let layoutFrames: [WindowKey: WindowFrame] = [
                keys[0]: WindowFrame(
                    position: CGPoint(x: 0, y: 0),
                    size: CGSize(width: 720, height: 800)
                ),
                keys[1]: WindowFrame(
                    position: CGPoint(x: 720, y: 0),
                    size: CGSize(width: 480, height: 460)
                ),
                keys[2]: WindowFrame(
                    position: CGPoint(x: 720, y: 460),
                    size: CGSize(width: 480, height: 340)
                ),
            ]
        let landingFrames = [
            keys[0]: WindowFrame(
                position: CGPoint(x: 720, y: 0),
                size: CGSize(width: 240, height: 460)
            ),
        ]
        canvas.update(
            frames: landingPath == nil ? layoutFrames : landingFrames,
            panelFrame: CGRect(origin: .zero, size: size),
            mainScreenTop: size.height,
            role: landingPath == nil ? .layout : .landing
        )
        canvas.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        XCTAssertGreaterThan(data.count, 1_000)
    }

    func testManagedResizeConstraintsLearnsLargerReadbackAsProvisionalMinimum() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var constraints = ManagedResizeConstraints()

        XCTAssertEqual(
            constraints.observe(
                requested: CGSize(width: 500, height: 400),
                actual: CGSize(width: 600, height: 400),
                now: now
            ),
            .constrained
        )
        XCTAssertEqual(constraints.minimumSize(at: now), CGSize(width: 600, height: 0))
        XCTAssertEqual(constraints.nextRetryDate, now.addingTimeInterval(1))
    }

    func testManagedResizeConstraintsDefersGrowthRefusalWithoutInventingMinimum() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var constraints = ManagedResizeConstraints()

        XCTAssertEqual(
            constraints.observe(
                requested: CGSize(width: 800, height: 500),
                actual: CGSize(width: 600, height: 500),
                now: now
            ),
            .deferred
        )
        XCTAssertEqual(constraints.minimumSize(at: now), .zero)
        XCTAssertTrue(constraints.retryDue(now: now.addingTimeInterval(1)))
    }

    func testManagedResizeConstraintsLearnsPartialConstraintButDefersShrink() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var constraints = ManagedResizeConstraints()

        XCTAssertEqual(
            constraints.observe(
                requested: CGSize(width: 500, height: 500),
                actual: CGSize(width: 600, height: 490),
                now: now
            ),
            .deferred
        )
        XCTAssertEqual(constraints.minimumSize(at: now), CGSize(width: 600, height: 0))
    }

    func testManagedResizeConstraintsInvalidatesBoundWhenReadbackIsSmaller() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var constraints = ManagedResizeConstraints()
        _ = constraints.observe(
            requested: CGSize(width: 500, height: 400),
            actual: CGSize(width: 600, height: 400),
            now: now
        )

        XCTAssertTrue(constraints.observeActual(CGSize(width: 550, height: 400), now: now))
        XCTAssertEqual(constraints.minimumSize(at: now), .zero)
    }

    func testManagedResizeConstraintsExpiresProvisionalBounds() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var constraints = ManagedResizeConstraints()
        _ = constraints.observe(
            requested: CGSize(width: 500, height: 400),
            actual: CGSize(width: 600, height: 400),
            now: now
        )

        XCTAssertEqual(
            constraints.minimumSize(at: now.addingTimeInterval(ManagedResizeConstraints.constraintLifetime)),
            .zero
        )
    }

    func testManagedResizeConstraintsRejectsMissingAndNonFiniteReadback() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var constraints = ManagedResizeConstraints()

        XCTAssertEqual(
            constraints.observe(requested: CGSize(width: 500, height: 400), actual: nil, now: now),
            .unavailable
        )
        XCTAssertEqual(
            constraints.observe(
                requested: CGSize(width: 500, height: 400),
                actual: CGSize(width: CGFloat.infinity, height: 400),
                now: now
            ),
            .unavailable
        )
    }

    func testManagedResizeConstraintsSettlesOnEventualTargetAndDoesNotRetry() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var constraints = ManagedResizeConstraints()
        _ = constraints.observe(
            requested: CGSize(width: 800, height: 500),
            actual: CGSize(width: 600, height: 500),
            now: now
        )

        XCTAssertEqual(
            constraints.observe(
                requested: CGSize(width: 800, height: 500),
                actual: CGSize(width: 800, height: 500),
                now: now.addingTimeInterval(1)
            ),
            .applied
        )
        XCTAssertNil(constraints.nextRetryDate)
        XCTAssertFalse(constraints.retryDue(now: now.addingTimeInterval(100)))
    }

    func testManagedResizeConstraintsBoundsRetriesAndNewTargetRearmsThem() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var constraints = ManagedResizeConstraints()
        let requested = CGSize(width: 800, height: 500)
        let actual = CGSize(width: 600, height: 500)

        _ = constraints.observe(requested: requested, actual: actual, now: now)
        XCTAssertEqual(constraints.nextRetryDate, now.addingTimeInterval(1))
        _ = constraints.observe(requested: requested, actual: actual, now: now.addingTimeInterval(1))
        XCTAssertEqual(constraints.nextRetryDate, now.addingTimeInterval(3))
        _ = constraints.observe(requested: requested, actual: actual, now: now.addingTimeInterval(3))
        XCTAssertEqual(constraints.nextRetryDate, now.addingTimeInterval(8))
        _ = constraints.observe(requested: requested, actual: actual, now: now.addingTimeInterval(8))
        XCTAssertNil(constraints.nextRetryDate)
        XCTAssertTrue(constraints.retryExhausted)

        _ = constraints.observe(
            requested: CGSize(width: 801, height: 500),
            actual: actual,
            now: now.addingTimeInterval(8)
        )
        XCTAssertEqual(constraints.nextRetryDate, now.addingTimeInterval(9))
        XCTAssertFalse(constraints.retryExhausted)
    }
}
