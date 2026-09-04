import SwiftUI
import UIKit

// The one screen the product exists for. The terminal fills it; everything else
// is annotation drawn around the plate (DESIGN.md): a thin measured header, a
// keypad, and a status band that appears only when the session is not simply
// running. No cards, no shadows, no spinner floating in the middle of content.
//
// Terminal bytes never pass through this view. `Connection.onStdout` hands them
// straight to `TerminalController`, which buffers them and feeds SwiftTerm from
// a display link. Nothing in this file re-renders because output arrived.

struct TerminalScreen: View {
    let host: Host

    @Environment(HostStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var connection = Connection()
    @State private var controller = TerminalController()
    @State private var state: Connection.State = .idle
    @State private var attached: AttachedResp?
    /// Wall clock at the moment the session stopped, so the age readout freezes
    /// instead of counting a session that is no longer running.
    @State private var sessionEndedAt: Date?

    /// Live grid size, updated when SwiftTerm re-lays-out. A rare event, so
    /// letting it invalidate the header costs nothing.
    @State private var cols = 80
    @State private var rows = 24

    /// The single authored motion moment: 0 to 1 draws the terminal viewport's
    /// registration marks in as the session attaches.
    @State private var marksProgress: CGFloat = 0

    @State private var ctrlLatched = false
    @State private var altLatched = false

    // Unlock
    @State private var typedSecret = ""
    @State private var unlockAttemptsLeft = 0
    /// True once the Keychain secret was tried on this connection, so a second
    /// NEED_UNLOCK falls through to the manual prompt instead of looping.
    @State private var triedKeychainSecret = false
    @FocusState private var secretFocused: Bool

    /// Re-read when the app returns to the foreground, so a host set to follow
    /// the system picks up a change made while the app was away.
    @State private var systemIsLight = SystemAppearance.isLight

    /// The host as the store currently holds it, not as it looked when this
    /// screen was pushed.
    ///
    /// `host` is a `let` snapshot copied into `openedHost` at tap time, so an
    /// edit made after that never reaches this view: the terminal kept
    /// rendering the previous font, which reads as the picker being inverted
    /// because every change appears one step behind.
    private var liveHost: Host {
        store.hosts.first { $0.id == host.id } ?? host
    }

    private var palette: TerminalPalette {
        TerminalPalette.resolve(scheme: liveHost.colorScheme, systemIsLight: systemIsLight)
    }

    /// The face this host renders in. Empty is the bundled Nerd Font, and a
    /// family whose configuration profile was removed while the app was away
    /// resolves back to it rather than to some proportional substitute — see
    /// `TerminalFont.font(family:size:bold:)`.
    private var fontFamily: String { liveHost.fontFamily }

    /// Live point size. Held in state rather than read off `host` every time
    /// because the pinch gesture changes it mid-session and writes it back to
    /// the store; `host` is the copy this screen was pushed with and would go
    /// stale the moment a pinch landed.
    @State private var fontSize: CGFloat = TerminalFont.defaultSize

    var body: some View {
        VStack(spacing: 0) {
            header
            terminalRegion
            KeyBar(ctrlLatched: $ctrlLatched, altLatched: $altLatched) { bytes in
                sendUserInput(Data(bytes))
            }
        }
        .background(Theme.ground)
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear { wireUpAndConnect() }
        .onDisappear { connection.disconnect(sendDetach: true) }
        // A font or palette edit must reach the terminal the moment it is
        // saved, not on the next foregrounding.
        .onChange(of: fontFamily) { _, _ in applyFont() }
        .onChange(of: liveHost.fontSize) { _, newValue in
            let resolved = TerminalFont.size(forHost: liveHost.fontSize)
            if fontSize != resolved {
                fontSize = resolved
                applyFont()
            }
            _ = newValue
        }
        .onChange(of: liveHost.colorScheme) { _, _ in controller.apply(palette: palette) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // PROTOCOL.md 6: any transport drop is already an implicit
                // DETACH, so this is only a courtesy that lets the daemon free
                // the socket a few seconds earlier. Correctness never depends
                // on it — the session id in the store is what resumes.
                connection.disconnect(sendDetach: true)
            case .active:
                systemIsLight = SystemAppearance.isLight
                controller.apply(palette: palette)
                // Re-asserted on the way back in for the same reason the palette
                // is: a configuration profile can be added or removed while the
                // app is in the background, which changes what this host's
                // chosen family resolves to.
                applyFont()
                if case .closed = state { reconnect() }
                if case .idle = state { reconnect() }
            default:
                break
            }
        }
        .task(id: perfLoggingEnabled) { await perfLoggingLoop() }
    }

    // MARK: - Header
    //
    // One measured row plus an annotation strip. Everything here is mono with
    // tabular figures, because all of it is machine data.

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                backControl
                HStack(spacing: Theme.Metric.grid * 2) {
                    StatusSquare(level: statusLevel)
                    Text(liveHost.displayName)
                        .llValueStrong()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Metric.grid * 2)
                    measured(label: "GEOM", value: "\(cols)×\(rows)")
                    measured(label: "AGE", value: nil) {
                        SessionAgeReadout(createdAt: sessionCreatedAt, endedAt: sessionEndedAt)
                    }
                }
                .padding(.trailing, Theme.Metric.gutter)
            }
            .frame(height: Theme.Metric.hitTarget + Theme.Metric.grid * 2)

            MicroLabel(annotation)
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.bottom, Theme.Metric.grid * 2)
                .llMeasuredColumn()
                .animation(Theme.Motion.state, value: annotation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Hairline() }
        .overlay(alignment: .bottomLeading) {
            // This screen's one tick scale, standing on the rule that divides
            // the header from the terminal, marking the terminal as the live
            // region (DESIGN.md: at most one per screen).
            //
            // Drawn inside the header's own bounds on purpose. Nudging it past
            // the edge with `.offset` renders nothing: the terminal region is
            // the next sibling in the VStack, so it paints over anything that
            // spills across the boundary.
            TickScale(edge: .horizontal)
                .padding(.leading, Theme.Metric.gutter)
        }
    }

    private var backControl: some View {
        Button {
            dismiss()
        } label: {
            Text("\u{25C0}")
                .font(.llValue)
                .frame(width: Theme.Metric.hitTarget)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(BackCellStyle())
        .accessibilityLabel(Text("back to the index"))
    }

    /// A micro-caps label stacked over its value, the measured-column pattern.
    private func measured<V: View>(
        label: String,
        value: String?,
        @ViewBuilder content: () -> V = { EmptyView() }
    ) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            MicroLabel(label)
            if let value {
                Text(value).llValue()
            } else {
                content()
            }
        }
        .llMeasuredColumn()
    }

    /// The annotation strip: what state the session is in, and the two facts the
    /// daemon reported about it. Never invented by the app (PRODUCT.md).
    private var annotation: String {
        var parts: [String] = [stateWord]
        if let attached {
            parts.append((attached.shell as NSString).lastPathComponent)
            parts.append("SESSION " + String(attached.sessionID.prefix(8)))
        }
        // The face actually in use, read back rather than assumed. This path
        // has shipped two bugs where the app believed one font was applied and
        // the screen drew another, neither visible except by reading
        // letterforms off a photograph.
        if !controller.resolvedFontFamily.isEmpty {
            // Requested beside applied, plus whether the applied face can draw
            // ASCII at all. Three facts instead of one, because a single name
            // could not distinguish stale state from a font that resolves but
            // has no glyphs.
            parts.append("REQ " + controller.requestedFontFamily.uppercased())
            parts.append("GOT " + controller.resolvedFontFamily.uppercased())
            // What is drawing the glyphs, which is the only claim that matters.
            if !controller.drawingFontFamily.isEmpty,
                controller.drawingFontFamily != controller.resolvedFontFamily {
                parts.append("DRAWN BY " + controller.drawingFontFamily.uppercased())
            }
            if !controller.primaryHasGlyphs { parts.append("NO GLYPHS") }
        }
        return parts.joined(separator: " / ")
    }

    private var stateWord: String {
        switch state {
        case .idle: return "IDLE"
        case .connecting: return "CONNECTING"
        case .attaching: return "ATTACHING"
        case .needsUnlock: return "LOCKED"
        case .live: return "LIVE"
        case .closed: return closedIsError ? "ERROR" : "CLOSED"
        }
    }

    private var statusLevel: StatusSquare.Level {
        switch state {
        case .live: return .connected
        case .connecting, .attaching, .needsUnlock: return .connecting
        case .closed: return closedIsError ? .failed : .offline
        case .idle: return .offline
        }
    }

    private var sessionCreatedAt: Date? {
        attached.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) }
    }

    // MARK: - Terminal region

    private var terminalRegion: some View {
        ZStack(alignment: .bottom) {
            SwiftTermView(controller: controller,
                          palette: palette,
                          fontFamily: fontFamily,
                          fontSize: fontSize)
                // The ring the registration marks live in, so a 6pt bracket
                // never lands on the first glyph cell.
                .padding(Theme.Metric.grid)

            RegistrationMarks(progress: marksProgress)

            stateBand
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: palette.background))
        .clipped()
    }

    // MARK: - State bands
    //
    // A band is a full-bleed shelf across the bottom of the plate, delimited by
    // a hairline. It is not a card and it never covers the middle of the output.

    @ViewBuilder
    private var stateBand: some View {
        switch state {
        case .idle, .connecting, .attaching:
            band {
                HStack(spacing: Theme.Metric.grid * 3) {
                    MicroLabel(stateWord, color: Theme.warn)
                    Text(endpointLabel)
                        .llValue(Theme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
            }
        case .needsUnlock:
            band { unlockContent }
        case .live:
            EmptyView()
        case .closed(let reason):
            band { closedContent(reason: reason) }
        }
    }

    private func band<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            Hairline()
            content()
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.bottom, Theme.Metric.grid * 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .transition(.opacity)
        .animation(Theme.Motion.state, value: stateWord)
    }

    private var unlockContent: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            HStack(spacing: Theme.Metric.grid * 3) {
                MicroLabel("UNLOCK REQUIRED", color: Theme.warn)
                Spacer(minLength: 0)
                if unlockAttemptsLeft > 0 {
                    MicroLabel("\(unlockAttemptsLeft) LEFT")
                }
            }
            HStack(spacing: Theme.Metric.grid * 3) {
                SecureField("", text: $typedSecret)
                    .textContentType(.password)
                    .font(.llValue)
                    .foregroundStyle(Theme.inkBright)
                    .tint(Theme.accent)
                    .focused($secretFocused)
                    .submitLabel(.go)
                    .onSubmit(submitSecret)
                    .frame(minHeight: Theme.Metric.hitTarget)
                    .overlay(alignment: .bottom) { Hairline(color: Theme.accent) }
                Button("UNLOCK", action: submitSecret)
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                    .disabled(typedSecret.isEmpty)
            }
        }
    }

    private func closedContent(reason: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            MicroLabel(closedIsError ? "ERROR" : "CLOSED",
                       color: closedIsError ? Theme.alertText : Theme.inkMuted)
            Text(recoveryText(for: reason))
                .llProse(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Metric.grid * 3) {
                Button("RECONNECT") { reconnect() }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                Button("INDEX") { dismiss() }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                Spacer(minLength: 0)
            }
        }
    }

    private var endpointLabel: String {
        "\(liveHost.hostname):\(liveHost.port)"
    }

    /// Turns a transport failure into one sentence. Foundation prefixes URL
    /// errors with "The operation couldn't be completed.", which says nothing
    /// and pushes the part that matters onto a second line.
    private static func humanise(_ reason: String) -> String {
        var text = reason
        for boilerplate in ["The operation couldn\u{2019}t be completed.",
                            "The operation couldn't be completed."] {
            if let range = text.range(of: boilerplate) {
                text.removeSubrange(range)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a trailing "(NSPOSIXErrorDomain error 57.)" style qualifier.
        if let paren = text.range(of: " (", options: .backwards), text.hasSuffix(")") {
            text = String(text[text.startIndex..<paren.lowerBound])
        }
        guard !text.isEmpty else { return "The connection dropped." }
        let sentence = "\(text.prefix(1).uppercased())\(text.dropFirst())"
        return sentence.hasSuffix(".") ? sentence : sentence + "."
    }

    /// Errors the daemon named come through as `CODE: message` (PROTOCOL.md);
    /// a plain transport close does not.
    private var closedIsError: Bool {
        guard case .closed(let reason) = state else { return false }
        guard let code = reason.split(separator: ":", maxSplits: 1).first else { return false }
        return !code.isEmpty && code.allSatisfy { $0.isUppercase || $0 == "_" }
    }

    /// Problem plus recovery, in sentences a human wrote. Prose is the one place
    /// this app is allowed to leave the mono face.
    private func recoveryText(for reason: String) -> String {
        let parts = reason.split(separator: ":", maxSplits: 1)
        guard closedIsError, let code = parts.first else {
            return "\(Self.humanise(reason)) Reconnect to try again."
        }
        switch String(code) {
        case ErrCode.sessionGone:
            return "That session is gone from the daemon. Reconnect to start a fresh one."
        case ErrCode.sessionReplaced:
            return "Another client attached to this session, so this one was dropped. Reconnect to take it back."
        case ErrCode.unauthorized:
            return "The daemon did not recognise your tailnet login. Check `allowed_logins` in its config.toml."
        case ErrCode.lockedOut:
            return "Too many wrong unlock secrets. The daemon is refusing attempts until its cooling period ends."
        case ErrCode.tooManySessions:
            return "The daemon is already running its maximum number of sessions. Close one, or raise `max_sessions`."
        case ErrCode.spawnFailed:
            return "The daemon could not start a shell. Check the `shell` and `default_cmd` keys in its config.toml."
        case ErrCode.protocolVersion:
            let detail = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            return "This app speaks a protocol version the daemon does not. Update whichever is older (\(detail))."
        case ErrCode.clientTooSlow:
            return "The phone could not keep up with the output and the daemon dropped it. Reconnect to reattach."
        default:
            let detail = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : reason
            return detail.isEmpty ? "The session closed." : detail
        }
    }

    // MARK: - Font
    //
    // Request-on-use. A family installed by a provider app (iFont and friends)
    // is not automatically available to this process — CoreText withholds it
    // until the app calls `CTFontManagerRequestFonts` — and that grant does not
    // necessarily outlive the launch it was made in. So a stored family that no
    // longer resolves gets one request, once per family per launch, before the
    // terminal settles for the bundled face. Falling back silently is what makes
    // it look like the app forgot the setting.

    private func applyFont() {
        controller.apply(fontFamily: fontFamily, size: fontSize)
        TerminalFont.requestIfUnresolved(family: fontFamily) { becameAvailable in
            guard becameAvailable else { return }
            controller.apply(fontFamily: fontFamily, size: fontSize)
        }
    }

    // MARK: - Connection plumbing

    private func wireUpAndConnect() {
        fontSize = TerminalFont.size(forHost: liveHost.fontSize)
        applyFont()
        controller.onFontSizeChange = { newSize in
            fontSize = newSize
            guard var current = store.host(id: host.id) else { return }
            current.fontSize = Double(newSize)
            store.update(current)
        }
        controller.onSend = { data in sendUserInput(data) }
        controller.onResize = { newCols, newRows in
            cols = newCols
            rows = newRows
            connection.send(.resize(cols: UInt16(clamping: newCols), rows: UInt16(clamping: newRows)))
        }
        connection.onState = { newState in
            state = newState
            handleState(newState)
        }
        // The hot path, and the only thing on it: no SwiftUI state is touched.
        connection.onStdout = { data in
            controller.feed(data)
        }
        connection.onSessionInvalidated = {
            store.setLastSessionID(nil, forHostID: host.id)
        }
        reconnect()
    }

    private func handleState(_ newState: Connection.State) {
        switch newState {
        case .live(let resp):
            attached = resp
            sessionEndedAt = nil
            store.setLastSessionID(resp.sessionID, forHostID: host.id)
            // ATTACHED echoes the geometry we asked for, which is the placeholder
            // sent before SwiftTerm had a frame to measure. The laid-out grid is
            // the truth about what the user is looking at, so re-assert it and
            // let the daemon resize the PTY to match.
            let laidOut = (cols: controller.cols, rows: controller.rows)
            if laidOut.cols != resp.cols || laidOut.rows != resp.rows {
                connection.send(.resize(cols: UInt16(clamping: laidOut.cols),
                                        rows: UInt16(clamping: laidOut.rows)))
            }
            cols = laidOut.cols
            rows = laidOut.rows
            // The one authored moment (DESIGN.md): the marks draw themselves in
            // as the session attaches, 200ms ease-out, and then nothing on this
            // screen animates again.
            if marksProgress < 1 {
                withAnimation(Theme.Motion.attach) { marksProgress = 1 }
            }

        case .needsUnlock(let attemptsLeft):
            unlockAttemptsLeft = attemptsLeft
            // Keychain first; only ask a human if the machine cannot answer.
            if !triedKeychainSecret, let secret = Keychain.unlockSecret(hostID: host.id) {
                triedKeychainSecret = true
                connection.send(.unlock(secret))
            } else {
                secretFocused = true
            }

        case .closed, .idle:
            marksProgress = 0
            if sessionEndedAt == nil { sessionEndedAt = Date() }

        case .connecting, .attaching:
            break
        }
    }

    private func reconnect() {
        triedKeychainSecret = false
        typedSecret = ""
        marksProgress = 0
        sessionEndedAt = nil
        ctrlLatched = false
        altLatched = false
        controller.resetMetrics()
        // Resume via the persisted session id if the store has a newer copy.
        let current = store.host(id: host.id) ?? host
        connection.connect(host: current, cols: controller.cols, rows: controller.rows)
    }

    private func submitSecret() {
        guard !typedSecret.isEmpty else { return }
        connection.send(.unlock(typedSecret))
        typedSecret = ""
        secretFocused = false
    }

    /// Every user-originated byte funnels through here so the latched modifiers
    /// can fold the next key, whether it came from the key bar or the software
    /// keyboard.
    private func sendUserInput(_ data: Data) {
        guard !data.isEmpty else { return }

        // Snapshot both latches before releasing either. Clearing one is a
        // SwiftUI state write, and reading the other after that write is a
        // read-after-write on the same update pass: Ctrl+Alt lost its ESC
        // prefix that way, which is exactly the kind of imprecision this app
        // cannot afford.
        let ctrl = ctrlLatched
        let alt = altLatched
        if ctrl { ctrlLatched = false }
        if alt { altLatched = false }

        var payload = data
        if ctrl {
            var first = payload[payload.startIndex]
            switch first {
            case 0x20:
                // Ctrl-Space is NUL, which the mask alone would not produce.
                first = 0x00
            case 0x3f...0x7f:
                // @ A..Z [ \ ] ^ _ and the lowercase run: k & 0x1f.
                first = first & 0x1f
            default:
                break
            }
            payload = Data([first]) + payload.dropFirst()
        }

        var out = Data()
        if alt {
            // Alt is the ESC prefix, which is what every terminal actually
            // sends for Meta. Applied after Ctrl so Alt+Ctrl+C is ESC 0x03.
            out.append(0x1b)
        }
        out.append(payload)
        connection.send(.stdin(out))
    }

    // MARK: - Measurement

    /// `LANDLINE_PERF=1` prints one line of feed statistics per second to the
    /// console. Off by default and compiled out of release.
    private var perfLoggingEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LANDLINE_PERF"] == "1"
        #else
        return false
        #endif
    }

    private func perfLoggingLoop() async {
        guard perfLoggingEnabled else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            print(controller.metricsLine(label: host.displayName))
            fflush(stdout)
        }
    }
}

// MARK: - Back cell

/// The header's leading cell. Pressed goes to `raised`, and a full hairline
/// separates it from the identity block, the way a plate is divided.
private struct BackCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.inkBright : Theme.inkMuted)
            .background(configuration.isPressed ? Theme.raised : Color.clear)
            .overlay(alignment: .trailing) { VerticalHairline() }
            .animation(Theme.Motion.state, value: configuration.isPressed)
    }
}

// MARK: - Session age

/// The session clock. It lives in its own view with its own timeline so a
/// ticking figure invalidates twenty points of header and nothing else — in
/// particular never the terminal.
private struct SessionAgeReadout: View {
    let createdAt: Date?
    /// When the session stopped. A clock that keeps counting after the process
    /// exited is the app inventing state, which PRODUCT.md forbids.
    var endedAt: Date?

    var body: some View {
        if let createdAt {
            if let endedAt {
                Text(Self.label(since: createdAt, now: endedAt)).llValue(Theme.inkMuted)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.label(since: createdAt, now: context.date)).llValue()
                }
            }
        } else {
            Text("--:--:--").llValue(Theme.inkMuted)
        }
    }

    /// Always eight glyphs wide, so the header never reflows while it counts.
    static func label(since start: Date, now: Date) -> String {
        let total = Int(max(0, now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

// MARK: - System appearance

enum SystemAppearance {
    /// The device's own light/dark setting, read past the window-level dark
    /// preference this app applies to its own chrome. DESIGN.md forces a dark
    /// ground because of the scene the app is used in, so `\.colorScheme` would
    /// always answer "dark"; a host set to follow the system needs the real
    /// answer for its terminal palette.
    static var isLight: Bool {
        UIScreen.main.traitCollection.userInterfaceStyle == .light
    }
}
