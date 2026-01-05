import Foundation
import WebKit
import Combine
import SwiftUI

@MainActor
class TelegramWebManager: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = TelegramWebManager()
    
    @Published var isAuthenticated = false
    @Published var connectionStatus: String = "Initializing..."
    
    private var webView: WKWebView!
    // Using K version as it's often lighter/simpler DOM
    private let telegramUrl = URL(string: "https://web.telegram.org/k/")! 
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    
    override init() {
        super.init()
        setupWebView()
    }
    
    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        
        contentController.add(self, name: "telegramBridge")
        configuration.userContentController = contentController
        
        configuration.websiteDataStore = .default()
        
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = userAgent
        
        // Inject Auth Monitor
        let authScript = WKUserScript(
            source: """
            setInterval(() => {
                // Check if logged in (look for chat list)
                if (document.querySelector('.chat-list')) {
                    window.webkit.messageHandlers.telegramBridge.postMessage({ type: 'AUTH_SUCCESS' });
                }
            }, 2000);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(authScript)
        
        load()
    }
    
    func load() {
        connectionStatus = "Connecting to Telegram..."
        webView.load(URLRequest(url: telegramUrl))
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "telegramBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        
        if type == "AUTH_SUCCESS" {
            if !isAuthenticated {
                isAuthenticated = true
                connectionStatus = "Connected"
                print("TelegramWebManager: 🔓 Authenticated!")
            }
        }
    }
    
    func getWebView() -> WKWebView {
        return webView
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        connectionStatus = "Telegram Loaded"
    }
    
    // MARK: - Sending Logic
    func sendReply(username: String?, text: String) {
        guard isAuthenticated else {
            print("TelegramWebManager: ❌ Not authenticated")
            return
        }
        
        // If we have a username, we can try to route to it
        if let username = username, username.starts(with: "@") || !username.contains(" ") {
            // Strip @ if present for URL
            let cleanUser = username.replacingOccurrences(of: "@", with: "")
            let targetUrl = "https://web.telegram.org/k/#@\(cleanUser)"
            print("TelegramWebManager: 🚀 Navigating to \(targetUrl)")
            webView.load(URLRequest(url: URL(string: targetUrl)!))
        } else {
            print("TelegramWebManager: ⚠️ No valid username, attempting reply in current context (risky)")
        }
        
        let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "'", with: "\\'")
                              .replacingOccurrences(of: "\n", with: "\\n")
        
        let js = """
        (async () => {
             async function typeMessage(message) {
                 // Wait for input
                 let input = null;
                 for(let i=0; i<20; i++) {
                     input = document.querySelector('.input-message-input');
                     if(input) break;
                     await new Promise(r => setTimeout(r, 500));
                 }
                 
                 if(!input) {
                     console.log("TelegramWebManager: Input not found");
                     return;
                 }
                 
                 input.focus();
                 document.execCommand('insertText', false, message);
                 
                 await new Promise(r => setTimeout(r, 100));
                 
                 // Press Enter
                 input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', which: 13, bubbles: true }));
             }
             
             await typeMessage('\(escapedText)');
        })();
        """
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.webView.evaluateJavaScript(js)
        }
    }
}
