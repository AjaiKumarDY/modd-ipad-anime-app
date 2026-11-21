import UIKit
import AVKit
import AVFoundation
import WebKit

// MARK: - Uranex Player Manager

final class UranexPlayerManager: NSObject, WKScriptMessageHandler {

    static let shared = UranexPlayerManager()

    // MARK: - Weak References

    weak var rootViewController: UIViewController?
    weak var webView: WKWebView?

    // MARK: - Player Components

    private(set) var playerViewController: AVPlayerViewController?
    private(set) var player: AVPlayer?

    private var currentAsset: AVURLAsset?
    private var currentItem: AVPlayerItem?
    private var statusObserver: NSKeyValueObservation?

    // MARK: - Status Overlay (High-Tech Theme: #0b111b, #00d4ff, Orbitron)

    private var statusOverlayView: UIView?
    private var statusTitleLabel: UILabel?
    private var statusSubtitleLabel: UILabel?
    private var statusSpinner: UIActivityIndicatorView?

    // MARK: - Current Playback Session State

    private var activeEpisodeId: String = ""
    private var activeEpisodeNum: Int = 1
    private var activeSlug: String = ""
    private var activeTitle: String = ""
    private var activeApiBase: String = ""
    private var activePreferredServer: String = "hd-1"
    private var activeCategory: String = "sub"

    private var inlineRect: CGRect = .zero
    private var isPlayingInline = false

    private override init() {
        super.init()
    }

    // MARK: - Setup & Initialization

    func setup(rootViewController: UIViewController, webView: WKWebView) {
        self.rootViewController = rootViewController
        self.webView = webView

        configureAudioSession()

        // Register WebKit script message handler
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: "uranexNative")
        contentController.add(self, name: "uranexNative")

        print("UranexPlayerManager initialized with native AVPlayerViewController bridge.")
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("UranexPlayerManager: Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
    }

    // MARK: - 1 GB RAM Protection for Binge-Watching (Apple A7 / iPad mini 2)

    func cleanupCurrentPlayerItem() {
        statusObserver?.invalidate()
        statusObserver = nil

        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)

        if let p = player {
            p.pause()
            // Release the previous AVPlayerItem
            p.replaceCurrentItem(with: nil)
        }

        currentItem = nil
        currentAsset = nil

        // Clear URLCache memory to prevent Jetsam OOM crashes when binge-watching
        URLCache.shared.removeAllCachedResponses()
    }

    @objc func handleMemoryWarning() {
        print("UranexPlayerManager: Memory warning received, clearing URLCache...")
        URLCache.shared.removeAllCachedResponses()
        if player?.timeControlStatus != .playing {
            cleanupCurrentPlayerItem()
        }
    }

    // MARK: - AVPlayerViewController Lifecycle

    private func ensurePlayerViewController() -> AVPlayerViewController {
        if let existing = playerViewController {
            return existing
        }

        let pvc = AVPlayerViewController()
        pvc.showsPlaybackControls = true
        pvc.updatesNowPlayingInfoCenter = true
        pvc.view.backgroundColor = UIColor(red: 11/255.0, green: 17/255.0, blue: 27/255.0, alpha: 1.0) // #0b111b

        let p = AVPlayer()
        pvc.player = p
        self.player = p
        self.playerViewController = pvc

        setupStatusOverlay(in: pvc)

        return pvc
    }

    // MARK: - High-Tech Dark Theme Overlay (#0b111b background, #00d4ff cyan accents, Orbitron)

    private func setupStatusOverlay(in pvc: AVPlayerViewController) {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor(red: 11/255.0, green: 17/255.0, blue: 27/255.0, alpha: 0.90) // #0b111b
        container.layer.borderColor = UIColor(red: 0/255.0, green: 212/255.0, blue: 255/255.0, alpha: 0.8).cgColor // #00d4ff
        container.layer.borderWidth = 1.0
        container.layer.cornerRadius = 8.0
        container.clipsToBounds = true
        container.isUserInteractionEnabled = true

        let spinner = UIActivityIndicatorView(style: .white)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = UIColor(red: 0/255.0, green: 212/255.0, blue: 255/255.0, alpha: 1.0) // #00d4ff cyan
        spinner.hidesWhenStopped = true

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = UIColor(red: 0/255.0, green: 212/255.0, blue: 255/255.0, alpha: 1.0) // #00d4ff
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.font = UIFont(name: "Orbitron-Bold", size: 12) ?? UIFont.boldSystemFont(ofSize: 12)
        titleLabel.text = "URANEX NATIVE STREAM"

        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.textColor = UIColor.white
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2
        subtitleLabel.font = UIFont(name: "Orbitron-Regular", size: 10) ?? UIFont.systemFont(ofSize: 10)
        subtitleLabel.text = "Resolving stream..."

        container.addSubview(spinner)
        container.addSubview(titleLabel)
        container.addSubview(subtitleLabel)

        // Overlay is attached to pvc.view
        pvc.view.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: pvc.view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: pvc.view.centerYAnchor),
            container.widthAnchor.constraint(lessThanOrEqualTo: pvc.view.widthAnchor, constant: -32),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            spinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            titleLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            subtitleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])

        self.statusOverlayView = container
        self.statusSpinner = spinner
        self.statusTitleLabel = titleLabel
        self.statusSubtitleLabel = subtitleLabel
    }

    private func showStatusOverlay(title: String? = nil, message: String, showSpinner: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusOverlayView?.isHidden = false
            if let t = title { self.statusTitleLabel?.text = t }
            self.statusSubtitleLabel?.text = message
            if showSpinner {
                self.statusSpinner?.startAnimating()
            } else {
                self.statusSpinner?.stopAnimating()
            }
        }
    }

    private func hideStatusOverlay() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusSpinner?.stopAnimating()
            UIView.animate(withDuration: 0.3) {
                self.statusOverlayView?.alpha = 0.0
            } completion: { _ in
                self.statusOverlayView?.isHidden = true
                self.statusOverlayView?.alpha = 1.0
            }
        }
    }

    // MARK: - Playback Session Controller

    func playEpisode(
        episodeId: String,
        episodeNum: Int,
        slug: String,
        title: String,
        apiBase: String,
        category: String,
        preferredServer: String,
        rect: CGRect
    ) {
        // 1. Release previous item and clear cache for binge-watching memory safety
        cleanupCurrentPlayerItem()

        self.activeEpisodeId = episodeId
        self.activeEpisodeNum = episodeNum
        self.activeSlug = slug
        self.activeTitle = title
        self.activeApiBase = apiBase
        self.activeCategory = category
        self.activePreferredServer = preferredServer
        self.inlineRect = rect

        configureAudioSession()

        // 2. Attach inline AVPlayerViewController
        attachInlinePlayer(rect: rect)

        // 3. Show loading status
        showStatusOverlay(
            title: "URANEX NATIVE PLAYER",
            message: "Looking for a direct stream (\(preferredServer.uppercased()))...",
            showSpinner: true
        )

        // 4. Resolve direct stream URL with fallback cascade
        startStreamResolution()
    }

    private func startStreamResolution() {
        StreamResolver.shared.resolveStream(
            episodeId: activeEpisodeId,
            episodeNum: activeEpisodeNum,
            slug: activeSlug,
            apiBase: activeApiBase,
            preferredServer: activePreferredServer,
            category: activeCategory,
            statusUpdate: { [weak self] statusText in
                self?.showStatusOverlay(message: statusText, showSpinner: true)
                self?.notifyWebState(state: "resolving", message: statusText)
            }
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let source):
                    self.loadResolvedStreamIntoPlayer(source: source)
                case .failure(let error):
                    let errMsg = error.localizedDescription
                    print("UranexPlayerManager: Stream resolution failed: \(errMsg)")
                    self.showStatusOverlay(
                        title: "STREAM OFFLINE",
                        message: "\(errMsg)\nTap a different server pill below.",
                        showSpinner: false
                    )
                    self.notifyWebState(state: "error", message: errMsg)
                }
            }
        }
    }

    // MARK: - Pass Custom Referer & UserAgent Headers into AVURLAsset

    private func loadResolvedStreamIntoPlayer(source: StreamSource) {
        showStatusOverlay(message: "Connecting to \(source.serverName.uppercased()) stream...", showSpinner: true)

        let resolvedReferer = source.referer
        let userAgent = source.userAgent

        // Pass custom headers into AVURLAsset
        let headers: [String: String] = [
            "Referer": resolvedReferer,
            "User-Agent": userAgent
        ]

        let asset = AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        self.currentAsset = asset

        let item = AVPlayerItem(asset: asset)
        // 1 GB RAM Protection: restrict forward buffering duration
        item.preferredForwardBufferDuration = 15.0
        self.currentItem = item

        // Observe AVPlayerItem.status via KVO
        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch observedItem.status {
                case .readyToPlay:
                    print("UranexPlayerManager: AVPlayerItem ready to play (\(source.url.absoluteString)).")
                    self.hideStatusOverlay()
                    self.player?.play()
                    self.notifyWebState(state: "playing", message: "Playing via \(source.serverName.uppercased())")

                case .failed:
                    let errDesc = observedItem.error?.localizedDescription ?? "CDN playback failed (403 or decode error)"
                    print("UranexPlayerManager: AVPlayerItem failed: \(errDesc)")

                    // Display error in small status label on the player overlay
                    self.showStatusOverlay(
                        title: "STREAM ERROR",
                        message: "\(errDesc)\nRetrying next server...",
                        showSpinner: true
                    )
                    self.notifyWebState(state: "error", message: errDesc)

                    // Automatically try the next server/source
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.tryNextFallbackServer(failedServer: source.serverName)
                    }

                case .unknown:
                    break

                @unknown default:
                    break
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        let pvc = ensurePlayerViewController()
        pvc.player?.replaceCurrentItem(with: item)
    }

    private func tryNextFallbackServer(failedServer: String) {
        let serverCycle = ["hd-1", "hd-2", "megacloud", "consumet-zoro", "consumet-gogo", "allanime"]
        if let idx = serverCycle.firstIndex(of: failedServer.lowercased()), idx + 1 < serverCycle.count {
            activePreferredServer = serverCycle[idx + 1]
        } else {
            activePreferredServer = "consumet-gogo"
        }
        startStreamResolution()
    }

    @objc private func playerItemDidReachEnd(_ notification: Notification) {
        notifyWebState(state: "ended", message: "Episode playback completed")
    }

    // MARK: - Inline & Fullscreen Presentation

    func attachInlinePlayer(rect: CGRect) {
        guard let root = rootViewController else { return }
        let pvc = ensurePlayerViewController()

        if pvc.parent == nil {
            root.addChild(pvc)
            root.view.addSubview(pvc.view)
            pvc.didMove(toParent: root)
        }

        self.inlineRect = rect
        pvc.view.frame = rect
        pvc.view.isHidden = false
        isPlayingInline = true
        root.view.bringSubviewToFront(pvc.view)
    }

    func updateInlineRect(_ rect: CGRect) {
        self.inlineRect = rect
        guard let pvc = playerViewController, pvc.presentingViewController == nil else { return }

        // If scrolled off-screen, hide inline player to prevent overlapping navigation bars
        let screenH = UIScreen.main.bounds.height
        if rect.maxY <= 0 || rect.minY >= screenH || rect.width <= 0 || rect.height <= 0 {
            pvc.view.isHidden = true
        } else {
            pvc.view.isHidden = false
            pvc.view.frame = rect
        }
    }

    func presentFullscreen() {
        guard let root = rootViewController else { return }
        let pvc = ensurePlayerViewController()

        if pvc.presentingViewController != nil {
            return
        }

        root.present(pvc, animated: true) { [weak self] in
            self?.player?.play()
        }
    }

    func closePlayer() {
        cleanupCurrentPlayerItem()
        StreamResolver.shared.cancel()

        if let pvc = playerViewController {
            pvc.view.isHidden = true
            if pvc.presentingViewController != nil {
                pvc.dismiss(animated: true, completion: nil)
            }
        }
        isPlayingInline = false
        notifyWebState(state: "closed", message: "Player closed")
    }

    // MARK: - Web Communication

    private func notifyWebState(state: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.webView else { return }
            let safeMsg = message.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: " ")
            let js = "if(window.uranexOnNativePlayerState){ window.uranexOnNativePlayerState('\(state)', '\(safeMsg)'); }"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "uranexNative",
              let dict = message.body as? [String: Any],
              let action = dict["action"] as? String else {
            return
        }

        switch action {
        case "play":
            let epId = (dict["episodeId"] as? String) ?? ""
            let epNum = (dict["episodeNum"] as? Int) ?? 1
            let slug = (dict["slug"] as? String) ?? ""
            let title = (dict["title"] as? String) ?? ""
            let apiBase = (dict["apiBase"] as? String) ?? ""
            let cat = (dict["category"] as? String) ?? "sub"
            let srv = (dict["serverName"] as? String) ?? "hd-1"

            var rect = CGRect(x: 0, y: 56, width: UIScreen.main.bounds.width, height: 240)
            if let rDict = dict["rect"] as? [String: Any],
               let x = rDict["x"] as? CGFloat,
               let y = rDict["y"] as? CGFloat,
               let w = rDict["width"] as? CGFloat,
               let h = rDict["height"] as? CGFloat,
               w > 0 && h > 0 {
                rect = CGRect(x: x, y: y, width: w, height: h)
            }

            playEpisode(
                episodeId: epId,
                episodeNum: epNum,
                slug: slug,
                title: title,
                apiBase: apiBase,
                category: cat,
                preferredServer: srv,
                rect: rect
            )

        case "updateRect":
            if let rDict = dict["rect"] as? [String: Any],
               let x = rDict["x"] as? CGFloat,
               let y = rDict["y"] as? CGFloat,
               let w = rDict["width"] as? CGFloat,
               let h = rDict["height"] as? CGFloat {
                updateInlineRect(CGRect(x: x, y: y, width: w, height: h))
            }

        case "presentFullscreen":
            presentFullscreen()

        case "close":
            closePlayer()

        case "switchServer":
            if let srv = dict["serverName"] as? String, !srv.isEmpty {
                activePreferredServer = srv
                startStreamResolution()
            }

        case "switchCategory":
            if let cat = dict["category"] as? String, !cat.isEmpty {
                activeCategory = cat
                startStreamResolution()
            }

        default:
            break
        }
    }
}
