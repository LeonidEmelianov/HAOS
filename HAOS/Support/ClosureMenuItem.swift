import AppKit

/// An `NSMenuItem` that runs a closure when selected, so menus (and pop-up
/// buttons, which dispatch the selected item's own action) can be built
/// declaratively instead of scattering `@objc` target/action methods around.
///
/// The item is its own target. AppKit holds targets weakly, but the owning
/// menu retains the item, which in turn keeps the closure alive.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    /// Creates a menu item titled `title` that runs `handler` when selected.
    /// `keyEquivalent` uses the Command modifier, as usual for menu items.
    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem does not support NSCoder")
    }

    @objc private func invoke() {
        handler()
    }
}
