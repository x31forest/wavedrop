import AppKit

struct NowPlayingTrack: Equatable {
    var player: String       // "Spotify" or "Music"
    var id: String
    var title: String
    var artist: String
    var album: String
    var artworkURL: String
    var playing: Bool
}

/// A music app Wavedrop can follow: how to notice changes, query the track and find cover art.
enum MusicPlayer: CaseIterable {
    case spotify, music

    var name: String { self == .spotify ? "Spotify" : "Music" }
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var notification: String { self == .spotify ? "com.spotify.client.PlaybackStateChanged" : "com.apple.Music.playerInfo" }

    /// Returns "state\nid\ntitle\nartist\nalbum\nartworkURL" or "" when nothing is loaded.
    var scriptSource: String {
        let (idProp, artProp) = self == .spotify ? ("id of t", "artwork url of t") : ("persistent ID of t", "\"\"")
        return """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
                if player state is stopped then return ""
                set t to current track
                return (player state as string) & linefeed & (\(idProp)) & linefeed & (name of t) & linefeed & ¬
                    (artist of t) & linefeed & (album of t) & linefeed & (\(artProp))
            end tell
        end if
        return ""
        """
    }
}

/// Watches one music app for the current track and its album art.
/// Uses the app's playback notification as the trigger and its AppleScript dictionary for details
/// (needs a one-time "Wavedrop wants to control …" Automation permission per app).
final class PlayerWatcher {
    let player: MusicPlayer
    /// Called on the main thread when the track or play state changes (nil = nothing loaded).
    var onChange: ((NowPlayingTrack?) -> Void)?
    /// Called on the main thread when album art for the current track has loaded.
    var onArtwork: ((NSImage, _ hue: Float?) -> Void)?

    private(set) var track: NowPlayingTrack?
    private(set) var artwork: (image: NSImage, hue: Float?)?
    private let queue: DispatchQueue
    private var timer: Timer?
    private var artworkFor = ""
    private let script: NSAppleScript?

    init(_ player: MusicPlayer) {
        self.player = player
        queue = DispatchQueue(label: "wavedrop.\(player.name)")
        script = NSAppleScript(source: player.scriptSource)
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(player.notification), object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        // Fallback poll in case a notification is missed (only talks to the app while it's running).
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == player.bundleID }) else {
            publish(nil)
            return
        }
        queue.async { [weak self] in
            guard let self, let script = self.script else { return }
            var err: NSDictionary?
            let out = script.executeAndReturnError(&err).stringValue ?? ""
            if let err { debugLog("\(self.player.name) query failed: \(err)") }
            let parts = out.components(separatedBy: "\n")
            let t: NowPlayingTrack? = parts.count >= 6
                ? NowPlayingTrack(player: self.player.name, id: parts[1], title: parts[2], artist: parts[3],
                                  album: parts[4], artworkURL: parts[5], playing: parts[0] == "playing")
                : nil
            DispatchQueue.main.async { self.publish(t) }
        }
    }

    private func publish(_ t: NowPlayingTrack?) {
        guard t != track else { return }
        track = t
        onChange?(t)
        guard let t, t.id != artworkFor else { return }
        artworkFor = t.id
        artwork = nil
        loadArtwork(for: t) { [weak self] img in
            guard let img else { return }
            let hue = Self.dominantHue(of: img)
            DispatchQueue.main.async {
                guard let self, self.track?.id == t.id else { return }
                self.artwork = (img, hue)
                self.onArtwork?(img, hue)
            }
        }
    }

    private func loadArtwork(for t: NowPlayingTrack, completion: @escaping (NSImage?) -> Void) {
        func fetch(_ url: URL?) {
            guard let url else { return completion(nil) }
            URLSession.shared.dataTask(with: url) { data, _, _ in completion(data.flatMap { NSImage(data: $0) }) }.resume()
        }
        switch player {
        case .spotify:
            Self.spotifyArtworkURL(for: t, completion: fetch)
        case .music:
            // Local/library tracks carry embedded art; streamed ones often don't, so fall back to
            // the iTunes Search API by artist + album.
            queue.async {
                let s = NSAppleScript(source: """
                    tell application id "com.apple.Music" to get raw data of artwork 1 of current track
                    """)
                var err: NSDictionary?
                if let data = s?.executeAndReturnError(&err).data, let img = NSImage(data: data) {
                    return completion(img)
                }
                Self.itunesArtworkURL(for: t, completion: fetch)
            }
        }
    }

    /// Newer Spotify builds often return an empty `artwork url` over AppleScript, so fall back to
    /// Spotify's public oEmbed endpoint, which gives the cover for a track ID.
    private static func spotifyArtworkURL(for t: NowPlayingTrack, completion: @escaping (URL?) -> Void) {
        if !t.artworkURL.isEmpty, let url = URL(string: t.artworkURL) { return completion(url) }
        let parts = t.id.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify",
              var c = URLComponents(string: "https://open.spotify.com/oembed") else { return completion(nil) }
        c.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(parts[1])/\(parts[2])")]
        guard let api = c.url else { return completion(nil) }
        URLSession.shared.dataTask(with: api) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var thumb = json["thumbnail_url"] as? String else { return completion(nil) }
            thumb = thumb.replacingOccurrences(of: "00001e02", with: "0000b273")   // 300 px → 640 px cover
            completion(URL(string: thumb))
        }.resume()
    }

    private static func itunesArtworkURL(for t: NowPlayingTrack, completion: @escaping (URL?) -> Void) {
        guard var c = URLComponents(string: "https://itunes.apple.com/search") else { return completion(nil) }
        c.queryItems = [URLQueryItem(name: "term", value: "\(t.artist) \(t.album)"),
                        URLQueryItem(name: "entity", value: "album"), URLQueryItem(name: "limit", value: "1")]
        guard let api = c.url else { return completion(nil) }
        URLSession.shared.dataTask(with: api) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["results"] as? [[String: Any]])?.first,
                  let art = first["artworkUrl100"] as? String else { return completion(nil) }
            completion(URL(string: art.replacingOccurrences(of: "100x100", with: "600x600")))
        }.resume()
    }

    /// Saturation-weighted average hue of the artwork (nil for black-and-white covers).
    static func dominantHue(of image: NSImage) -> Float? {
        let n = 24
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var x: Float = 0, y: Float = 0, total: Float = 0
        for i in 0..<(n * n) {
            let c = NSColor(red: CGFloat(data[i * 4]) / 255, green: CGFloat(data[i * 4 + 1]) / 255,
                            blue: CGFloat(data[i * 4 + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
            let w = Float(s * b)
            let a = Float(h) * 2 * .pi
            x += cos(a) * w; y += sin(a) * w; total += w
        }
        guard total > Float(n * n) * 0.08 else { return nil }
        let hue = atan2(y, x) / (2 * .pi)
        return hue < 0 ? hue + 1 : hue
    }
}

/// Follows Spotify and Apple Music together; whichever started playing most recently is "current".
final class NowPlayingHub {
    let watchers = MusicPlayer.allCases.map(PlayerWatcher.init)
    var onChange: ((NowPlayingTrack?) -> Void)?
    var onArtwork: ((NSImage, _ hue: Float?) -> Void)?
    private var active: Int?

    var track: NowPlayingTrack? { active.flatMap { watchers[$0].track } }

    func start() {
        for (i, w) in watchers.enumerated() {
            w.onChange = { [weak self] t in self?.changed(i, t) }
            w.onArtwork = { [weak self] img, hue in
                if self?.active == i { self?.onArtwork?(img, hue) }
            }
            w.start()
        }
    }

    private func changed(_ i: Int, _ t: NowPlayingTrack?) {
        if t?.playing == true {
            let switched = active != i
            active = i
            onChange?(t)
            if switched, let art = watchers[i].artwork { onArtwork?(art.image, art.hue) }
        } else if active == i || active == nil {
            // Paused/stopped in the current player — unless the other one is playing right now.
            if let other = watchers.indices.first(where: { $0 != i && watchers[$0].track?.playing == true }) {
                active = other
            } else {
                active = t == nil ? nil : i
            }
            onChange?(track)
        }
    }
}

/// Album art + title card shown over the visuals.
final class NowPlayingCard: NSView {
    private let art = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let album = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        layer?.cornerRadius = 12

        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 8
        art.layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        artist.font = .systemFont(ofSize: 15, weight: .medium)
        album.font = .systemFont(ofSize: 13)
        for (l, a) in [(title, 0.95), (artist, 0.85), (album, 0.6)] {
            l.textColor = NSColor(white: 1, alpha: a)
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [title, artist, album])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [art, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 18)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            art.widthAnchor.constraint(equalToConstant: 96),
            art.heightAnchor.constraint(equalToConstant: 96),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ t: NowPlayingTrack) {
        title.stringValue = t.title
        artist.stringValue = t.artist
        album.stringValue = t.album
    }

    func setArtwork(_ img: NSImage?) {
        art.image = img
        art.isHidden = img == nil
    }
}

/// Appends to ~/Library/Logs/Wavedrop.log (handy for checking background behaviour).
func debugLog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Wavedrop.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: url)
    }
}
