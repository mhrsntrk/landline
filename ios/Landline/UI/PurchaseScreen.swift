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

    /// The host list's banner: the trial as a countdown, so its end is never
    /// a surprise.
    func bannerLabel(now: Date) -> String {
        switch self {
        case .trial(let end): "TRIAL · \(TrialCountdown.remaining(until: end, now: now))"
        default: label
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
                offer(status: purchases.access.status(at: context.date), now: context.date)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(Theme.Metric.gutter)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.panel.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await purchases.loadProducts()
            // Someone already mid-trial (a restore, or a trial started before
            // reminders existed) is asked here, next to the switch that
            // explains what the notifications are for.
            if case .trial = purchases.access.status(), purchases.remindersEnabled {
                await purchases.askForReminderPermission()
            }
        }
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

    private func offer(status: AccessStatus, now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 5) {
            MicroLabel(status.bannerLabel(now: now),
                       color: status == .unlocked ? Theme.ok : status == .expired ? Theme.warn : Theme.accent)
            Text(title(status, now: now)).llTitle().fixedSize(horizontal: false, vertical: true)
            if status != .unlocked {
                // The line that sells it: people who reach for a terminal app
                // have been burned by subscriptions, and this one is not.
                Text("One-time purchase.\nNo subscription.")
                    .llTitle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(disclosure(status)).llProse().fixedSize(horizontal: false, vertical: true)
            Hairline()

            if status != .unlocked {
                if let product = purchases.unlockProduct {
                    actions(status: status, product: product)
                } else {
                    Text(purchases.isLoadingProducts
                         ? "Connecting to the App Store…"
                         : "Connect to the App Store to see your local price and start a trial or purchase.")
                        .llProse().fixedSize(horizontal: false, vertical: true)
                    Button("TRY AGAIN") { Task { await purchases.reload() } }
                        .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                        .disabled(purchases.isBusy || purchases.isLoadingProducts)
                }
                Hairline()
            }

            Button("RESTORE PURCHASES") { Task { await purchases.restore() } }
                .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                .disabled(purchases.isBusy)
            if purchases.isBusy { MicroLabel("WAITING FOR THE APP STORE") }
            if let message = purchases.message {
                Text(message).llProse().fixedSize(horizontal: false, vertical: true)
            }
            if status != .unlocked {
                Text("Requires Tailscale on your devices and the free landlined daemon on each computer.")
                    .llProse(Theme.inkMuted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Metric.gutter) {
                Link("PRIVACY", destination: URL(string: "https://github.com/mhrsntrk/landline/blob/main/docs/PRIVACY.md")!)
                Link("SUPPORT", destination: URL(string: "https://github.com/mhrsntrk/landline/issues")!)
            }
            .llValue(Theme.accent)
        }
        .padding(.vertical, Theme.Metric.grid * 4)
    }

    /// One primary action per state: start the trial when there is one to
    /// start, otherwise buy. Buying stays available during the trial.
    @ViewBuilder
    private func actions(status: AccessStatus, product: PurchaseProduct) -> some View {
        @Bindable var purchases = purchases
        switch status {
        case .trialAvailable:
            Button("START 7-DAY FREE TRIAL") { Task { await purchases.startTrial() } }
                .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                .disabled(!purchases.canStartTrial || purchases.isBusy)
            Text("Landline will remind you two days and one day before the trial ends. You can switch them off on this screen at any time.")
                .llProse().fixedSize(horizontal: false, vertical: true)
            Button("UNLOCK NOW · \(product.displayPrice)") { Task { await purchases.unlock() } }
                .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                .disabled(purchases.isBusy)
        case .trial:
            Button("UNLOCK LANDLINE · \(product.displayPrice)") { Task { await purchases.unlock() } }
                .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                .disabled(purchases.isBusy)
            InstrumentToggle(
                title: "REMIND ME BEFORE IT ENDS",
                isOn: $purchases.remindersEnabled,
                note: !purchases.remindersEnabled
                    ? "No reminders. The host list still shows the days left."
                    : purchases.remindersAllowedBySystem
                        ? "Two notifications: two days and one day before the trial ends."
                        : "Notifications are off for Landline in iOS Settings, so these cannot arrive.")
        default:
            Button("UNLOCK LANDLINE · \(product.displayPrice)") { Task { await purchases.unlock() } }
                .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                .disabled(purchases.isBusy || status == .checking)
        }
    }

    private func title(_ status: AccessStatus, now: Date) -> String {
        switch status {
        case .checking: "Checking your access."
        case .trialAvailable: "Your machines, on the line."
        case .trial(let end): "Trial: \(TrialCountdown.remaining(until: end, now: now).lowercased())."
        case .expired: "Your trial has ended."
        case .unlocked: "Landline is yours."
        }
    }

    private func disclosure(_ status: AccessStatus) -> String {
        let price = purchases.unlockProduct?.displayPrice
        let then = price.map { "Then \($0), paid once, if you keep it." } ?? "Then a one-time purchase if you keep it."
        switch status {
        case .unlocked:
            return "Every terminal feature is unlocked. Existing Landline users keep full access."
        case .checking:
            return "Checking your App Store purchases. Your saved hosts, settings and snippets are safe."
        case .expired:
            return "Your hosts, settings and snippets are all kept. Unlock once to connect again, on every machine."
        case .trialAvailable:
            return "Every host and every feature, free for seven days from when you start. \(then) No automatic charge. After the trial, connecting requires the unlock; your hosts and settings stay saved."
        case .trial(let end):
            return "Every feature until \(end.formatted(date: .abbreviated, time: .shortened)). \(then) No automatic charge. Your hosts and settings stay saved either way."
        }
    }
}
