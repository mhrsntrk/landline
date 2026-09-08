import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    /// Regular width: the index is a column *beside* this screen rather than a
    /// screen behind it, so the header's leading cell shows and hides it
    /// instead of popping a stack. Nil in compact width, where it goes back.
    var indexColumn: Binding<NavigationSplitViewVisibility>?

    @Environment(HostStore.self) private var store
    @Environment(SettingsStore.self) private var settings
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

    /// Ctrl, Alt and Leader. The composition rules live on the type, in the
    /// model, where they can be tested as a state machine — see `LatchState`.
    @State private var latches = LatchState()

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

    /// The row as the app-wide setting currently has it.
    private var keyBar: [ResolvedKey] { settings.resolvedKeyBar }

    /// The byte this host's tmux prefix resolves to. Nil when the stored
    /// notation is not a `C-<key>` this understands, which the settings screen
    /// refuses to save but a hand-edited `hosts.json` can still contain.
    private var leaderByte: UInt8? { LeaderKey.byte(for: liveHost.leaderKey) }

    /// The header band's laid-out width, which decides whether the session
    /// column fits. Changes when the window resizes or the index column shows
    /// and hides, which on an iPad is constantly.
    @State private var headerWidth: CGFloat = 0

    // Attachments. A phone cannot hand a file to a terminal, so the app puts
    // one in the host's inbox over HTTP and then types the path it landed at.
    // See `docs/HTTP.md`; the daemon owns the name and the destination.
    @State private var api = HostAPI()
    @State private var attachSourceShowing = false
    @State private var photoPickerShowing = false
    @State private var photoItem: PhotosPickerItem?
    @State private var fileImporterShowing = false
    @State private var upload = UploadProgress.none
    /// One shot, so the debug attachment hook cannot fire again on a reconnect.
    @State private var demoAttachFired = false
    @State private var snippetsShowing = false
    /// Files the host has offered (`landlined send`). Polled once on attach and
    /// on every foregrounding rather than continuously: an offer is made by a
    /// person at a keyboard, so the moment worth checking is the moment you
    /// look at the phone.
    @State private var offers: [HostOffer] = []
    @State private var openedOffer: URL?
    @State private var fetchingOffer = false

    /// Live point size. Held in state rather than read off `host` every time
    /// because the pinch gesture changes it mid-session and writes it back to
    /// the store; `host` is the copy this screen was pushed with and would go
    /// stale the moment a pinch landed.
    @State private var fontSize: CGFloat = TerminalFont.defaultSize

    var body: some View {
        VStack(spacing: 0) {
            header
            terminalRegion
            // An empty layout means the user removed every key, which is a
            // choice: the bar disappears and the terminal gets its 44pt back.
            if !keyBar.isEmpty {
                KeyBar(keys: keyBar,
                       ctrlLatched: $latches.ctrl,
                       altLatched: $latches.alt,
                       leaderLatched: $latches.leader,
                       leaderByte: leaderByte,
                       send: { bytes in sendUserInput(Data(bytes)) },
                       // Only a live session has somewhere to put a file and
                       // something to type the path into.
                       attach: isLive ? { attachSourceShowing = true } : nil,
                       snippets: isLive ? { snippetsShowing = true } : nil)
            }
        }
        .background(Theme.ground)
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear {
            wireUpAndConnect()
            // After the representable has made its view. A hardware keyboard is
            // the normal case on an iPad and this is a terminal, so the
            // terminal has to be what a keystroke reaches.
            DispatchQueue.main.async { controller.focus() }
        }
        .onDisappear {
            connection.disconnect(sendDetach: true)
            // Both objects are stored in `@State` on this view *and* hold
            // closures that captured it, so each retains itself through its own
            // callback and neither deinit ever runs. Clearing them here is what
            // actually releases the pair when the screen goes away.
            connection.onState = nil
            connection.onStdout = nil
            connection.onSessionInvalidated = nil
            controller.onSend = nil
            controller.onResize = nil
            controller.onFontSizeChange = nil
        }
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
                controller.focus()
                if case .closed = state { reconnect() }
                if case .idle = state { reconnect() }
                // Coming back to the app is the clearest signal that whatever
                // the link was waiting out is over, so it should not sit
                // through the rest of a backoff the user cannot see.
                if case .reconnecting = state { connection.retryNow() }
                if isLive { Task { await refreshOffers() } }
            default:
                break
            }
        }
        .task(id: perfLoggingEnabled) { await perfLoggingLoop() }
        // Polled while the session is live, not only on attach. The moment a
        // file is offered is the moment someone runs `landlined send` at the
        // machine, which is routinely while they are already looking at the
        // phone. Checking only on attach meant the band never appeared in the
        // one case it exists for. A push would be better and the protocol has
        // no room for one: version 1 is frozen.
        .task(id: isLive) { await pollOffers() }
        .modifier(AttachmentPickers(
            attachSourceShowing: $attachSourceShowing,
            photoPickerShowing: $photoPickerShowing,
            photoItem: $photoItem,
            fileImporterShowing: $fileImporterShowing,
            snippetsShowing: $snippetsShowing,
            openedOffer: $openedOffer,
            onPhoto: { item in Task { await loadPhoto(item) } },
            onFile: { result in
                switch result {
                case .success(let url): loadFile(at: url)
                case .failure(let error): upload = .failed(error.localizedDescription)
                }
            },
            onSnippet: { snippet in
                snippetsShowing = false
                insert(snippet: snippet)
            }
        ))
    }

    private var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    // MARK: - Header
    //
    // One measured row. Everything here is mono with tabular figures, because
    // all of it is machine data.

    private var header: some View {
        // One measured row, no second line. The annotation strip that used to
        // sit under this said LIVE / ZSH / SESSION, and on a phone the terminal
        // is short enough that a whole row of chrome has to earn itself. The
        // status square already carries the state, the shell is visible in the
        // prompt, and the session id moved into the measured columns where the
        // other machine facts live.
        HStack(spacing: 0) {
            backControl
            HStack(spacing: Theme.Metric.grid * 2) {
                StatusSquare(level: statusLevel)
                Text(liveHost.displayName)
                    .llValueStrong()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Metric.grid * 2)
                // The column that only exists on a wide band. On a phone the
                // band is full and there is nowhere to put this; on an iPad's
                // detail pane the same row has 500pt of nothing between the
                // name and the readouts, and a measured strip with a hole in it
                // is a phone layout that has been stretched. So the hole gets
                // filled with the one fact the header never showed: which
                // endpoint this session is actually attached to, which is also
                // the fact you want when two machines are named alike.
                if showsEndpointColumn {
                    measured(label: "ENDPOINT", value: endpointLabel)
                }
                if let sessionShortID, showsSessionColumn {
                    measured(label: "SESS", value: sessionShortID)
                }
                measured(label: "GEOM", value: "\(cols)×\(rows)")
                measured(label: "AGE", value: nil) {
                    SessionAgeReadout(createdAt: sessionCreatedAt, endedAt: sessionEndedAt)
                }
            }
            .padding(.trailing, Theme.Metric.gutter)
        }
        .frame(height: Theme.Metric.hitTarget + Theme.Metric.grid * 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: HeaderWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(HeaderWidthKey.self) { headerWidth = $0 }
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

    /// The one back affordance this app has (DESIGN.md, navigation grammar):
    /// the leading cell of the header band. In a split view the same cell
    /// carries the index column, because there the index is not behind this
    /// screen, it is next to it.
    private var backControl: some View {
        HeaderLeadingCell(kind: leadingKind) {
            if let indexColumn {
                withAnimation(Theme.Motion.state) {
                    indexColumn.wrappedValue = indexIsShowing ? .detailOnly : .all
                }
            } else {
                dismiss()
            }
        }
    }

    private var indexIsShowing: Bool {
        indexColumn?.wrappedValue != .detailOnly
    }

    private var leadingKind: HeaderLeading {
        indexColumn == nil ? .back : .index(showing: indexIsShowing)
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

    /// Whether the band has the width to carry the session column as well as
    /// the geometry and the age.
    ///
    /// The band is one row and it holds four things: the leading cell, the
    /// machine's name, and three measured columns. On the narrowest phone this
    /// app supports the four do not all fit at their honest widths, and the one
    /// that loses is the name, which is the one thing on this screen that says
    /// which machine you are typing at. So the least load-bearing column goes
    /// instead: `SESS` is a four-glyph handle for matching a row in
    /// `landlined sessions list`, which is a thing you do at a desk, not on a
    /// train. `GEOM` and `AGE` both change while you watch and are kept.
    private var showsSessionColumn: Bool {
        headerWidth == 0 || headerWidth >= Self.sessionColumnFloor
    }

    /// Measured, not guessed: the leading cell, the three columns at their
    /// laid-out widths and the gutters come to just over 320pt, and a name
    /// column narrower than about 80pt stops being a name.
    static let sessionColumnFloor: CGFloat = 400

    /// Wide enough that the band has room the other columns are not using.
    /// A full-width iPad pane and a landscape phone clear it; a portrait phone
    /// and a narrow split never do.
    private var showsEndpointColumn: Bool { headerWidth >= Self.endpointColumnFloor }

    static let endpointColumnFloor: CGFloat = 700

    /// First four glyphs of the session id: enough to match a row in
    /// `landlined sessions list`, and the label is kept to four characters
    /// too, because a column is as wide as the wider of its label and value
    /// and this row has to hold three columns on a small phone.
    /// Absent until the daemon has answered.
    private var sessionShortID: String? {
        guard let attached else { return nil }
        return String(attached.sessionID.prefix(4)).uppercased()
    }

    private var stateWord: String {
        switch state {
        case .idle: return "IDLE"
        case .connecting: return "CONNECTING"
        case .attaching: return "ATTACHING"
        case .needsUnlock: return "LOCKED"
        case .live: return "LIVE"
        case .reconnecting: return "RETRYING"
        case .closed: return closedIsError ? "ERROR" : "CLOSED"
        }
    }

    private var statusLevel: StatusSquare.Level {
        switch state {
        case .live: return .connected
        case .connecting, .attaching, .needsUnlock, .reconnecting: return .connecting
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
        case .reconnecting(let attempt, let reason):
            band {
                VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
                    HStack(spacing: Theme.Metric.grid * 3) {
                        MicroLabel("RECONNECTING", color: Theme.warn)
                        Spacer(minLength: 0)
                        MicroLabel("TRY \(attempt)").llMeasuredColumn()
                    }
                    // The session is on the daemon, so this is a reattach, not
                    // a new shell. Saying so is what stops someone force
                    // quitting the app to "start again" and orphaning it.
                    Text("\(reason). The session is still on the host and will be resumed.")
                        .llProse(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("RETRY NOW") { connection.retryNow() }
                        .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                }
            }
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
            VStack(spacing: 0) {
                offerBand
                uploadBand
            }
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

    // MARK: - Attachments

    /// What the band says while a file is on its way, and after one did not
    /// make it. Nothing at all on success: the path appearing at the prompt is
    /// the receipt, and a banner confirming what is already on screen is chrome
    /// that has not earned itself.
    enum UploadProgress: Equatable {
        case none
        case sending(name: String, bytes: Int)
        case failed(String)
        /// The file reached the host but the path could not be typed, because
        /// the session dropped in between. The upload is not the thing that
        /// went wrong, and saying "UPLOAD FAILED" would send someone looking
        /// for a file that is already there.
        case strandedAt(String)
        /// A fetch from the host's outbox failed. Its own case because the
        /// upload wording is wrong in both halves for a download.
        case fetchFailed(String)

        var label: String {
            switch self {
            case .none, .sending: return ""
            case .failed: return "UPLOAD FAILED"
            case .strandedAt: return "UPLOADED, NOT TYPED"
            case .fetchFailed: return "COULD NOT OPEN"
            }
        }

        var message: String? {
            switch self {
            case .none, .sending: return nil
            case .failed(let text), .fetchFailed(let text): return text
            case .strandedAt(let path):
                return "The file is on the host at \(path), but the session dropped before the path could be typed."
            }
        }
    }

    @ViewBuilder
    private var uploadBand: some View {
        switch upload {
        case .none:
            EmptyView()
        case .sending(let name, let bytes):
            band {
                HStack(spacing: Theme.Metric.grid * 3) {
                    MicroLabel("SENDING", color: Theme.warn)
                    Text(name)
                        .llValue(Theme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    MicroLabel(Self.sizeLabel(bytes))
                }
            }
        case .failed, .fetchFailed, .strandedAt:
            band {
                VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
                    HStack(spacing: Theme.Metric.grid * 3) {
                        // A stranded upload is not an error: the file arrived.
                        // It reads in `warn` so it does not send anyone hunting
                        // for a failure that did not happen.
                        MicroLabel(upload.label,
                                   color: isStranded ? Theme.warn : Theme.alert)
                        Spacer(minLength: 0)
                        Button("DISMISS") { upload = .none }
                            .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                    }
                    if let message = upload.message {
                        Text(message)
                            .llValue(isStranded ? Theme.ink : Theme.alertText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var isStranded: Bool {
        if case .strandedAt = upload { return true }
        return false
    }

    /// Bytes as the band prints them: whole units, never more than four glyphs
    /// wide, because this sits in a measured row.
    static func sizeLabel(_ bytes: Int) -> String {
        if bytes >= 1_048_576 {
            return "\(Int((Double(bytes) / 1_048_576).rounded())) MB"
        }
        return "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        let type = item.supportedContentTypes.first
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            await MainActor.run { upload = .failed(UploadError.empty.message) }
            return
        }
        // The picker does not hand over a file name, only a content type, so
        // one is made up here. It barely matters: the daemon appends a unique
        // suffix and owns the final name either way.
        let name = "photo.\(type?.preferredFilenameExtension ?? "jpg")"
        let attachment = AttachmentPrep.prepare(data: data, filename: name, type: type)
        await MainActor.run { send(attachment) }
    }

    private func loadFile(at url: URL) {
        // A file picked out of another app's container is only readable inside
        // this pair of calls.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Asked before reading. The picker allows any item, so this could be a
        // multi-gigabyte video or a file iCloud has not downloaded, and
        // `Data(contentsOf:)` on one of those blocks the main thread long
        // enough to be killed, well before the host's own size cap is ever
        // consulted.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size, size > Self.pickedFileCeiling {
            upload = .failed("that file is \(Self.sizeLabel(size)), larger than a host will take")
            return
        }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
            upload = .failed("could not read that file")
            return
        }
        let type = UTType(filenameExtension: url.pathExtension)
        send(AttachmentPrep.prepare(data: data, filename: url.lastPathComponent, type: type))
    }

    /// The largest file worth reading into memory before asking the host.
    ///
    /// Matches the daemon's own default `upload_max_bytes`. A host may be
    /// configured lower, and will say so; this exists only to stop the app
    /// dying before it can be told.
    private static let pickedFileCeiling = 26_214_400

    private func send(_ attachment: Attachment) {
        upload = .sending(name: attachment.filename, bytes: attachment.data.count)
        let target = liveHost
        // The same secret the shell handshake uses. A host with no unlock sends
        // an empty one, which the daemon accepts because its gate is not armed.
        let secret = Keychain.unlockSecret(hostID: target.id) ?? ""
        Task {
            do {
                let path = try await api.upload(
                    data: attachment.data,
                    filename: attachment.filename,
                    to: target,
                    secret: secret
                )
                await MainActor.run {
                    // Only clear the band if the path can actually be typed.
                    // `Connection.send` drops frames while reconnecting, and a
                    // long upload over a flaky link is exactly when that
                    // happens: the file lands, the receipt never appears, and
                    // without this the whole thing vanishes silently.
                    if isLive {
                        upload = .none
                        insert(path: path)
                    } else {
                        upload = .strandedAt(path)
                    }
                }
            } catch {
                let message = (error as? UploadError)?.message ?? error.localizedDescription
                await MainActor.run { upload = .failed(message) }
            }
        }
    }

    /// See `DemoSeed.attachesAFile`. Debug-only, and inert unless the
    /// environment asks for it.
    private func demoAttachIfAsked() {
        #if DEBUG
        guard DemoSeed.attachesAFile, !demoAttachFired else { return }
        demoAttachFired = true
        // A moment after the prompt has drawn, so the still shows the path
        // arriving at a settled screen rather than racing the shell.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let size = CGSize(width: 900, height: 600)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(Theme.accent).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            guard let data = image.pngData() else { return }
            send(AttachmentPrep.prepare(data: data, filename: "demo-shot.png", type: .png))
        }
        #endif
    }

    /// What the host has sent this way, when it has sent anything.
    ///
    /// A band rather than a badge or a count somewhere: a file offered from the
    /// host is a thing waiting to be picked up, and it should say so where the
    /// session is, not in a screen someone has to think to visit.
    @ViewBuilder
    private var offerBand: some View {
        if let offer = offers.first {
            band {
                HStack(spacing: Theme.Metric.grid * 3) {
                    MicroLabel(offers.count > 1 ? "\(offers.count) FILES FROM HOST" : "FILE FROM HOST",
                               color: Theme.ok)
                    Text(offer.name)
                        .llValue(Theme.inkBright)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MicroLabel(Self.sizeLabel(offer.bytes)).llMeasuredColumn()
                    Spacer(minLength: 0)
                    Button(fetchingOffer ? "..." : "OPEN") {
                        Task { await fetch(offer) }
                    }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
                    .disabled(fetchingOffer)
                    Button("DISMISS") { Task { await withdraw(offer) } }
                        .buttonStyle(InstrumentButtonStyle(emphasis: .secondary))
                }
            }
        }
    }

    /// Asks for the outbox while the session is live, and stops when it is not.
    ///
    /// Fifteen seconds because that is well under how long anyone waits after
    /// typing `landlined send` before looking at the phone, and the request is
    /// a few dozen bytes of JSON over a link that is already carrying a
    /// terminal.
    @MainActor
    private func pollOffers() async {
        guard isLive else { return }
        await refreshOffers()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, isLive else { return }
            await refreshOffers()
        }
    }

    @MainActor
    private func refreshOffers() async {
        let target = liveHost
        let secret = Keychain.unlockSecret(hostID: target.id) ?? ""
        // Silent on failure. This is a background courtesy, and a host running
        // a daemon too old to know the endpoint must not put an error band over
        // a working session.
        offers = (try? await api.outbox(on: target, secret: secret)) ?? []
    }

    @MainActor
    private func fetch(_ offer: HostOffer) async {
        fetchingOffer = true
        defer { fetchingOffer = false }
        let target = liveHost
        let secret = Keychain.unlockSecret(hostID: target.id) ?? ""
        do {
            let url = try await api.fetchOffer(offer, on: target, secret: secret)
            // Withdrawn on success: it has been picked up, and an offer that
            // stays after you took it is a band that never goes away.
            try? await api.withdrawOffer(id: offer.id, on: target, secret: secret)
            offers.removeAll { $0.id == offer.id }
            openedOffer = url
        } catch {
            upload = .failed((error as? UploadError)?.message ?? error.localizedDescription)
        }
    }

    @MainActor
    private func withdraw(_ offer: HostOffer) async {
        let target = liveHost
        let secret = Keychain.unlockSecret(hostID: target.id) ?? ""
        try? await api.withdrawOffer(id: offer.id, on: target, secret: secret)
        offers.removeAll { $0.id == offer.id }
    }

    /// Types a saved snippet into the session.
    ///
    /// Same path as an inserted file path and for the same reasons: bracketed
    /// paste when the far end asked for it, and never through `sendUserInput`,
    /// where a latched Ctrl would fold the first character of it.
    private func insert(snippet: Snippet) {
        let bytes = snippet.bytes(bracketedPaste: controller.bracketedPaste)
        guard !bytes.isEmpty else { return }
        connection.send(.stdin(Data(bytes)))
    }

    /// Types the path the file landed at into the session.
    ///
    /// Deliberately not routed through `sendUserInput`: a latched Ctrl would
    /// fold the first byte of the path, and a path is not a keystroke. Nothing
    /// is executed here, and nothing is guessed about what is running at the
    /// far end. The path arrives at the prompt and the person decides.
    private func insert(path: String) {
        let bytes = PathInsertion.bytes(for: path, bracketedPaste: controller.bracketedPaste)
        guard !bytes.isEmpty else { return }
        connection.send(.stdin(Data(bytes)))
    }

    private func closedContent(reason: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.grid * 2) {
            MicroLabel(closedIsError ? "ERROR" : "CLOSED",
                       color: closedIsError ? Theme.alertText : Theme.inkMuted)
            Text(recoveryText(for: reason))
                .llProse(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            // One action, not two. The way back to the index is the header's
            // leading cell, on this screen and on every other screen in the app
            // (DESIGN.md, navigation grammar); a second control that did the
            // same thing in a different shape is exactly the drift this band
            // used to carry.
            HStack(spacing: Theme.Metric.grid * 3) {
                Button("RECONNECT") { reconnect() }
                    .buttonStyle(InstrumentButtonStyle(emphasis: .primary))
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
        // A reason may already end in its own terminator; appending a period
        // to one produced "is Tailscale up?." on screen.
        let terminated = [".", "?", "!"].contains { sentence.hasSuffix($0) }
        return terminated ? sentence : sentence + "."
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
        // Debug screenshot hook, the same idiom as `DemoSeed`: arm the leader so
        // the latched cell can be looked at rather than reasoned about. After
        // `reconnect()`, which clears every latch.
        if DemoSeed.armsLeader { latches.leader = true }
    }

    private func handleState(_ newState: Connection.State) {
        switch newState {
        case .live(let resp):
            attached = resp
            sessionEndedAt = nil
            // Before a single replayed byte reaches SwiftTerm. The daemon sends
            // ATTACHED, then the scrollback, then live output, and the replay
            // must not answer the queries it contains.
            controller.beginReplay(bytes: resp.replayBytes)
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
            demoAttachIfAsked()
            // Debug screenshot hook, the same idiom as `DemoSeed`: arm the
            // leader a moment *after* the attach settles. Arming in
            // `wireUpAndConnect` is not enough against a live session, for two
            // reasons: a foregrounding that lands while the connection is still
            // idle calls `reconnect()`, which clears every latch, and the
            // emulator's own answers to the queries tmux asks on attach travel
            // out through `sendUserInput`, which *consumes* one. Two seconds is
            // past both. Compiled out of release with the rest of `DemoSeed`.
            if DemoSeed.armsLeader {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    latches.leader = true
                }
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

        case .reconnecting:
            // The marks stay drawn. This is one session having a bad minute,
            // not a session ending, and taking the plate apart and putting it
            // back for every tunnel would be the most animated thing in the app.
            break

        case .connecting, .attaching:
            // Every new transport re-unlocks (PROTOCOL.md 3), so the
            // "already tried the Keychain" flag is per *connection*, not per
            // screen. Resetting it only in `reconnect()` meant the paths that
            // reconnect inside `Connection` (the backoff after a dropped link,
            // the fresh attach after SESSION_GONE, the RETRY NOW button) came
            // back up with the flag still set and fell straight through to the
            // manual prompt, which is the one thing an automatic reconnect is
            // supposed to spare you.
            triedKeychainSecret = false

        }
    }

    private func reconnect() {
        triedKeychainSecret = false
        typedSecret = ""
        marksProgress = 0
        sessionEndedAt = nil
        latches.clear()
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
    ///
    /// The composition rules — and the snapshot-before-clear that keeps them
    /// honest across a SwiftUI update pass — live on `LatchState`, so they can
    /// be tested without a view. One frame per keypress, because the tmux prefix
    /// and the key it prefixes must not be able to arrive split around a
    /// reconnect.
    ///
    /// The armed check is not a micro-optimisation, it is the difference between
    /// a keystroke costing a frame and costing nothing. `latches` is `@State`,
    /// and `consume` is `mutating`, so calling it writes the State and
    /// invalidates this whole body — header, key bar and all — once per byte
    /// typed. On a held key that is 25 to 50 body re-renders a second for a
    /// state machine that had nothing to say. Cleared latches return the payload
    /// unchanged (asserted in `LatchStateTests`), so skipping the call when none
    /// is armed is behaviour-preserving by construction.
    private func sendUserInput(_ data: Data) {
        guard !data.isEmpty else { return }
        let out: [UInt8]
        if latches.isAnyArmed {
            out = latches.consume(Array(data), leaderByte: leaderByte)
        } else {
            out = Array(data)
        }
        guard !out.isEmpty else { return }
        connection.send(.stdin(Data(out)))
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

// MARK: - Header measurement

/// The header band's width, reported by the band itself. Used to decide
/// whether the session column fits, which changes with the window and with the
/// index column rather than with the device.
private struct HeaderWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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

/// Everything this screen can present, lifted off `body`.
///
/// Not an organisational preference: with all of it inline the type checker
/// gives up on `body` outright. Six presentations on one view is past what it
/// will infer in reasonable time, and the failure is a build error rather than
/// a slow build.
private struct AttachmentPickers: ViewModifier {
    @Binding var attachSourceShowing: Bool
    @Binding var photoPickerShowing: Bool
    @Binding var photoItem: PhotosPickerItem?
    @Binding var fileImporterShowing: Bool
    @Binding var snippetsShowing: Bool
    @Binding var openedOffer: URL?

    let onPhoto: (PhotosPickerItem) -> Void
    let onFile: (Result<URL, Error>) -> Void
    let onSnippet: (Snippet) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Attach", isPresented: $attachSourceShowing,
                                titleVisibility: .visible) {
                Button("Photo library") { photoPickerShowing = true }
                Button("Files") { fileImporterShowing = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The file is copied to this host's inbox and its path is typed into the session.")
            }
            // Photos only. A video is minutes of bytes over a phone link and
            // past the daemon's size cap either way, and anyone who genuinely
            // means to send one can still reach it through Files and get a real
            // answer about the size rather than a picker that promised it would
            // work.
            .photosPicker(isPresented: $photoPickerShowing, selection: $photoItem,
                          matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                // Cleared immediately so picking the same photo twice still fires.
                photoItem = nil
                onPhoto(item)
            }
            .fileImporter(isPresented: $fileImporterShowing, allowedContentTypes: [.item],
                          onCompletion: onFile)
            .sheet(isPresented: $snippetsShowing) {
                SnippetPickerView(choose: onSnippet)
            }
            .quickLookPreview($openedOffer)
    }
}

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
