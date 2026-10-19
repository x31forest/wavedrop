import AppKit
import MetalKit

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    do { try Snapshot.run(path: CommandLine.arguments[i + 1]) } catch { print("snapshot failed: \(error)") }
    exit(0)
}

final class VisualizerView: MTKView {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.toggleFullScreen(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var view: VisualizerView!
    private var renderer: Renderer!
    private var source: AudioSource!
    private let hud = NSTextField(labelWithString: "")
    private var hudPinned = false
    /// Always-on shortcut cheat sheet (bottom right), toggled with K.
    private let keysLabel = NSTextField(labelWithString: """
         ←  →  Space   change preset
         M             style: Auto / Electronic / Classical
         L             lock preset
         F  Return     full screen   (Esc exits)
         H             pin status panel
         N             pin song info (Spotify)
         [  ]          beat sync −/+ 10 ms
         K             hide these keys
        """)
    private var hudVisibleUntil = CACurrentMediaTime() + 8
    private var lastHudUpdate: CFTimeInterval = 0
    private var lastPreset = ""
    private var heardAudio = false
    private let startTime = CACurrentMediaTime()
    private var captureError: String?
    private let defaults = UserDefaults.standard
    private let spotify = SpotifyNowPlaying()
    private let card = NowPlayingCard()
    private var cardPinned = false
    private var cardVisibleUntil: CFTimeInterval = 0
    private var cardShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let demo = CommandLine.arguments.contains("--demo")
        source = demo ? DemoSource() : SystemAudioTap()
        do { try source.start() } catch {
            captureError = error.localizedDescription
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Wavedrop"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.setFrameAutosaveName("WavedropMain")
        if window.frame.origin == .zero { window.center() }

        view = VisualizerView(frame: window.contentView!.bounds, device: MTLCreateSystemDefaultDevice())
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = true
        window.contentView = view

        do {
            renderer = try Renderer(view: view, source: source)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not start the renderer"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        if let m = defaults.string(forKey: "mode"), let mode = StyleMode(rawValue: m) { renderer.director.mode = mode }
        if defaults.object(forKey: "latency") != nil { renderer.analyzer.latencyCompensation = defaults.double(forKey: "latency") }
        if let name = defaults.string(forKey: "preset"), let i = presets.firstIndex(where: { $0.name == name }) {
            renderer.director.select(i)
        }
        renderer.director.locked = defaults.bool(forKey: "locked")
        hudPinned = defaults.bool(forKey: "pinHUD")
        view.delegate = renderer
        renderer.mtkView(view, drawableSizeWillChange: view.drawableSize)
        renderer.onFrame = { [weak self] f, d in self?.frame(f, d) }
        view.onKey = { [weak self] e in self?.handleKey(e) ?? false }

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        hud.textColor = NSColor(white: 1, alpha: 0.92)
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        hud.layer?.cornerRadius = 8
        hud.maximumNumberOfLines = 0
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            hud.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])

        keysLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        keysLabel.textColor = NSColor(white: 1, alpha: 0.85)
        keysLabel.wantsLayer = true
        keysLabel.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        keysLabel.layer?.cornerRadius = 8
        keysLabel.maximumNumberOfLines = 0
        keysLabel.translatesAutoresizingMaskIntoConstraints = false
        keysLabel.isHidden = defaults.bool(forKey: "hideKeys")
        view.addSubview(keysLabel)
        NSLayoutConstraint.activate([
            keysLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            keysLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])

        card.translatesAutoresizingMaskIntoConstraints = false
        card.alphaValue = 0
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        cardPinned = defaults.bool(forKey: "pinSongInfo")
        spotify.onChange = { [weak self] t in self?.trackChanged(t) }
        spotify.onArtwork = { [weak self] img, hue in
            self?.card.setArtwork(img)
            self?.renderer.director.artHue = hue
        }
        spotify.start()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--fullscreen") || defaults.bool(forKey: "fullscreen") {
            window.toggleFullScreen(nil)
        }
    }

    private var lastTrackID = ""

    private func trackChanged(_ t: SpotifyNowPlaying.Track?) {
        guard let t else { return }
        card.show(t)
        if t.id != lastTrackID {
            lastTrackID = t.id
            card.setArtwork(nil)
            renderer.director.artHue = nil
            cardVisibleUntil = CACurrentMediaTime() + 10
        } else if t.playing {
            cardVisibleUntil = max(cardVisibleUntil, CACurrentMediaTime() + 4)   // resumed
        }
    }

    private func updateCard(_ now: CFTimeInterval) {
        let playing = spotify.track?.playing ?? false
        let want = playing && (cardPinned || now < cardVisibleUntil)
        guard want != cardShown else { return }
        cardShown = want
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = want ? 0.6 : 1.2
            card.animator().alphaValue = want ? 1 : 0
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { defaults.set(true, forKey: "fullscreen") }
    func windowDidExitFullScreen(_ notification: Notification) { defaults.set(false, forKey: "fullscreen") }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { source?.stop() }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Wavedrop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Wavedrop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Wavedrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fs)
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard let chars = e.charactersIgnoringModifiers?.lowercased() else { return false }
        let d = renderer.director
        var handled = true
        switch (chars, e.keyCode) {
        case (_, 123): d.previous()                        // ←
        case (_, 124), (" ", _): d.next()                   // → / space
        case (_, 53): if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }   // esc
        case (_, 36), ("f", _): window.toggleFullScreen(nil)    // return / f
        case ("m", _):
            d.mode = d.mode.next
            defaults.set(d.mode.rawValue, forKey: "mode")
        case ("l", _):
            d.locked.toggle()
            defaults.set(d.locked, forKey: "locked")
        case ("h", _):
            hudPinned.toggle()
            defaults.set(hudPinned, forKey: "pinHUD")
        case ("n", _):
            cardPinned.toggle()
            defaults.set(cardPinned, forKey: "pinSongInfo")
            if !cardPinned { cardVisibleUntil = 0 }
        case ("k", _):
            keysLabel.isHidden.toggle()
            defaults.set(keysLabel.isHidden, forKey: "hideKeys")
        case ("[", _): renderer.adjustLatency(by: -0.01); defaults.set(renderer.analyzer.latencyCompensation, forKey: "latency")
        case ("]", _): renderer.adjustLatency(by: 0.01); defaults.set(renderer.analyzer.latencyCompensation, forKey: "latency")
        default: handled = false
        }
        if handled { hudVisibleUntil = CACurrentMediaTime() + 4 }
        return handled
    }

    private func frame(_ f: AudioFeatures, _ d: Director) {
        let now = CACurrentMediaTime()
        if !f.silent { heardAudio = true }
        if d.presetName != lastPreset {
            if !lastPreset.isEmpty { hudVisibleUntil = max(hudVisibleUntil, now + 2.5) }
            lastPreset = d.presetName
            defaults.set(d.presetName, forKey: "preset")
        }
        if window.styleMask.contains(.fullScreen), Int(now * 2) % 6 == 0 { NSCursor.setHiddenUntilMouseMoves(true) }
        updateCard(now)
        guard now - lastHudUpdate > 0.1 else { return }
        lastHudUpdate = now

        var problem: String?
        if let captureError {
            problem = "⚠︎ Couldn't capture system audio: \(captureError)"
        } else if !heardAudio && now - startTime > 4 {
            problem = """
            No audio yet — play some music. If music IS playing, allow Wavedrop in
            System Settings › Privacy & Security › Screen & System Audio Recording
            (System Audio Recording Only), then relaunch.
            """
        }
        let show = hudPinned || now < hudVisibleUntil || problem != nil
        hud.isHidden = !show
        guard show else { return }

        let styleWord = d.styleValue > 0.5 ? "pulse" : "flow"
        let modeText = d.mode == .auto ? "Auto → \(styleWord) \(Int(d.styleValue * 100))%" : d.mode.rawValue
        let dots = (0..<4).map { f.bpm > 0 && f.rhythm > 0.25 && $0 == f.beatCount % 4 ? "●" : "○" }.joined()
        let tempo = f.bpm > 0 && f.rhythm > 0.25 ? String(format: "%5.1f BPM %@", f.bpm, dots) : "  free tempo"
        let bar = { (v: Float) in String(repeating: "▮", count: Int(min(1, v) * 10)).padding(toLength: 10, withPad: "·", startingAt: 0) }
        var lines = [
            " \(d.presetName)\(d.locked ? "  🔒" : "")",
            " Style: \(modeText)    \(tempo)",
            " Level \(bar(f.loudness))  Bass \(bar(f.bassAtt / 2))  Treble \(bar(f.trebAtt / 2))",
            String(format: " Sync offset %+.0f ms", renderer.analyzer.latencyCompensation * 1000),
        ]
        if let problem { lines.insert(" " + problem.replacingOccurrences(of: "\n", with: "\n "), at: 0) }
        lines.append(" " + source.statusText + " ")
        hud.stringValue = lines.joined(separator: "\n")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
