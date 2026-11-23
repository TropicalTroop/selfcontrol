import AppKit
import SwiftUI

/// Reports whether the window containing this view can be seen (open, not minimized, not fully
/// covered). SwiftUI keeps a closed window's views alive and keeps updating them, so the main
/// window and menu-bar popup use this to render nothing while hidden.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { visible in if isVisible != visible { isVisible = visible } }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = { visible in if isVisible != visible { isVisible = visible } }
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    self?.report(closing: note.name == NSWindow.willCloseNotification)
                })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            let visible = !closing && (window?.occlusionState.contains(.visible) ?? false)
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
