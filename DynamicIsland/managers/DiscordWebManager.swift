import Foundation
import WebKit
import Combine
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
class DiscordWebManager: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = DiscordWebManager()
    
    @Published var isAuthenticated = false
    @Published var connectionStatus: String = "Initializing..."
    private var discordToken: String?
    
    private var webView: WKWebView!
    private let discordUrl = URL(string: "https://discord.com/app")!
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    
    override init() {
        super.init()
        setupWebView()
    }
    
    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        
        contentController.add(self, name: "discordBridge")
        contentController.add(self, name: "logging")
        contentController.add(self, name: "discordStatus")
        configuration.userContentController = contentController
        
        // Persistent storage to keep login session
        configuration.websiteDataStore = .default()
        
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = userAgent
        
        // Inject Auth & Token Monitor
        let authScript = WKUserScript(
            source: """
            (function() {
                // Function to bridge logs
                window.logToSwift = function(msg) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.logging) {
                        window.webkit.messageHandlers.logging.postMessage(msg);
                    }
                    console.log(msg);
                };

                // Token Extraction Logic
                function extractToken() {
                    try {
                        // Method 1: Webpack internal store (most reliable for modern Discord)
                        if (window.webpackChunkdiscord_app) {
                            const token = (webpackChunkdiscord_app.push([[''],{},e=>{m=[];for(let c in e.c)m.push(e.c[c])}]),m)
                                .find(m => m?.exports?.default?.getToken !== undefined)
                                ?.exports?.default?.getToken();
                            if (token) {
                                window.webkit.messageHandlers.discordBridge.postMessage({ type: 'TOKEN_EXTRACTED', token: token });
                                return true;
                            }
                        }
                        
                        // Method 2: LocalStorage (older versions)
                        const lsToken = window.localStorage.getItem('token');
                        if (lsToken) {
                            window.webkit.messageHandlers.discordBridge.postMessage({ type: 'TOKEN_EXTRACTED', token: lsToken.replace(/"/g, '') });
                            return true;
                        }
                    } catch (e) {
                        console.error('Token extraction error:', e);
                    }
                    return false;
                }

                // Intercept Authorization Header in Fetch/XHR
                const originalFetch = window.fetch;
                window.fetch = function() {
                    if (arguments[1] && arguments[1].headers) {
                        const headers = arguments[1].headers;
                        let auth = headers['Authorization'] || headers['authorization'];
                        if (auth) {
                            window.webkit.messageHandlers.discordBridge.postMessage({ type: 'TOKEN_EXTRACTED', token: auth });
                        }
                    }
                    return originalFetch.apply(this, arguments);
                };

                const originalSetHeader = XMLHttpRequest.prototype.setRequestHeader;
                XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
                    if (name.toLowerCase() === 'authorization') {
                        window.webkit.messageHandlers.discordBridge.postMessage({ type: 'TOKEN_EXTRACTED', token: value });
                    }
                    return originalSetHeader.apply(this, arguments);
                };

                // Existing AUTH_SUCCESS logic
                setInterval(() => {
                    extractToken();
                    
                    const isUrlAuth = window.location.href.includes('/channels/@me') || window.location.href.includes('/channels/');
                    const selectors = [
                        'nav[aria-label="Servers sidebar"]', 
                        'div[class*="sidebar_"]', 
                        'div[class*="channels_"]',
                        'section[aria-label="User area"]'
                    ];
                    
                    if (isUrlAuth || selectors.some(s => document.querySelector(s))) {
                        window.webkit.messageHandlers.discordBridge.postMessage({ type: 'AUTH_SUCCESS' });
                    }
                }, 2000);

                // New discordStatus logic
                function checkAuthStatus() {
                    const isLogged = window.location.href.includes('/channels/');
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.discordStatus) {
                        window.webkit.messageHandlers.discordStatus.postMessage(isLogged);
                    }
                }
                setInterval(checkAuthStatus, 5000);
                extractToken();
                checkAuthStatus();
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(authScript)
        
        load()
    }
    
    func load() {
        print("DiscordWebManager: 🚀 Loading Discord Web...")
        webView.load(URLRequest(url: URL(string: "https://discord.com/app")!))
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "discordBridge",
           let body = message.body as? [String: Any],
           let type = body["type"] as? String {
            if type == "AUTH_SUCCESS" {
                if !isAuthenticated {
                    isAuthenticated = true
                    connectionStatus = "Connected"
                    print("DiscordWebManager: 🔓 Authenticated!")
                }
            } else if type == "TOKEN_EXTRACTED" {
                if let token = body["token"] as? String {
                    if self.discordToken != token {
                        self.discordToken = token
                        self.isAuthenticated = true
                        self.connectionStatus = "Connected (API Ready)"
                        print("DiscordWebManager: 🔑 Token extracted successfully!")
                    }
                }
            } else if type == "SEND_SUCCESS" {
                print("DiscordWebManager: ✅ Message sent successfully!")
            } else if type == "SEND_ERROR" {
                if let error = body["error"] as? String {
                    print("DiscordWebManager: ❌ Send error: \(error)")
                }
            }
        } else if message.name == "logging", let log = message.body as? String {
            print("🔵 [DISCORD-JS]: \(log)")
        } else if message.name == "discordStatus", let status = message.body as? Bool {
            // Updated auth logic
            self.isAuthenticated = status
            self.connectionStatus = status ? "Connected" : "Not Logged In"
        }
    }
    
    func getWebView() -> WKWebView {
        return webView
    }
    
    // Safe method to show webview in a window
    @MainActor
    func showWebViewInWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Discord Web"
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        window.center()
    }
}

extension DiscordWebManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        connectionStatus = "Discord Loaded"
    }
    
    // MARK: - Sending Logic
    func sendReply(channelId: String, text: String) {
        // Extract channel ID if it's in "guildId:channelId" format
        let finalChannelId = channelId.components(separatedBy: ":").last ?? channelId
        var isNumeric = CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: finalChannelId))
        
        if let token = self.discordToken, isNumeric {
            print("DiscordWebManager: 🚀 Sending message via REST API...")
            sendMessageViaAPI(channelId: finalChannelId, text: text)
            return
        }
        
        guard isAuthenticated else {
            print("DiscordWebManager: ⚠️ Not authenticated, cannot send message")
            return
        }
        
        print("DiscordWebManager: ⚠️ Token not found, falling back to UI automation...")
        
        // Original UI automation fallback
        let parts = channelId.components(separatedBy: ":")
        var targetUrl = ""
        var targetId = finalChannelId
        
        if parts.count == 2 {
            let guildId = parts[0]
            targetUrl = "https://discord.com/channels/\(guildId)/\(targetId)"
            isNumeric = true
        } else {
            isNumeric = CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: targetId))
            targetUrl = isNumeric ? "https://discord.com/channels/@me/\(targetId)" : "https://discord.com/channels/@me"
        }

        let escapedChannel = targetId.replacingOccurrences(of: "'", with: "\\'")
        let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "'", with: "\\'")
                              .replacingOccurrences(of: "\n", with: "\\n")
                              .replacingOccurrences(of: "\"", with: "\\\"")

        print("DiscordWebManager: 🚀 Navigating to \(targetUrl)")
        webView.load(URLRequest(url: URL(string: targetUrl)!))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.executeSendScript(escapedText: escapedText, escapedChannel: escapedChannel, isNumeric: isNumeric)
        }
    }
    
    func sendFile(channelId: String, fileURL: URL, text: String) {
        let finalChannelId = channelId.components(separatedBy: ":").last ?? channelId
        guard let token = self.discordToken else {
            print("DiscordWebManager: ❌ No token available for file send")
            return
        }

        let url = URL(string: "https://discord.com/api/v9/channels/\(finalChannelId)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        
        // 1. JSON Payload part
        let payload: [String: Any] = ["content": text]
        if let payloadData = try? JSONSerialization.data(withJSONObject: payload) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"payload_json\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
            body.append(payloadData)
            body.append("\r\n".data(using: .utf8)!)
        }

        // 2. File part
        if let fileData = try? Data(contentsOf: fileURL) {
            let filename = fileURL.lastPathComponent
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"files[0]\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        print("DiscordWebManager: 🚀 Sending file (\(fileURL.lastPathComponent)) to \(finalChannelId)")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("DiscordWebManager: ❌ File send error: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("DiscordWebManager: ✅ File sent successfully via API!")
                } else {
                    let bodyString = data != nil ? String(data: data!, encoding: .utf8) ?? "" : ""
                    print("DiscordWebManager: ❌ File send failed with status \(httpResponse.statusCode). Body: \(bodyString)")
                }
            }
        }.resume()
    }

    private func sendMessageViaAPI(channelId: String, text: String) {
        guard let token = self.discordToken else { return }
        
        let url = URL(string: "https://discord.com/api/v9/channels/\(channelId)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        let body: [String: Any] = ["content": text]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("DiscordWebManager: ❌ Failed to serialize message body")
            return
        }
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("DiscordWebManager: ❌ API send error: \(error.localizedDescription)")
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    print("DiscordWebManager: ✅ Message sent successfully via API!")
                } else {
                    let bodyString = data != nil ? String(data: data!, encoding: .utf8) ?? "" : ""
                    print("DiscordWebManager: ❌ API send failed with status \(httpResponse.statusCode). Body: \(bodyString)")
                    
                    // If error is 401, token might be invalid, clear it
                    if httpResponse.statusCode == 401 {
                        DispatchQueue.main.async {
                            self.discordToken = nil
                            self.isAuthenticated = false
                            print("DiscordWebManager: 🔑 Token invalid, cleared.")
                        }
                    }
                }
            }
        }.resume()
    }
    
    func getProfilePicture(for userId: String, completion: @escaping (NSImage?) -> Void) {
        getProfilePicture(candidates: [userId], completion: completion)
    }
    
    func getProfilePicture(candidates: [String], completion: @escaping (NSImage?) -> Void) {
        var remaining = candidates
        guard let token = self.discordToken, !remaining.isEmpty else {
            completion(nil)
            return
        }
        
        let userId = remaining.removeFirst()
        print("DiscordWebManager: 👤 Attempting to fetch profile picture for userId: \(userId)")
        
        let url = URL(string: "https://discord.com/api/v9/users/\(userId)")!
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 404 {
                print("DiscordWebManager: 📡 User \(userId) not found (404). Trying next candidate if available...")
                if !remaining.isEmpty {
                    self?.getProfilePicture(candidates: remaining, completion: completion)
                } else {
                    completion(nil)
                }
                return
            }
            
            if let error = error {
                print("DiscordWebManager: ❌ User API request error: \(error.localizedDescription)")
                completion(nil)
                return
            }
            
            guard let data = data else {
                completion(nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let avatarHash = json["avatar"] as? String {
                        let avatarUrlString = "https://cdn.discordapp.com/avatars/\(userId)/\(avatarHash).png?size=128"
                        print("DiscordWebManager: 🖼️ Avatar URL found: \(avatarUrlString)")
                        
                        if let avatarUrl = URL(string: avatarUrlString) {
                            URLSession.shared.dataTask(with: avatarUrl) { imageData, _, _ in
                                if let imageData = imageData, let image = NSImage(data: imageData) {
                                    completion(image)
                                } else {
                                    completion(nil)
                                }
                            }.resume()
                        } else {
                            completion(nil)
                        }
                    } else {
                        print("DiscordWebManager: ⚠️ User has no avatar hash in JSON")
                        completion(nil)
                    }
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }.resume()
    }
    
    func getGuildIcon(guildId: String, completion: @escaping (NSImage?) -> Void) {
        guard let token = self.discordToken else {
            completion(nil)
            return
        }
        
        print("DiscordWebManager: 🏰 Attempting to fetch guild icon for guildId: \(guildId)")
        
        let url = URL(string: "https://discord.com/api/v9/guilds/\(guildId)")!
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("DiscordWebManager: ❌ Guild API request error: \(error.localizedDescription)")
                completion(nil)
                return
            }
            
            guard let data = data else {
                completion(nil)
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let iconHash = json["icon"] as? String {
                        let iconUrlString = "https://cdn.discordapp.com/icons/\(guildId)/\(iconHash).png?size=128"
                        print("DiscordWebManager: 🖼️ Guild Icon URL found: \(iconUrlString)")
                        
                        if let iconUrl = URL(string: iconUrlString) {
                            URLSession.shared.dataTask(with: iconUrl) { imageData, _, _ in
                                if let imageData = imageData, let image = NSImage(data: imageData) {
                                    completion(image)
                                } else {
                                    completion(nil)
                                }
                            }.resume()
                        } else {
                            completion(nil)
                        }
                    } else {
                        print("DiscordWebManager: ⚠️ Guild has no icon hash in JSON")
                        completion(nil)
                    }
                } else {
                    completion(nil)
                }
            } catch {
                completion(nil)
            }
        }.resume()
    }
    
    private func executeSendScript(escapedText: String, escapedChannel: String, isNumeric: Bool) {
        let js = """
        // Define logger immediately
        const log = (msg) => {
            try {
                if (window.webkit?.messageHandlers?.logging) {
                    window.webkit.messageHandlers.logging.postMessage(String(msg));
                }
                console.log(msg);
            } catch(e) {
                console.error('Log failed:', e);
            }
        };
        
        log('🚀 Script iniziato!');
        
        const sleep = (ms) => new Promise(r => setTimeout(r, ms));
        
        async function sendMessage() {
            try {
                log('⏳ Step 1: Attendo 2 secondi...');
                await sleep(2000);
                
                // Search sidebar if needed
                if (!\(isNumeric)) {
                    log('🔍 Step 2: Cercando "\(escapedChannel)" nella sidebar...');
                    try {
                        const links = Array.from(document.querySelectorAll('a[href*="/channels/@me/"]'));
                        const match = links.find(el => el.textContent.toLowerCase().includes('\(escapedChannel)'.toLowerCase()));
                        if (match) {
                            log('✅ Trovato! Clicco...');
                            match.click();
                            await sleep(2000);
                        } else {
                            log('⚠️ Non trovato, continuo...');
                        }
                    } catch(e) {
                        log('❌ Errore ricerca sidebar: ' + e.message);
                    }
                }
                
                log('🔍 Step 3: Cercando textbox...');
                let textbox = null;
                for (let i = 0; i < 60; i++) {
                    textbox = document.querySelector('div[role="textbox"][data-slate-editor="true"]') ||
                              document.querySelector('div[role="textbox"]') ||
                              document.querySelector('div[contenteditable="true"]');
                    if (textbox) break;
                    await sleep(500);
                }
                
                if (!textbox) {
                    throw new Error('Textbox non trovata dopo 30 secondi');
                }
                
                log('✅ Step 4: Textbox trovata!');
                textbox.focus();
                await sleep(500);
                
                log('📝 Step 5: Inserimento testo...');
                
                // Try multiple methods
                let success = false;
                
                // Method 1: Direct text content
                try {
                    textbox.textContent = '\(escapedText)';
                    textbox.dispatchEvent(new Event('input', {bubbles: true}));
                    await sleep(300);
                    if (textbox.textContent.includes('\(escapedText)'.substring(0, 10))) {
                        success = true;
                        log('✅ Metodo 1 riuscito');
                    }
                } catch(e) {
                    log('⚠️ Metodo 1 fallito: ' + e.message);
                }
                
                // Method 2: innerText
                if (!success) {
                    try {
                        textbox.innerText = '\(escapedText)';
                        textbox.dispatchEvent(new InputEvent('input', {
                            bubbles: true,
                            inputType: 'insertText',
                            data: '\(escapedText)'
                        }));
                        await sleep(300);
                        if (textbox.innerText.includes('\(escapedText)'.substring(0, 10))) {
                            success = true;
                            log('✅ Metodo 2 riuscito');
                        }
                    } catch(e) {
                        log('⚠️ Metodo 2 fallito: ' + e.message);
                    }
                }
                
                // Method 3: Slate structure
                if (!success) {
                    try {
                        const slateHtml = '<div data-slate-node="element"><span data-slate-node="text"><span data-slate-leaf="true"><span data-slate-string="true">\(escapedText)</span></span></span></div>';
                        textbox.innerHTML = slateHtml;
                        textbox.dispatchEvent(new Event('input', {bubbles: true}));
                        await sleep(300);
                        success = true;
                        log('✅ Metodo 3 (Slate) riuscito');
                    } catch(e) {
                        log('⚠️ Metodo 3 fallito: ' + e.message);
                    }
                }
                
                log('📋 Contenuto finale textbox: "' + (textbox.textContent || textbox.innerText).substring(0, 50) + '"');
                
                log('⌨️ Step 6: Invio messaggio...');
                
                // Try to find send button with multiple selectors
                const sendBtnSelectors = [
                    'button[aria-label*="Send"]',
                    'button[aria-label*="Invia"]',
                    'button[type="submit"]',
                    'button[class*="sendButton"]',
                    'button[class*="buttonContainer"] button',
                    'div[class*="buttons"] button[type="button"]'
                ];
                
                let sendBtn = null;
                for (const selector of sendBtnSelectors) {
                    const btns = document.querySelectorAll(selector);
                    for (const btn of btns) {
                        // Check if button is visible and not disabled
                        const rect = btn.getBoundingClientRect();
                        if (rect.width > 0 && rect.height > 0 && !btn.disabled) {
                            sendBtn = btn;
                            break;
                        }
                    }
                    if (sendBtn) break;
                }
                
                if (sendBtn) {
                    log('🖱️ Trovato bottone send, tentativo click completo...');
                    
                    // Get button position for mouse events
                    const rect = sendBtn.getBoundingClientRect();
                    const x = rect.left + rect.width / 2;
                    const y = rect.top + rect.height / 2;
                    
                    // Method 1: Full mouse event sequence
                    const mouseEvents = ['mouseenter', 'mouseover', 'mousedown', 'mouseup', 'click'];
                    for (const eventType of mouseEvents) {
                        const mouseEvent = new MouseEvent(eventType, {
                            view: window,
                            bubbles: true,
                            cancelable: true,
                            clientX: x,
                            clientY: y,
                            button: 0
                        });
                        sendBtn.dispatchEvent(mouseEvent);
                        await sleep(50);
                    }
                    
                    log('✅ Click events completati');
                    await sleep(300);
                    
                    // Method 2: Direct click() call
                    sendBtn.click();
                    log('✅ Click diretto eseguito');
                    await sleep(200);
                    
                    // Method 3: Focus and click
                    sendBtn.focus();
                    await sleep(100);
                    sendBtn.click();
                    log('✅ Focus + click eseguito');
                    
                } else {
                    log('⚠️ Bottone non trovato, uso keyboard events...');
                    
                    // Focus textbox first
                    textbox.focus();
                    await sleep(100);
                    
                    // Try multiple keyboard event approaches
                    // Method 1: Full keyboard event with all properties
                    const keydownEvent = new KeyboardEvent('keydown', {
                        key: 'Enter',
                        code: 'Enter',
                        keyCode: 13,
                        which: 13,
                        charCode: 13,
                        bubbles: true,
                        cancelable: true,
                        composed: true
                    });
                    textbox.dispatchEvent(keydownEvent);
                    
                    await sleep(50);
                    
                    const keypressEvent = new KeyboardEvent('keypress', {
                        key: 'Enter',
                        code: 'Enter',
                        keyCode: 13,
                        which: 13,
                        charCode: 13,
                        bubbles: true,
                        cancelable: true,
                        composed: true
                    });
                    textbox.dispatchEvent(keypressEvent);
                    
                    await sleep(50);
                    
                    const keyupEvent = new KeyboardEvent('keyup', {
                        key: 'Enter',
                        code: 'Enter',
                        keyCode: 13,
                        which: 13,
                        charCode: 13,
                        bubbles: true,
                        cancelable: true,
                        composed: true
                    });
                    textbox.dispatchEvent(keyupEvent);
                    
                    await sleep(200);
                    
                    // Method 2: Also try dispatching on document
                    log('⌨️ Provo anche su document...');
                    document.dispatchEvent(new KeyboardEvent('keydown', {
                        key: 'Enter',
                        code: 'Enter',
                        keyCode: 13,
                        bubbles: true
                    }));
                    
                    await sleep(100);
                    
                    // Method 3: Try finding the form and submitting it
                    const form = textbox.closest('form');
                    if (form) {
                        log('📝 Trovato form, submit...');
                        form.dispatchEvent(new Event('submit', {bubbles: true, cancelable: true}));
                    }
                }
                
                // Final verification - check if message was sent by checking if textbox is empty
                await sleep(1000);
                const finalContent = textbox.textContent || textbox.innerText || '';
                log('🔍 Verifica finale - textbox content: "' + finalContent.substring(0, 30) + '"');
                
                if (finalContent.trim().length === 0 || finalContent.trim().length < '\(escapedText)'.length / 2) {
                    log('✅ SUCCESSO: Textbox vuota/pulita, messaggio probabilmente inviato!');
                } else {
                    log('⚠️ WARNING: Textbox ancora piena, messaggio potrebbe non essere stato inviato');
                }
                
                await sleep(500);
                log('🎉 Sequenza completata!');
                
                window.webkit.messageHandlers.discordBridge.postMessage({
                    type: 'SEND_SUCCESS',
                    chatId: '\(escapedChannel)'
                });
                
            } catch(error) {
                log('💥 ERRORE: ' + error.message);
                log('Stack: ' + (error.stack || 'N/A'));
                window.webkit.messageHandlers.discordBridge.postMessage({
                    type: 'SEND_ERROR',
                    error: error.message
                });
            }
        }
        
        // Execute without returning the promise
        sendMessage().catch(e => {
            log('💥 Catch esterno: ' + e.message);
        });
        
        // Return undefined immediately to avoid "unsupported type" error
        undefined;
        """
        
        print("DiscordWebManager: 📤 Executing send script...")
        self.webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("DiscordWebManager: ❌ JS execution error: \(error.localizedDescription)")
            } else {
                print("DiscordWebManager: ✅ JS script sent")
            }
        }
    }
}
