import AppKit
import SwiftUI
import XCTest
@testable import RinkanUMIS

@MainActor
final class RootViewViewportLayoutTests: XCTestCase {
    @MainActor
    private struct HostingHarness {
        let window: NSWindow
        let controller: NSViewController
        let hostView: NSView
        let proposedFittingSize: CGSize

        func tearDown() {
            window.contentViewController = nil
            window.close()
        }
    }

    private let supportedViewports = [
        CGSize(width: 1_080, height: 700),
        CGSize(width: 1_360, height: 860),
    ]

    func testEveryWorkspaceKeepsNavigationSplitInsideSupportedViewports() throws {
        _ = NSApplication.shared

        for viewportSize in supportedViewports {
            for route in WorkspaceRoute.allCases {
                try assertRootLayout(route: route, viewportSize: viewportSize)
            }
        }
    }

    func testEveryWorkspaceMinimumHeightStaysWithinMinimumWindowViewport() {
        let maximumHeight: CGFloat = 700

        let ingestModel = AppModel(initializeServices: false)
        assertMinimumHeight(
            IngestWorkspaceView().environmentObject(ingestModel),
            maximumHeight: maximumHeight,
            context: "ingest workspace"
        )

        let reviewModel = AppModel(initializeServices: false)
        assertMinimumHeight(
            RatingWorkspaceView().environmentObject(reviewModel),
            maximumHeight: maximumHeight,
            context: "review workspace"
        )

        let renameModel = AppModel(initializeServices: false)
        assertMinimumHeight(
            RenameWorkspaceView().environmentObject(renameModel),
            maximumHeight: maximumHeight,
            context: "rename workspace"
        )

        let historyModel = AppModel(initializeServices: false)
        assertMinimumHeight(
            HistoryWorkspaceView().environmentObject(historyModel),
            maximumHeight: maximumHeight,
            context: "history workspace"
        )

        let settingsModel = AppModel(initializeServices: false)
        assertMinimumHeight(
            SettingsWorkspaceView().environmentObject(settingsModel),
            maximumHeight: maximumHeight,
            context: "settings workspace"
        )
    }

    func testLongWrappingWorkspaceCopyDoesNotExpandPastDetailViewportHeight() {
        let detailViewport = CGSize(width: 900, height: 650)

        let ingestModel = AppModel(initializeServices: false)
        assertFitsHeight(
            IngestWorkspaceView().environmentObject(ingestModel),
            viewport: detailViewport,
            context: "ingest workspace"
        )

        let reviewModel = AppModel(initializeServices: false)
        assertFitsHeight(
            RatingWorkspaceView().environmentObject(reviewModel),
            viewport: detailViewport,
            context: "review workspace"
        )

        let renameModel = AppModel(initializeServices: false)
        assertFitsHeight(
            RenameWorkspaceView().environmentObject(renameModel),
            viewport: detailViewport,
            context: "rename workspace"
        )
    }

    private func assertRootLayout(
        route: WorkspaceRoute,
        viewportSize: CGSize
    ) throws {
        let model = AppModel(initializeServices: false)
        model.route = route
        let harness = makeRootHarness(model: model, viewportSize: viewportSize)
        defer { harness.tearDown() }

        let context = "\(route.rawValue) at \(Int(viewportSize.width))x\(Int(viewportSize.height))"
        assertFiniteSize(harness.proposedFittingSize, context: context)
        XCTAssertLessThanOrEqual(
            harness.proposedFittingSize.height,
            viewportSize.height + 1,
            "RootView reported a taller fitting size than its viewport for \(context)"
        )

        layOut(harness.hostView)
        XCTAssertEqual(
            harness.hostView.bounds.width,
            viewportSize.width,
            accuracy: 1,
            "hosting width changed for \(context)"
        )
        XCTAssertEqual(
            harness.hostView.bounds.height,
            viewportSize.height,
            accuracy: 1,
            "hosting height changed for \(context)"
        )

        let viewportFrame = harness.hostView.bounds
        let navigationSplit = try outerNavigationSplitView(
            in: harness.hostView,
            context: context
        )
        let splitFrame = frame(of: navigationSplit, in: harness.hostView)
        assertInsideViewport(
            splitFrame,
            viewportFrame: viewportFrame,
            context: "outer NavigationSplitView, \(context)"
        )

        let splitCandidates = verticalSplitViews(in: harness.hostView)
        for (index, candidate) in splitCandidates.enumerated() {
            let layoutFrame = frame(of: candidate, in: harness.hostView)
            assertInsideViewport(
                layoutFrame,
                viewportFrame: viewportFrame,
                context: "split candidate \(index) layout, \(context)"
            )
        }

        let paneContainers = navigationSplit.subviews
            .filter { !$0.isHidden }
            .map { view in (view, frame(of: view, in: harness.hostView)) }
            .filter { !$0.0.subviews.isEmpty && $0.1.width > 32 && $0.1.height > 1 }
            .sorted { $0.1.width < $1.1.width }

        guard paneContainers.count >= 2 else {
            XCTFail(
                "outer NavigationSplitView exposed only \(paneContainers.count) non-empty content panes for \(context); sidebar may be collapsed"
            )
            return
        }

        let sidebarPane = paneContainers[0]
        let detailPane = paneContainers[paneContainers.count - 1]
        assertInsideViewport(
            sidebarPane.1,
            viewportFrame: viewportFrame,
            context: "sidebar container, \(context)"
        )
        assertInsideViewport(
            detailPane.1,
            viewportFrame: viewportFrame,
            context: "workspace detail container, \(context)"
        )
        XCTAssertLessThan(
            sidebarPane.1.midX,
            detailPane.1.midX,
            "sidebar and detail pane ordering is invalid for \(context)"
        )
        XCTAssertLessThan(
            sidebarPane.1.width,
            detailPane.1.width,
            "sidebar must remain distinguishable from the detail container for \(context)"
        )
    }

    private func makeRootHarness(
        model: AppModel,
        viewportSize: CGSize
    ) -> HostingHarness {
        let controller = NSHostingController(
            rootView: RootView().environmentObject(model)
        )
        let proposedFittingSize = controller.sizeThatFits(in: viewportSize)
        let origin = NSPoint(x: 100, y: 100)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: viewportSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(origin: .zero, size: viewportSize)
        controller.view.autoresizingMask = [.width, .height]
        window.setContentSize(viewportSize)
        return HostingHarness(
            window: window,
            controller: controller,
            hostView: controller.view,
            proposedFittingSize: proposedFittingSize
        )
    }

    private func layOut(_ view: NSView) {
        // Repeated synchronous layout settles the SwiftUI-to-AppKit split hierarchy without
        // timers, sleeps, accessibility clients, or initialization of production services.
        for _ in 0 ..< 3 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
    }

    private func outerNavigationSplitView(
        in hostView: NSView,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSSplitView {
        let descendants = descendantViews(including: hostView)
        let candidates = verticalSplitViews(in: hostView)
        let topLevelCandidates = candidates.filter { candidate in
            !ancestorSequence(startingAt: candidate.superview).contains { $0 is NSSplitView }
        }
        let viewTypes = descendants
            .prefix(80)
            .map { String(describing: type(of: $0)) }
            .joined(separator: " | ")

        return try XCTUnwrap(
            topLevelCandidates.max { left, right in
                let leftFrame = frame(of: left, in: hostView)
                let rightFrame = frame(of: right, in: hostView)
                if abs(leftFrame.width - rightFrame.width) > 1 {
                    return leftFrame.width < rightFrame.width
                }
                return leftFrame.width * leftFrame.height < rightFrame.width * rightFrame.height
            },
            "missing concrete outer NSSplitView for \(context). View hierarchy: \(viewTypes)",
            file: file,
            line: line
        )
    }

    private func verticalSplitViews(in hostView: NSView) -> [NSSplitView] {
        descendantViews(including: hostView)
            .compactMap { $0 as? NSSplitView }
            .filter { $0.isVertical && $0.subviews.count >= 2 }
    }

    private func ancestorSequence(startingAt view: NSView?) -> [NSView] {
        var result: [NSView] = []
        var current = view
        while let ancestor = current {
            result.append(ancestor)
            current = ancestor.superview
        }
        return result
    }

    private func descendantViews(including root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { descendantViews(including: $0) }
    }

    private func frame(of view: NSView, in hostView: NSView) -> NSRect {
        view.convert(view.bounds, to: hostView)
    }

    private func assertMinimumHeight<Content: View>(
        _ view: Content,
        maximumHeight: CGFloat,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // NavigationSplitView may make a zero-size minimum probe before proposing the final detail
        // width. A vertically fixed wrapping Text can turn that probe into a four-digit minimum
        // height and center the entire split hierarchy outside the real window.
        let controller = NSHostingController(rootView: view)
        let fittingSize = controller.sizeThatFits(in: .zero)
        assertFiniteSize(fittingSize, context: context, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            fittingSize.height,
            0,
            "\(context) returned a negative minimum height",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            fittingSize.height,
            maximumHeight + 1,
            "\(context) reported a \(fittingSize.height)pt minimum height; the app minimum viewport is \(maximumHeight)pt",
            file: file,
            line: line
        )
    }

    private func assertFitsHeight<Content: View>(
        _ view: Content,
        viewport: CGSize,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let controller = NSHostingController(rootView: view)
        let fittingSize = controller.sizeThatFits(in: viewport)
        assertFiniteSize(fittingSize, context: context, file: file, line: line)
        XCTAssertGreaterThan(
            fittingSize.height,
            0,
            "\(context) returned an empty fitting height",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            fittingSize.height,
            viewport.height + 1,
            "\(context) expanded to \(fittingSize.height)pt for a \(viewport.height)pt proposal",
            file: file,
            line: line
        )
    }

    private func assertFiniteSize(
        _ size: CGSize,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            size.width.isFinite && size.height.isFinite,
            "non-finite fitting size \(size) for \(context)",
            file: file,
            line: line
        )
    }

    private func assertInsideViewport(
        _ frame: NSRect,
        viewportFrame: NSRect,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tolerance: CGFloat = 2
        assertFiniteNonemptyFrame(frame, context: context, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            frame.minX,
            viewportFrame.minX - tolerance,
            "frame begins left of viewport for \(context): \(frame), viewport \(viewportFrame)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxX,
            viewportFrame.maxX + tolerance,
            "frame ends right of viewport for \(context): \(frame), viewport \(viewportFrame)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            frame.minY,
            viewportFrame.minY - tolerance,
            "frame begins below viewport for \(context): \(frame), viewport \(viewportFrame)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            frame.maxY,
            viewportFrame.maxY + tolerance,
            "frame ends above viewport for \(context): \(frame), viewport \(viewportFrame)",
            file: file,
            line: line
        )
    }

    private func assertFiniteNonemptyFrame(
        _ frame: NSRect,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            frame.minX.isFinite && frame.minY.isFinite
                && frame.width.isFinite && frame.height.isFinite,
            "non-finite frame \(frame) for \(context)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            frame.width,
            0,
            "empty width for \(context)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            frame.height,
            0,
            "empty height for \(context)",
            file: file,
            line: line
        )
    }
}
