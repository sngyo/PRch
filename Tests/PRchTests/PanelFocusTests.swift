import AppKit
import Testing
@testable import PRch

@Test @MainActor func presentationTakesFocusFromAnAutomaticallySelectedSearchField() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                          styleMask: .titled, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = try #require(window.contentView)
    let search = NSTextField(frame: NSRect(x: 16, y: 100, width: 200, height: 24))
    search.stringValue = "sample"
    content.addSubview(search)
    window.initialFirstResponder = search
    #expect(window.makeFirstResponder(search))
    #expect(window.firstResponder is NSTextView)

    // Reproduce late SwiftUI attachment after AppKit has focused the text field.
    let navigation = PanelKeyHandler.KeyView(handle: { _, _ in false })
    defer { navigation.stop() }
    content.addSubview(navigation)
    #expect(window.initialFirstResponder === navigation)
    #expect(window.firstResponder === navigation)

    // Deliberately entering search still works and ordinary view updates leave it alone.
    #expect(window.makeFirstResponder(search))
    navigation.startsWithNavigation = true
    #expect(window.firstResponder is NSTextView)

    // Reopening a panel returns to navigation without clearing the search query.
    #expect(PanelKeyHandler.focusNavigation(in: window))
    #expect(window.firstResponder === navigation)
    #expect(search.stringValue == "sample")
    #expect(window.makeFirstResponder(search))
    #expect(window.firstResponder is NSTextView)
}

@Test @MainActor func settingsAndDetachedPanelsDoNotCaptureFocus() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                          styleMask: .titled, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = try #require(window.contentView)
    let field = NSTextField(frame: NSRect(x: 16, y: 100, width: 200, height: 24))
    content.addSubview(field)
    window.initialFirstResponder = field
    #expect(window.makeFirstResponder(field))
    let navigation = PanelKeyHandler.KeyView(handle: { _, _ in false }, startsWithNavigation: false)
    defer { navigation.stop() }
    content.addSubview(navigation)
    #expect(!PanelKeyHandler.focusNavigation(in: window))
    #expect(window.initialFirstResponder === field)
    #expect(window.firstResponder is NSTextView)

    navigation.startsWithNavigation = true
    #expect(window.initialFirstResponder === navigation)
    #expect(PanelKeyHandler.focusNavigation(in: window))
    navigation.startsWithNavigation = false
    #expect(window.initialFirstResponder == nil)
    #expect(!PanelKeyHandler.focusNavigation(in: window))
    #expect(window.makeFirstResponder(field))
    navigation.startsWithNavigation = true
    navigation.removeFromSuperview()
    #expect(window.initialFirstResponder == nil)
    #expect(!PanelKeyHandler.focusNavigation(in: window))
    #expect(window.firstResponder is NSTextView)
}
