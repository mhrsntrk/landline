import SwiftUI
import SwiftTerm

/// Reference handle the screen keeps so it can push bytes into the terminal
/// and read its current grid size.
final class TerminalController {
    fileprivate weak var terminalView: TerminalView?

    func feed(_ data: Data) {
        terminalView?.feed(byteArray: [UInt8](data)[...])
    }

    var cols: Int { terminalView?.getTerminal().cols ?? 80 }
    var rows: Int { terminalView?.getTerminal().rows ?? 24 }
}

/// UIViewRepresentable wrapper around SwiftTerm's TerminalView.
/// Rendering and ANSI emulation stay entirely inside SwiftTerm
/// (SCOPE.md 8: do not hand-roll ANSI emulation).
struct SwiftTermView: UIViewRepresentable {
    let controller: TerminalController
    /// Bytes the user typed (or pasted) that should go to the PTY.
    var onSend: (Data) -> Void
    /// The terminal grid was re-laid-out to a new size.
    var onResize: (_ cols: Int, _ rows: Int) -> Void

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        view.nativeBackgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        view.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        controller.terminalView = view
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.onSend = onSend
        context.coordinator.onResize = onResize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSend: onSend, onResize: onResize)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onSend: (Data) -> Void
        var onResize: (_ cols: Int, _ rows: Int) -> Void

        init(onSend: @escaping (Data) -> Void, onResize: @escaping (_ cols: Int, _ rows: Int) -> Void) {
            self.onSend = onSend
            self.onResize = onResize
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onSend(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
