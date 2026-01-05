import SwiftUI
import WebKit

struct WhatsAppLinkView: View {
    @StateObject private var waManager = WhatsAppWebManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var showDebug = false
    
    var body: some View {
        VStack(spacing: 20) {
            header
            
            ZStack {
                if showDebug && !waManager.isAuthenticated {
                    WebViewWrapper(webView: waManager.getWebView())
                        .cornerRadius(12)
                } else if waManager.isAuthenticated {
                    connectedState
                } else if let qrImage = waManager.qrCodeImage {
                    qrState(image: qrImage)
                } else {
                    loadingState
                }
            }
            .frame(width: 250, height: 250)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            
            statusFooter
            
            VStack(spacing: 12) {
                Toggle("Secure Private Mode", isOn: $waManager.isEphemeral)
                    .toggleStyle(.switch)
                    .font(.caption)
                
                if !waManager.isEphemeral {
                    Text("Note: Normal mode requires Keychain access to save your session securely.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                } else {
                    Text("Private mode: No keychain prompt, but you will need to re-link on every restart.")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            .padding(.vertical, 8)
            
            HStack(spacing: 20) {
                if !waManager.isAuthenticated {
                    refreshButton
                    
                    Button(action: { showDebug.toggle() }) {
                        Label(showDebug ? "Hide Browser" : "Open Browser", systemImage: showDebug ? "eye.slash" : "safari")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    
                    if showDebug {
                        Button(action: { waManager.manualAuthOverride() }) {
                            Label("Sync & Done", systemImage: "checkmark.seal")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.green)
                    }
                } else {
                    // Always show an exit button if for some reason dismiss doesn't work or state is weird
                    Button("Close Setup") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }
        }
        .padding(30)
        .frame(width: 400)
        .background(Color.black.opacity(0.95))
    }
    
    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "message.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            
            Text("Link WhatsApp")
                .font(.system(size: 24, weight: .bold))
            
            Text("Scan the QR code with your phone to enable background replies.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    private func qrState(image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.none) // Keep QR sharp
            .padding(10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 10)
    }
    
    private var connectedState: some View {
        VStack(spacing: 15) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            Text("Connected!")
                .font(.headline)
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
    
    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Generating QR Code...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private var statusFooter: some View {
        HStack {
            Circle()
                .fill(waManager.isAuthenticated ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            
            Text(waManager.connectionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private var refreshButton: some View {
        HStack(spacing: 15) {
            Button(action: { waManager.reload() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            
            Button(action: { waManager.hardReset() }) {
                Label("Reset All", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.8))
        }
    }
}

struct WebViewWrapper: NSViewRepresentable {
    let webView: WKWebView
    
    func makeNSView(context: Context) -> WKWebView {
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
