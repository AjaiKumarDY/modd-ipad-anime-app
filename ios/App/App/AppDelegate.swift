import UIKit
import WebKit
import Capacitor
import AVFoundation

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Configure hardware audio session for video playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AppDelegate: Failed to set audio session: \(error.localizedDescription)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let rootVC = self.window?.rootViewController as? CAPBridgeViewController,
               let webView = rootVC.webView {
                // Setup native hardware-accelerated video player bridge
                UranexPlayerManager.shared.setup(rootViewController: rootVC, webView: webView)

                // High-tech dark background for reliable WKWebView compositing on iOS 12
                webView.isOpaque = true
                webView.backgroundColor = UIColor(red: 11/255.0, green: 17/255.0, blue: 27/255.0, alpha: 1.0)
                webView.scrollView.backgroundColor = UIColor(red: 11/255.0, green: 17/255.0, blue: 27/255.0, alpha: 1.0)
            }
        }
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // 1 GB RAM Protection for iPad mini 2 (ME276HN/A, Apple A7, iOS 12.5.8)
        // Clear URLCache and trim media buffers to prevent Jetsam OOM kill
        URLCache.shared.removeAllCachedResponses()
        UranexPlayerManager.shared.handleMemoryWarning()
    }

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {}
    func applicationDidBecomeActive(_ application: UIApplication) {}
    func applicationWillTerminate(_ application: UIApplication) {
        UranexPlayerManager.shared.cleanupCurrentPlayerItem()
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        let statusBarRect = UIApplication.shared.statusBarFrame
        guard let touchPoint = event?.allTouches?.first?.location(in: self.window) else { return }
        if statusBarRect.contains(touchPoint) {
            NotificationCenter.default.post(name: .capacitorStatusBarTapped, object: nil)
        }
    }
}
