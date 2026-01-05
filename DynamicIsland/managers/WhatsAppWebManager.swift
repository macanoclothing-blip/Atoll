import Foundation
import WebKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class WhatsAppWebManager: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = WhatsAppWebManager()
    
    @Published var isAuthenticated = false
    @Published var qrCodeImage: NSImage?
    @Published var connectionStatus: String = "Initializing..."
    @Published var isEphemeral: Bool = false {
        didSet {
            setupWebView() // Re-init with new store
        }
    }
    private var webView: WKWebView!
    private let waUrl = URL(string: "https://web.whatsapp.com")!
    
    // Cache for profile pictures: chatId -> Image
    private var profilePicCache = [String: NSImage]()
    private var profilePicCallbacks = [String: [(NSImage?) -> Void]]()
    
    // User Agent for WhatsApp Web to work correctly
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    
    override init() {
        super.init()
        setupWebView()
    }
    
    private func setupWebView() {
        objectWillChange.send()
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        
        // Register for script messages
        contentController.add(self, name: "waBridge")
        contentController.add(self, name: "waLog")
        configuration.userContentController = contentController
        
        // Persistent or Ephemeral storage
        configuration.websiteDataStore = isEphemeral ? .nonPersistent() : .default()
        
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = userAgent
        
        // Enable inspector
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        // Inject WA-JS via UserScript (Local File - CSP Safe)
        let scriptPath = "/Users/delli/Desktop/Atoll/Atoll successi/messaggi/Atoll/DynamicIsland/wppconnect-wa.js"
        if let localJs = try? String(contentsOfFile: scriptPath) {
            let waJsScript = WKUserScript(
                source: """
                \(localJs)
                (function() {
                    WPP.webpack.onReady(() => {
                        window.webkit.messageHandlers.waLog.postMessage('WPP Ready (Local)');
                        WPP.config.poweredBy = 'Atoll';
                    });
                })();
                """,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(waJsScript)
            print("WhatsAppWebManager: 📦 Local WA-JS injected successfully")
        } else {
            print("WhatsAppWebManager: ❌ ERROR: Could not find local WA-JS at \(scriptPath)")
        }
        
        let bridgeScript = WKUserScript(
            source: """
            function log(msg) {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.waLog) {
                    window.webkit.messageHandlers.waLog.postMessage(msg);
                }
            }

            function checkAuth() {
                // Check for authenticated state with multiple common selectors
                const authSelectors = [
                    '#side',
                    '._ak8l',
                    '[data-testid="side-panel"]',
                    '[data-asset-chat-background]',
                    '.two', 
                    '#pane-side',
                    '[data-testid="chat-list-search"]'
                ];
                
                const isAuth = authSelectors.some(s => !!document.querySelector(s));
                
                if (isAuth) {
                    log('JS: Auth detected! Sending AUTH_SUCCESS...');
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.waBridge) {
                        window.webkit.messageHandlers.waBridge.postMessage({ type: 'AUTH_SUCCESS' });
                    }
                    return;
                }

                // QR Logic
                const selectors = [
                    'canvas[aria-label="Scan me!"]',
                    'canvas',
                    'div[data-ref] canvas'
                ];

                let qrCanvas = null;
                for (const selector of selectors) {
                    qrCanvas = document.querySelector(selector);
                    if (qrCanvas) break;
                }
                
                if (qrCanvas) {
                    try {
                        const qrData = qrCanvas.toDataURL();
                        window.webkit.messageHandlers.waBridge.postMessage({ type: 'QR_CODE', data: qrData });
                    } catch (e) {
                        // log('Error getting canvas data: ' + e.message);
                    }
                } else {
                    const reloadBtn = document.querySelector('button span[data-icon="refresh-light"]')?.closest('button');
                    if (reloadBtn) {
                        log('QR expired, clicking reload');
                        reloadBtn.click();
                    }
                }
            }
            
            // Inject WA-JS Library (WPPConnect) listener
            (function() {
                setInterval(() => {
                    if (window.WPP && window.WPP.chat && !window.waMsgListenerAttached) {
                        WPP.chat.on('msg-upsert', (msg) => {
                            if (msg.isNewMsg && !msg.fromMe) {
                                window.webkit.messageHandlers.waBridge.postMessage({ 
                                    type: 'MSG_EVENT', 
                                    chatId: msg.from?._serialized || msg.from,
                                    body: msg.body,
                                    sender: msg.sender?.name || msg.sender?.pushname || msg.sender?.id?._serialized
                                });
                            }
                        });
                        window.waMsgListenerAttached = true;
                        log('JS: msg-upsert listener attached');
                    }
                    checkAuth();
                }, 1500);
                checkAuth();
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(bridgeScript)
        
        // Prevent media playback or other background noises
        webView.configuration.mediaTypesRequiringUserActionForPlayback = .all
        
        load()
    }
    
    func load() {
        connectionStatus = "Connecting to WhatsApp..."
        webView.load(URLRequest(url: waUrl))
    }
    
    func reload() {
        webView.reload()
    }
    
    func hardReset() {
        print("WhatsAppWebManager: ⚠️ Performing hard reset...")
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                print("WhatsAppWebManager: 🧹 Data cleared. Loading fresh...")
                DispatchQueue.main.async {
                    self.isAuthenticated = false
                    self.qrCodeImage = nil
                    self.load()
                }
            }
        }
    }
    
    // MARK: - Sending Messages
    
    func sendMessage(to phone: String, text: String) {
        var chatId = phone
        
        // If it's just a number, normalize it to @c.us
        if !chatId.contains("@") {
            let clean = chatId.replacingOccurrences(of: "+", with: "")
                             .replacingOccurrences(of: " ", with: "")
            chatId = "\(clean)@c.us"
        } else if chatId.contains("@s.whatsapp.net") {
            chatId = chatId.replacingOccurrences(of: "@s.whatsapp.net", with: "@c.us")
        }
        
        let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "'", with: "\\'")
                             .replacingOccurrences(of: "\n", with: "\\n")
        
        print("WhatsAppWebManager: ✉️ Attempting to send to \(chatId)")
        
        let js = """
        (async () => {
            try {
                // Wait up to 5 seconds for WPP to be ready
                for (let i = 0; i < 10; i++) {
                    if (typeof WPP !== 'undefined' && WPP.chat && WPP.webpack.isReady) break;
                    log('Waiting for WPP... (' + i + ')');
                    await new Promise(r => setTimeout(r, 500));
                }

                if (typeof WPP === 'undefined' || !WPP.chat) {
                    throw new Error('WPP Library failed to initialize in time');
                }
                
                log('Calling WPP.chat.sendTextMessage to ' + '\(chatId)');
                if (typeof WPP.chat.sendTextMessage !== 'function') {
                    log('DEBUG: WPP.chat keys: ' + Object.keys(WPP.chat).join(', '));
                    throw new Error('sendTextMessage is not a function in WPP.chat');
                }
                const result = await WPP.chat.sendTextMessage('\(chatId)', '\(escapedText)');
                
                log('Message sent successfully');
                window.webkit.messageHandlers.waBridge.postMessage({ type: 'SEND_SUCCESS', chatId: '\(chatId)' });
                return "SUCCESS";
            } catch (e) {
                log('Error in sendTextMessage: ' + e.message);
                window.webkit.messageHandlers.waBridge.postMessage({ 
                    type: 'SEND_ERROR', 
                    chatId: '\(chatId)', 
                    error: e.message 
                });
            }
        })();
        """
        
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js) { (result, error) in
                if let error = error {
                    print("WhatsAppWebManager: ❌ JS Evaluation Error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func sendFile(to phone: String, fileURL: URL, caption: String) {
        // 1. Normalize phone
        var chatId = phone
        if !chatId.contains("@") {
            let clean = chatId.replacingOccurrences(of: "+", with: "")
                             .replacingOccurrences(of: " ", with: "")
            chatId = "\(clean)@c.us"
        } else if chatId.contains("@s.whatsapp.net") {
            chatId = chatId.replacingOccurrences(of: "@s.whatsapp.net", with: "@c.us")
        }
        
        // 2. Read file and convert to Base64
        guard let fileData = try? Data(contentsOf: fileURL) else {
            print("WhatsAppWebManager: ❌ Failed to read file data at \(fileURL)")
            return
        }
        
        print("WhatsAppWebManager: 📄 Preparing to send file: \(fileURL.lastPathComponent) (\(fileData.count) bytes)")
        
        let base64 = fileData.base64EncodedString()
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let dataUrl = "data:\(mimeType);base64,\(base64)"
        let fileName = fileURL.lastPathComponent.replacingOccurrences(of: "'", with: "\\'")
        
        let escapedCaption = caption.replacingOccurrences(of: "\\", with: "\\\\")
                                    .replacingOccurrences(of: "'", with: "\\'")
                                    .replacingOccurrences(of: "\n", with: "\\n")

        // 3. Inject JS
        let js = """
        (async () => {
            try {
                log('JS: Starting file send for \(chatId)');
                
                // Wait for WPP
                for (let i = 0; i < 15; i++) {
                    if (typeof WPP !== 'undefined' && WPP.chat && WPP.webpack.isReady) break;
                    log('JS: Waiting for WPP to send file... (' + i + ')');
                    await new Promise(r => setTimeout(r, 500));
                }

                if (typeof WPP === 'undefined' || !WPP.chat) {
                    throw new Error('WPP Library failed to initialize in time');
                }
                
                log('JS: Calling WPP.chat.sendFile to \(chatId)');
                
                if (typeof WPP.chat.sendFile !== 'function') {
                    log('DEBUG: WPP.chat keys: ' + Object.keys(WPP.chat).join(', '));
                    // Try to use sendFileMessage as fallback if it exists
                    if (typeof WPP.chat.sendFileMessage === 'function') {
                        log('JS: Falling back to WPP.chat.sendFileMessage');
                        const result = await WPP.chat.sendFileMessage('\(chatId)', '\(dataUrl)', {
                            type: 'document',
                            filename: '\(fileName)',
                            caption: '\(escapedCaption)'
                        });
                        return result;
                    }
                    throw new Error('sendFile is not a function in WPP.chat');
                }

                // Using WPP.chat.sendFile which is robust for dataUrls
                const result = await WPP.chat.sendFile('\(chatId)', '\(dataUrl)', {
                    type: 'document',
                    filename: '\(fileName)',
                    caption: '\(escapedCaption)'
                });
                
                log('JS: File send result: ' + JSON.stringify(result));
                
                window.webkit.messageHandlers.waBridge.postMessage({ 
                    type: 'SEND_SUCCESS', 
                    chatId: '\(chatId)' 
                });
            } catch (e) {
                log('JS ERROR sending file: ' + e.message);
                window.webkit.messageHandlers.waBridge.postMessage({ 
                    type: 'SEND_ERROR', 
                    chatId: '\(chatId)', 
                    error: e.message 
                });
            }
        })();
        """
        
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js) { (result, error) in
                if let error = error {
                    print("WhatsAppWebManager: ❌ JS SendFile Evaluation Error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    
    // MARK: - Profile Pictures
    
    func getProfilePicture(for phone: String, completion: @escaping (NSImage?) -> Void) {
        getProfilePicture(candidates: [phone], completion: completion)
    }
    
    func getProfilePicture(candidates: [String], completion: @escaping (NSImage?) -> Void) {
        print("WhatsAppWebManager: 🖼️ Starting fetch request for candidates: \(candidates)")
        
        let validCandidates = candidates.map { candidate -> String in
            var chatId = candidate
            if !chatId.contains("@") && CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: chatId.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: " ", with: ""))) {
                let clean = chatId.replacingOccurrences(of: "+", with: "")
                                 .replacingOccurrences(of: " ", with: "")
                return "\(clean)@c.us"
            } else if chatId.contains("@s.whatsapp.net") {
                return chatId.replacingOccurrences(of: "@s.whatsapp.net", with: "@c.us")
            }
            return chatId // Could be a name or already a JID
        }
        
        let firstChatId = validCandidates.first ?? ""
        
        // Caching check for the first candidate
        if let cached = profilePicCache[firstChatId] {
            completion(cached)
            return
        }
        
        // Queue the callback
        if profilePicCallbacks[firstChatId] != nil {
            profilePicCallbacks[firstChatId]?.append(completion)
            return
        } else {
            profilePicCallbacks[firstChatId] = [completion]
        }
        
        let js = """
        (async () => {
            try {
                log('JS: Starting profile pic fetch for candidates: \(validCandidates)');
                
                // Wait for WPP
                let wppReady = false;
                for (let i = 0; i < 15; i++) {
                    if (typeof WPP !== 'undefined' && WPP.contact && WPP.webpack.isReady) {
                        wppReady = true;
                        break;
                    }
                    await new Promise(r => setTimeout(r, 500));
                }

                if (!wppReady) {
                    log('JS ERROR: WPP Library not ready (WPP available: ' + (typeof WPP !== 'undefined') + ')');
                    window.webkit.messageHandlers.waBridge.postMessage({ 
                        type: 'PROFILE_PIC_ERROR', 
                        chatId: '\(firstChatId)', 
                        error: 'WPP Library not ready' 
                    });
                    return;
                }
                
                const candidates = \(validCandidates);
                log('JS: Searching profiles for: ' + candidates.join(', '));
                
                let foundUrl = null;
                let foundId = null;
                
                for (const id of candidates) {
                    try {
                        log('JS: Checking ID/Name: ' + id);
                        let picUrl = null;
                        
                        // 🟢 PRIVATE API FALLBACK: Try direct Store access if WPP is limited
                        const getDirectUrl = async (jid) => {
                            try {
                                if (window.Store) {
                                    if (window.Store.ProfilePic) {
                                        log('JS: Trying Store.ProfilePic for ' + jid);
                                        let pic = window.Store.ProfilePic.get(jid);
                                        if (!pic || !pic.img) pic = await window.Store.ProfilePic.find(jid);
                                        if (pic && pic.img) { log('JS: Found via Store.ProfilePic'); return pic.img; }
                                    }
                                    if (window.Store.Contact) {
                                        log('JS: Trying Store.Contact for ' + jid);
                                        const c = window.Store.Contact.get(jid);
                                        if (c && c.profilePic && c.profilePic.img) { log('JS: Found via Store.Contact'); return c.profilePic.img; }
                                    }
                                }
                                if (window.WPP && window.WPP.contact) {
                                    log('JS: Trying WPP.contact for ' + jid);
                                    // Try getProfilePictureUrl first, then getProfilePicture
                                    let url = null;
                                    if (typeof WPP.contact.getProfilePictureUrl === 'function') {
                                        url = await WPP.contact.getProfilePictureUrl(jid);
                                    } else if (typeof WPP.contact.getProfilePicture === 'function') {
                                        url = await WPP.contact.getProfilePicture(jid);
                                    }
                                    return url;
                                }
                            } catch (e) { log('JS Store Error: ' + e.message); }
                            return null;
                        };

                        // If it looks like a name, try to find the contact first
                        if (!id.includes('@')) {
                            const contacts = await WPP.contact.list();
                            log('JS: Searching name "' + id + '" in ' + contacts.length + ' contacts');
                            const match = contacts.find(c => c.name?.toLowerCase() === id.toLowerCase() || c.pushname?.toLowerCase() === id.toLowerCase() || c.id?.user === id);
                            
                            if (match) {
                                const mId = match.id?._serialized || match.id || id;
                                log('JS: Found contact by name! ID: ' + mId);
                                picUrl = await getDirectUrl(mId);
                                if (picUrl) { foundId = id; foundUrl = picUrl; break; }
                            } else {
                                log('JS: Name search failed for "' + id + '"');
                            }
                        } else {
                            picUrl = await getDirectUrl(id);
                            if (picUrl) { foundId = id; foundUrl = picUrl; break; }
                        }
                    } catch (err) {
                        log('JS ERROR checking ' + id + ': ' + err.message);
                    }
                }
                
                if (foundUrl) {
                    log('JS SUCCESS: Profile pic URL found: ' + foundUrl);
                    window.webkit.messageHandlers.waBridge.postMessage({ 
                        type: 'PROFILE_PIC_URL', 
                        chatId: '\(firstChatId)', 
                        url: foundUrl 
                    });
                } else {
                    log('JS: No profile pic found for any candidate');
                    window.webkit.messageHandlers.waBridge.postMessage({ 
                        type: 'PROFILE_PIC_EMPTY', 
                        chatId: '\(firstChatId)' 
                    });
                }
            } catch (e) {
                log('JS UNCAUGHT ERROR: ' + e.message);
                window.webkit.messageHandlers.waBridge.postMessage({ 
                    type: 'PROFILE_PIC_ERROR', 
                    chatId: '\(firstChatId)', 
                    error: e.message 
                });
            }
        })();
        """
        
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js)
        }
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        connectionStatus = "WhatsApp Web Loaded"
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        connectionStatus = "Load Error"
        print("WhatsAppWebManager: ❌ Navigation failed: \(error.localizedDescription)")
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        connectionStatus = "Connection Error"
        print("WhatsAppWebManager: ❌ Provisional navigation failed: \(error.localizedDescription)")
    }
    
    
    // MARK: - WKScriptMessageHandler
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "waLog" {
            if let log = message.body as? String {
                print("WhatsAppWebManager [JS]: \(log)")
            }
            return
        }
        
        guard message.name == "waBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { 
            print("WhatsAppWebManager: 📥 Received unknown message: \(message.name)")
            return 
        }
        
        print("WhatsAppWebManager: 📥 Bridge type: \(type)")
        
        switch type {
        case "AUTH_SUCCESS":
            if !isAuthenticated {
                print("WhatsAppWebManager: 🔓 Auth Success Received!")
                DispatchQueue.main.async {
                    self.isAuthenticated = true
                    self.qrCodeImage = nil
                    self.connectionStatus = "Connected"
                }
            }
        case "QR_CODE":
            if let dataUrl = body["data"] as? String {
                print("WhatsAppWebManager: 📑 Received QR data (\(dataUrl.count) bytes)")
                processQRData(dataUrl)
            }
        case "SEND_SUCCESS":
            let id = body["chatId"] as? String ?? "unknown"
            print("WhatsAppWebManager: ✅ Message confirmed sent to \(id)")
        case "SEND_ERROR":
            let err = body["error"] as? String ?? "unknown error"
            print("WhatsAppWebManager: ❌ Message failed: \(err)")
        case "PROFILE_PIC_URL":
            if let chatId = body["chatId"] as? String, let urlString = body["url"] as? String {
                downloadProfilePic(chatId: chatId, urlString: urlString)
            }
        case "PROFILE_PIC":
            if let chatId = body["chatId"] as? String, let dataUrl = body["data"] as? String {
                handleProfilePicData(chatId, dataUrl: dataUrl)
            }
        case "PROFILE_PIC_EMPTY":
            if let chatId = body["chatId"] as? String {
                print("WhatsAppWebManager: ⚪ Profile pic EMPTY for \(chatId)")
                let callbacks = profilePicCallbacks.removeValue(forKey: chatId)
                callbacks?.forEach { $0(nil) }
            }
        case "PROFILE_PIC_ERROR":
            if let chatId = body["chatId"] as? String, let err = body["error"] as? String {
                print("WhatsAppWebManager: ❌ Profile pic ERROR for \(chatId): \(err)")
                let callbacks = profilePicCallbacks.removeValue(forKey: chatId)
                callbacks?.forEach { $0(nil) }
            }
        default:
            break
        }
    }
    
    private func processQRData(_ dataUrl: String) {
        let parts = dataUrl.components(separatedBy: ",")
        guard parts.count > 1 else { 
            print("WhatsAppWebManager: ❌ Invalid Data URL format")
            return 
        }
        
        guard let data = Data(base64Encoded: parts[1]) else { 
            print("WhatsAppWebManager: ❌ Failed to decode base64 QR data")
            return 
        }
        
        if let image = NSImage(data: data) {
            Task { @MainActor in
                self.qrCodeImage = image
                self.connectionStatus = "Scan QR to connect"
            }
        } else {
            print("WhatsAppWebManager: ❌ Failed to create NSImage from QR data")
        }
    }

    private func downloadProfilePic(chatId: String, urlString: String) {
        guard let url = URL(string: urlString) else { return }
        
        print("WhatsAppWebManager: 🌐 Downloading profile pic from URL: \(urlString)")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                print("WhatsAppWebManager: ❌ Download error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    let callbacks = self?.profilePicCallbacks.removeValue(forKey: chatId)
                    callbacks?.forEach { $0(nil) }
                }
                return
            }
            
            if let response = response as? HTTPURLResponse {
                print("WhatsAppWebManager: 🌐 Response code: \(response.statusCode) for \(chatId)")
            }

            guard let data = data else {
                print("WhatsAppWebManager: ❌ No data received for \(chatId)")
                DispatchQueue.main.async {
                    let callbacks = self?.profilePicCallbacks.removeValue(forKey: chatId)
                    callbacks?.forEach { $0(nil) }
                }
                return
            }
            
            print("WhatsAppWebManager: 📥 Received \(data.count) bytes for \(chatId)")
            
            guard let image = NSImage(data: data) else {
                print("WhatsAppWebManager: ❌ Failed to create NSImage from data (\(data.count) bytes) for \(chatId)")
                // Try to dump some data for debug if it's small or just type
                if let str = String(data: data.prefix(100), encoding: .utf8) {
                    print("WhatsAppWebManager: 📝 Data prefix (UTF8): \(str)")
                }
                
                DispatchQueue.main.async {
                    let callbacks = self?.profilePicCallbacks.removeValue(forKey: chatId)
                    callbacks?.forEach { $0(nil) }
                }
                return
            }
            
            DispatchQueue.main.async {
                self?.profilePicCache[chatId] = image
                let callbacks = self?.profilePicCallbacks.removeValue(forKey: chatId)
                callbacks?.forEach { $0(image) }
                print("WhatsAppWebManager: ✅ Profile pic successfully created, cached and sent to callbacks for \(chatId)")
            }
        }.resume()
    }

    private func handleProfilePicData(_ chatId: String, dataUrl: String) {
        let parts = dataUrl.components(separatedBy: ",")
        guard parts.count > 1, let data = Data(base64Encoded: parts[1]) else { return }
        
        if let image = NSImage(data: data) {
            profilePicCache[chatId] = image
            let callbacks = profilePicCallbacks.removeValue(forKey: chatId)
            callbacks?.forEach { $0(image) }
            print("WhatsAppWebManager: 🖼️ Profile pic (Base64) cached for \(chatId). Size: \(image.size)")
        } else {
            print("WhatsAppWebManager: ❌ Failed to create image from Base64 data for \(chatId)")
        }
    }

    // This is useful for debugging or showing the link UI
    func getWebView() -> WKWebView {
        return webView
    }
    
    func forceAuthCheck() {
        print("WhatsAppWebManager: ⚡️ Manual Auth Check requested")
        let js = "checkAuth();"
        webView.evaluateJavaScript(js)
    }
    
    // Safety method to manually set as authenticated if detection fails
    func manualAuthOverride() {
        print("WhatsAppWebManager: ⚠️ MANUAL AUTH OVERRIDE TRIGGERED")
        DispatchQueue.main.async {
            self.isAuthenticated = true
            self.qrCodeImage = nil
            self.connectionStatus = "Connected (Manual)"
        }
    }
}
