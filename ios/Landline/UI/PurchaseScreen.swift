import SwiftUI

extension AccessStatus {
    var label: String {
        switch self {
        case .checking: "CHECKING PURCHASE"
        case .trialAvailable: "7 DAYS FREE"
        case .trial: "TRIAL ACTIVE"
        case .expired: "TRIAL ENDED"
        case .unlocked: "UNLOCKED"
        }
    }
}

struct PurchaseScreen: View {
    var leading: HeaderLeading = .back
    var indexColumn: Binding<NavigationSplitViewVisibility>?
    @Environment(Purchases.self) private var purchases

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                offer(status: purchases.access.status(at: context.date))
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(Theme.Metric.gutter)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.panel.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .toolbar(.hidden, for: .navigationBar)
        .task { await purchases.loadProducts() }
    }

    @ViewBuilder private var header: some View {
        if let indexColumn {
            HStack(spacing: 0) {
                HeaderLeadingCell(kind: .index(showing: indexColumn.wrappedValue != .detailOnly)) {
                    withAnimation(Theme.Motion.state) {
                        indexColumn.wrappedValue = indexColumn.wrappedValue == .detailOnly ? .all : .detailOnly
                    }
                }
                Text("LANDLINE").llTitle().padding(Theme.Metric.gutter)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Hairline() }
        } else {
            SettingHeader(title: "LANDLINE", annotation: "TRIAL & PURCHASE", leading: leading)
        }
    }

    private func offer(status: AccessStatus) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 5) {
            MicroLabel(status.label, color: status == .unlocked ? Theme.ok : Theme.accent)
            Text(title(status)).llTitle().fixedSize(horizontal: false, vertical: true)
            Text(disclosure(status)).llProse().fixedSize(horizontal: false, vertical: true)
            Hairline()

            if status != .unlocked {
                Text("Every host. Every terminal feature.").llValueStrong()
                Text("Requires Tailscale on your devices and the free landlined daemon on each computer.")
                    .llProse().fixedSize(horizontal: false, vertical: true)

                if let product = purchases.unlockProduct {
                    Text("7 days free. Then \(product.displayPrice), paid once if you choose to continue.")
                        .llProse().fixedSize(horizontal: false, vertical: true)
                    Text("No subscription. No automatic charge.").llProse()
                    if status == .trialAvailable {
                        Button("START 7-DAY FREE TRIAL") { Task { await purchases.startTrial() } }
                            .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                            .disabled(!purchases.canStartTrial || purchases.isBusy)
                    }
                    Button("UNLOCK LANDLINE · \(product.displayPrice)") { Task { await purchases.unlock() } }
                        .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                        .disabled(purchases.isBusy || status == .checking)
                } else {
                    Text(purchases.isLoadingProducts
                         ? "Connecting to the App Store…"
                         : "Connect to the App Store to see your local price and start a trial or purchase.")
                        .llProse().fixedSize(horizontal: false, vertical: true)
                    Button("TRY AGAIN") { Task { await purchases.reload() } }
                        .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                        .disabled(purchases.isBusy || purchases.isLoadingProducts)
                }
            }

            Hairline()
            Button("RESTORE PURCHASES") { Task { await purchases.restore() } }
                .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                .disabled(purchases.isBusy)
            if purchases.isBusy { MicroLabel("WAITING FOR THE APP STORE") }
            if let message = purchases.message {
                Text(message).llProse().fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Metric.gutter) {
                Link("PRIVACY", destination: URL(string: "https://github.com/mhrsntrk/landline/blob/main/docs/PRIVACY.md")!)
                Link("SUPPORT", destination: URL(string: "https://github.com/mhrsntrk/landline/issues")!)
            }
            .llValue(Theme.accent)
        }
        .padding(.vertical, Theme.Metric.grid * 4)
    }

    private func title(_ status: AccessStatus) -> String {
        switch status {
        case .checking: "Checking your access."
        case .trialAvailable: "Your machines, on the line."
        case .trial(let end): "Trial until \(end.formatted(date: .abbreviated, time: .shortened))"
        case .expired: "Keep the line open."
        case .unlocked: "Landline is yours."
        }
    }

    private func disclosure(_ status: AccessStatus) -> String {
        switch status {
        case .unlocked:
            "Every terminal feature is unlocked. Existing Landline users keep full access."
        case .checking:
            "Checking your App Store purchases. Your saved hosts, settings and snippets are safe."
        case .expired:
            "Your seven-day trial has ended. Unlock Landline to connect again. Your hosts, settings and snippets stay saved. Remote sessions are detached, never killed by trial expiry; your daemon's usual idle timeout still applies."
        case .trialAvailable, .trial:
            "Try every feature for seven days from when you start. After the trial, terminal connections require the one-time unlock. Your hosts, settings and snippets stay saved. Remote sessions are detached at expiry and follow your daemon's usual idle timeout."
        }
    }
}
