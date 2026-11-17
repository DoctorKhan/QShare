import AppKit
import QuickShareKit
import SwiftUI

/// A small floating window in the top-right corner that shows incoming requests and
/// transfers in progress. It exists so that accepting a transfer never depends on
/// notification permission or Focus settings.
final class TransferPanelController {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private let model: AppModel
    private var panel: NSPanel?
    private var hosting: NSHostingView<TransferPanelView>?

    init(model: AppModel) {
        self.model = model
    }

    /// Shows, resizes or hides the panel to match `model.panelTransfers`.
    func refresh() {
        // Let SwiftUI apply the state change first so the measured size is current.
        DispatchQueue.main.async { self.layout() }
    }

    private func layout() {
        guard !model.panelTransfers.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12,
            width: size.width, height: size.height)
        panel.setFrame(frame, display: true, animate: panel.isVisible)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: TransferPanelView(model: model))
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }
}

struct TransferPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.panelTransfers) { transfer in
                HStack(alignment: .top, spacing: 0) {
                    TransferRow(transfer: transfer, model: model)
                    if transfer.state.isFinished {
                        Button {
                            model.dismissFromPanel(transfer)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                        .help("Dismiss")
                    }
                }
                if transfer.id != model.panelTransfers.last?.id {
                    Divider()
                }
            }
        }
        .frame(width: 360)
        .onHover { model.panelHovered = $0 }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}
