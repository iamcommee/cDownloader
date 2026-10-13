import AppKit
import Testing
@testable import cDownloader

/// The line between the sidebar and the list must not flash when the window reopens: the divider's see-through strip
/// blends within the window, while the columns keep their materials. The views are stand-ins built like the real
/// split view, since a test process gets a newer macOS layout than the app.
@MainActor
@Suite struct SidebarDividerTests {
    /// A side-by-side split view like the main window's: a see-through sidebar column, a list column, and a divider
    /// part (not one of the columns) holding a one-point see-through strip.
    @MainActor
    struct StandIn {
        let split = NSSplitView()
        let sidebarMaterial = NSVisualEffectView()
        let listMaterial = NSVisualEffectView()
        let dividerPart = NSView()
        let dividerStrip = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 1, height: 400))

        init(vertical: Bool = true, stripOneLevelDown: Bool = false, withDivider: Bool = true) {
            split.isVertical = vertical
            split.arrangesAllSubviews = false
            sidebarMaterial.material = .sidebar
            sidebarMaterial.blendingMode = .behindWindow
            listMaterial.blendingMode = .withinWindow
            for material in [sidebarMaterial, listMaterial] {
                let column = NSView()
                column.addSubview(material)
                split.addArrangedSubview(column)
            }
            dividerStrip.material = .sidebar
            dividerStrip.blendingMode = .behindWindow
            guard withDivider else { return }
            if stripOneLevelDown {
                let holder = NSView()
                holder.addSubview(dividerStrip)
                dividerPart.addSubview(holder)
            } else {
                dividerPart.addSubview(dividerStrip)
            }
            split.addSubview(dividerPart)
        }
    }

    // MARK: SD-01 the divider strip switches, the columns stay, a second run changes nothing

    @Test("SD-01 divider strip blends within the window, columns untouched, repeat run harmless")
    func sd01_dividerStripSwitches() {
        let tree = StandIn()
        let columns = tree.split.arrangedSubviews

        SidebarDivider.blendWithinWindow(in: tree.split)
        #expect(tree.dividerStrip.blendingMode == .withinWindow)
        // Guards: the columns keep their own materials.
        #expect(tree.sidebarMaterial.blendingMode == .behindWindow)
        #expect(tree.sidebarMaterial.material == .sidebar)
        #expect(tree.listMaterial.blendingMode == .withinWindow)
        #expect(tree.split.arrangedSubviews == columns)

        SidebarDivider.blendWithinWindow(in: tree.split)
        #expect(tree.dividerStrip.blendingMode == .withinWindow)
        #expect(tree.sidebarMaterial.blendingMode == .behindWindow)
        #expect(tree.listMaterial.blendingMode == .withinWindow)
    }

    // MARK: CR-01 applied when the view lands in a window, however late

    @Test("CR-01 the fix switches the strip once its view is placed in a window, even well after it was made")
    func cr01_appliesWhenPlacedInWindow() async {
        let tree = StandIn()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(tree.split)
        let anchor = SidebarDividerFix.Anchor()
        await nextMainTurn()
        #expect(tree.dividerStrip.blendingMode == .behindWindow)

        window.contentView?.addSubview(anchor)
        await nextMainTurn()
        #expect(tree.dividerStrip.blendingMode == .withinWindow)
        #expect(tree.sidebarMaterial.blendingMode == .behindWindow)
    }

    /// Waits until the work already queued for the main thread has run.
    private func nextMainTurn() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    // MARK: SD-02 found at any depth

    enum Nesting: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case splitViewThreeLevelsDown = "split view nested three plain views deep"
        case stripOneLevelDown = "strip one level down inside the divider part"
        case splitViewInsideAnotherColumn = "two split views, one inside the other's list column"
        var testDescription: String { rawValue }
    }

    @Test("SD-02 divider strips are found at any depth", arguments: Nesting.allCases)
    func sd02_foundAtAnyDepth(_ nesting: Nesting) {
        let root = NSView()
        switch nesting {
        case .splitViewThreeLevelsDown:
            let tree = StandIn()
            var parent = root
            for _ in 0..<3 {
                let level = NSView()
                parent.addSubview(level)
                parent = level
            }
            parent.addSubview(tree.split)
            SidebarDivider.blendWithinWindow(in: root)
            #expect(tree.dividerStrip.blendingMode == .withinWindow)
            #expect(tree.sidebarMaterial.blendingMode == .behindWindow)
        case .stripOneLevelDown:
            let tree = StandIn(stripOneLevelDown: true)
            root.addSubview(tree.split)
            SidebarDivider.blendWithinWindow(in: root)
            #expect(tree.dividerStrip.blendingMode == .withinWindow)
            #expect(tree.sidebarMaterial.blendingMode == .behindWindow)
        case .splitViewInsideAnotherColumn:
            let outer = StandIn(), inner = StandIn()
            outer.split.arrangedSubviews[1].addSubview(inner.split)
            root.addSubview(outer.split)
            SidebarDivider.blendWithinWindow(in: root)
            #expect(outer.dividerStrip.blendingMode == .withinWindow)
            #expect(inner.dividerStrip.blendingMode == .withinWindow)
            #expect(outer.sidebarMaterial.blendingMode == .behindWindow)
            #expect(inner.sidebarMaterial.blendingMode == .behindWindow)
        }
    }

    // MARK: SD-03 everything else is left alone (guards)

    enum LeftAlone: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case stackedSplitView = "split view stacked top to bottom"
        case noSplitView = "no split view"
        case emptyView = "empty view"
        case noDividerPart = "side-by-side split view with columns only"
        case dividerAlreadyWithinWindow = "divider part already blending within the window"
        var testDescription: String { rawValue }
    }

    @Test("SD-03 views outside side-by-side dividers keep their materials", arguments: LeftAlone.allCases)
    func sd03_leftAlone(_ shape: LeftAlone) {
        let root = NSView()
        var watched: [(NSVisualEffectView, NSVisualEffectView.BlendingMode)] = []
        switch shape {
        case .stackedSplitView:
            let tree = StandIn(vertical: false)
            root.addSubview(tree.split)
            watched = [(tree.dividerStrip, .behindWindow), (tree.sidebarMaterial, .behindWindow)]
        case .noSplitView:
            let material = NSVisualEffectView()
            material.blendingMode = .behindWindow
            let holder = NSView()
            holder.addSubview(material)
            root.addSubview(holder)
            watched = [(material, .behindWindow)]
        case .emptyView:
            break
        case .noDividerPart:
            let tree = StandIn(withDivider: false)
            root.addSubview(tree.split)
            watched = [(tree.sidebarMaterial, .behindWindow), (tree.listMaterial, .withinWindow)]
        case .dividerAlreadyWithinWindow:
            let tree = StandIn()
            tree.dividerStrip.blendingMode = .withinWindow
            tree.dividerPart.addSubview(NSView())
            root.addSubview(tree.split)
            watched = [(tree.dividerStrip, .withinWindow), (tree.sidebarMaterial, .behindWindow)]
        }

        SidebarDivider.blendWithinWindow(in: root)
        for (material, expected) in watched {
            #expect(material.blendingMode == expected)
        }
    }
}
