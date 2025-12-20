#if os(macOS)
import SwiftUI
import Defaults
import CoreAudio

struct CircularHUDView: View {
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    
    @Default(.circularHUDShowValue) var showValue
    @Default(.circularHUDSize) var size
    @Default(.circularHUDStrokeWidth) var strokeWidth
    @Default(.circularHUDUseAccentColor) var useAccentColor
    
    @Environment(\.colorScheme) var colorScheme
    
    @Default(.useColorCodedVolumeDisplay) var useColorCodedVolume
    @Default(.useSmoothColorGradient) var useSmoothGradient
    
    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                }
            
            // Native Gauge Ring
            Gauge(value: value) {
                Text("")
            }
            .gaugeStyle(.accessoryCircular)
            .labelsHidden()
            .tint(strokeStyle)
            .scaleEffect(size / 60)
            .animation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0), value: value)
            
            // Central Icon
            Image(systemName: symbolName)
                .font(.system(size: size * 0.32, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace)) // Smooth icon switching
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: symbolName)

            
            // Bottom Value Label
            if showValue {
                VStack {
                    Spacer()
                    Text("\(Int(value * 100))")
                        .font(.system(size: size * 0.15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .contentTransition(.numericText())
                        .padding(.bottom, size * 0.03) // Adjusted to align perfectly with the bottom gap
                }
            }



        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var strokeStyle: AnyShapeStyle {
        if type == .volume && useColorCodedVolume {
            return ColorCodedProgressBar.shapeStyle(for: value, mode: .volume, smoothGradient: useSmoothGradient)
        }
        
        return AnyShapeStyle(useAccentColor ? Color.accentColor : Color.white)
    }
    
    private var symbolName: String {
        if !icon.isEmpty { return icon }
        
        switch type {
        case .volume:
            // Check if headphones/AirPods are connected
            let deviceInfo = getAudioDeviceInfo()
            
            if deviceInfo.isAirPods {
                // Use AirPods icon when AirPods are connected
                if value < 0.01 { return "headphones.slash" }
                else { return "airpods" }
            } else if deviceInfo.isHeadphones {
                // Use headphone icons when other headphones are connected
                if value < 0.01 { return "headphones.slash" }
                else { return "headphones" }
            } else {
                // Use speaker icons for built-in speakers
                if value < 0.01 { return "speaker.slash.fill" }
                else if value < 0.33 { return "speaker.wave.1.fill" }
                else if value < 0.66 { return "speaker.wave.2.fill" }
                else { return "speaker.wave.3.fill" }
            }
        case .brightness:
            return "sun.max.fill"
        case .backlight:
            return "keyboard"
        default:
            return "questionmark"
        }
    }
    
    private struct AudioDeviceInfo {
        let isAirPods: Bool
        let isHeadphones: Bool
    }
    
    private func getAudioDeviceInfo() -> AudioDeviceInfo {
        #if os(macOS)
        // Get default output device
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout.size(ofValue: deviceID))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return AudioDeviceInfo(isAirPods: false, isHeadphones: false)
        }
        
        // Get device name
        var deviceName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &deviceName) == noErr else {
            return AudioDeviceInfo(isAirPods: false, isHeadphones: false)
        }
        
        let name = (deviceName as String).lowercased()
        
        // Check for AirPods specifically
        let isAirPods = name.contains("airpod")
        
        // Check for other headphones
        let isHeadphones = name.contains("headphone") || 
                          name.contains("ear") ||
                          name.contains("buds") ||
                          name.contains("beats")
        
        return AudioDeviceInfo(isAirPods: isAirPods, isHeadphones: !isAirPods && isHeadphones)
        #else
        return AudioDeviceInfo(isAirPods: false, isHeadphones: false)
        #endif
    }
}
#endif
