//
//  DynamicIslandHeader.swift
//  DynamicIsland
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct DynamicIslandHeader: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @EnvironmentObject var webcamManager: WebcamManager
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject var clipboardManager = ClipboardManager.shared
    @ObservedObject var shelfState = ShelfStateViewModel.shared
    @ObservedObject var timerManager = TimerManager.shared
    @ObservedObject var doNotDisturbManager = DoNotDisturbManager.shared
    @State private var showClipboardPopover = false
    @State private var showColorPickerPopover = false
    @State private var showTimerPopover = false
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.timerDisplayMode) var timerDisplayMode
    
    var body: some View {
        HStack(spacing: 0) {
            if !Defaults[.enableMinimalisticUI] {
                HStack {
                    let shouldShowTabs = coordinator.alwaysShowTabs || vm.notchState == .open || !shelfState.items.isEmpty
                    if shouldShowTabs {
                        TabSelectionView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(vm.notchState == .closed ? 0 : 1)
                .blur(radius: vm.notchState == .closed ? 20 : 0)
                .animation(.smooth.delay(0.1), value: vm.notchState)
                .zIndex(2)
            }

            if vm.notchState == .open && !Defaults[.enableMinimalisticUI] {
                Rectangle()
                    .fill(NSScreen.screens
                        .first(where: { $0.localizedName == coordinator.selectedScreen })?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open && !Defaults[.enableMinimalisticUI] {
                    if Defaults[.showMirror] {
                        Button(action: {
                            vm.toggleCameraPreview()
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "web.camera")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    if Defaults[.enableClipboardManager] && Defaults[.showClipboardIcon] {
                        Button(action: {
                            // Switch behavior based on display mode
                            switch Defaults[.clipboardDisplayMode] {
                            case .panel:
                                ClipboardPanelManager.shared.toggleClipboardPanel()
                            case .popover:
                                showClipboardPopover.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showClipboardPopover, arrowEdge: .bottom) {
                            ClipboardPopover()
                        }
                        .onChange(of: showClipboardPopover) { isActive in
                            vm.isClipboardPopoverActive = isActive
                            
                            // If popover was closed, trigger a hover recheck
                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                        .onAppear {
                            if Defaults[.enableClipboardManager] && !clipboardManager.isMonitoring {
                                clipboardManager.startMonitoring()
                            }
                        }
                    }
                    
                    // ColorPicker button
                    if Defaults[.enableColorPickerFeature] {
                        Button(action: {
                            switch Defaults[.colorPickerDisplayMode] {
                            case .panel:
                                ColorPickerPanelManager.shared.toggleColorPickerPanel()
                            case .popover:
                                showColorPickerPopover.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "eyedropper")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showColorPickerPopover, arrowEdge: .bottom) {
                            ColorPickerPopover()
                        }
                        .onChange(of: showColorPickerPopover) { isActive in
                            vm.isColorPickerPopoverActive = isActive
                            
                            // If popover was closed, trigger a hover recheck
                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                    }
                    
                    if Defaults[.enableTimerFeature] && timerDisplayMode == .popover {
                        Button(action: {
                            withAnimation(.smooth) {
                                showTimerPopover.toggle()
                            }
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "timer")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showTimerPopover, arrowEdge: .bottom) {
                            TimerPopover()
                        }
                        .onChange(of: showTimerPopover) { isActive in
                            vm.isTimerPopoverActive = isActive
                            if !isActive {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    vm.shouldRecheckHover.toggle()
                                }
                            }
                        }
                    }
                    
                    if Defaults[.settingsIconInNotch] {
                        Button(action: {
                            SettingsWindowController.shared.showWindow()
                        }) {
                            Capsule()
                                .fill(.black)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    Image(systemName: "gear")
                                        .foregroundColor(.white)
                                        .padding()
                                        .imageScale(.medium)
                                }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    
                    // Screen Recording Indicator
                    if Defaults[.enableScreenRecordingDetection] && Defaults[.showRecordingIndicator] && !shouldSuppressStatusIndicators {
                        RecordingIndicator()
                            .frame(width: 30, height: 30) // Same size as other header elements
                    }

                    if Defaults[.enableDoNotDisturbDetection]
                        && Defaults[.showDoNotDisturbIndicator]
                        && doNotDisturbManager.isDoNotDisturbActive
                        && !shouldSuppressStatusIndicators {
                        FocusIndicator()
                            .frame(width: 30, height: 30)
                            .transition(.opacity)
                    }
                    
                    if Defaults[.showBatteryIndicator] {
                        DynamicIslandBatteryView(
                            batteryWidth: 30,
                            isCharging: batteryModel.isCharging,
                            isInLowPowerMode: batteryModel.isInLowPowerMode,
                            isPluggedIn: batteryModel.isPluggedIn,
                            levelBattery: batteryModel.levelBattery,
                            maxCapacity: batteryModel.maxCapacity,
                            timeToFullCharge: batteryModel.timeToFullCharge,
                            isForNotification: false
                        )
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .animation(.smooth.delay(0.1), value: vm.notchState)
            .zIndex(2)
            .overlay(
                // HUD display for volume/brightness/backlight - appears on top of all elements
                Group {
                    if vm.notchState == .open && !Defaults[.enableMinimalisticUI] && shouldShowHUD {
                        GeometryReader { geometry in
                            HStack {
                                Spacer()
                                headerHUDView
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                    // Extend to cover clipboard button - calculate based on visible buttons
                                    .frame(width: calculateHUDWidth(), alignment: .trailing)
                                    .offset(x: calculateHUDOffset(), y: 2)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                },
                alignment: .trailing
            )
            .zIndex(shouldShowHUD ? 10 : 2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
        .onChange(of: coordinator.shouldToggleClipboardPopover) { _ in
            // Only toggle if clipboard is enabled
            if Defaults[.enableClipboardManager] {
                switch Defaults[.clipboardDisplayMode] {
                case .panel:
                    ClipboardPanelManager.shared.toggleClipboardPanel()
                case .popover:
                    showClipboardPopover.toggle()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleClipboardPopover"))) { _ in
            // Handle keyboard shortcut for popover mode
            if Defaults[.enableClipboardManager] && Defaults[.clipboardDisplayMode] == .popover {
                showClipboardPopover.toggle()
            }
        }
        .onChange(of: enableTimerFeature) { _, newValue in
            if !newValue {
                showTimerPopover = false
                vm.isTimerPopoverActive = false
            }
        }
        .onChange(of: timerDisplayMode) { _, mode in
            if mode == .tab {
                showTimerPopover = false
                vm.isTimerPopoverActive = false
            }
        }
    }
}

private extension DynamicIslandHeader {
    var shouldSuppressStatusIndicators: Bool {
        Defaults[.settingsIconInNotch]
            && Defaults[.enableClipboardManager]
            && Defaults[.showClipboardIcon]
            && Defaults[.enableColorPickerFeature]
            && Defaults[.enableTimerFeature]
    }
    
    var shouldShowHUD: Bool {
        coordinator.sneakPeek.show && 
        (coordinator.sneakPeek.type == .volume || 
         coordinator.sneakPeek.type == .brightness || 
         coordinator.sneakPeek.type == .backlight)
    }
    
    @ViewBuilder
    var headerHUDView: some View {
        HStack(spacing: 8) {
            // Icon
            Group {
                switch coordinator.sneakPeek.type {
                case .volume:
                    if coordinator.sneakPeek.icon.isEmpty {
                        let baseIcon = BluetoothAudioManager.shared.isBluetoothAudioConnected ? "headphones" : speakerIcon(for: coordinator.sneakPeek.value)
                        Image(systemName: baseIcon)
                            .contentTransition(.interpolate)
                            .symbolVariant(coordinator.sneakPeek.value > 0 ? .none : .slash)
                    } else {
                        Image(systemName: coordinator.sneakPeek.icon)
                            .contentTransition(.interpolate)
                            .opacity(coordinator.sneakPeek.value.isZero ? 0.6 : 1)
                            .scaleEffect(coordinator.sneakPeek.value.isZero ? 0.85 : 1)
                    }
                case .brightness:
                    Image(systemName: brightnessIcon(for: coordinator.sneakPeek.value))
                        .contentTransition(.interpolate)
                case .backlight:
                    Image(systemName: backlightIcon(for: coordinator.sneakPeek.value))
                        .contentTransition(.interpolate)
                default:
                    EmptyView()
                }
            }
            .foregroundStyle(.white)
            .symbolVariant(.fill)
            .frame(width: 16, height: 16)
            
            // Progress bar with percentage
            HStack(spacing: 6) {
                if coordinator.sneakPeek.type == .volume {
                    if coordinator.sneakPeek.value.isZero {
                        // Show muted text but keep black background
                        Text("muted")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .contentTransition(.numericText())
                            .frame(width: 60, alignment: .leading)
                        
                        if Defaults[.showProgressPercentages] {
                            Text("0%")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                                .frame(width: 32, alignment: .trailing)
                        }
                    } else {
                        DraggableProgressBar(value: Binding(
                            get: { coordinator.sneakPeek.value },
                            set: { newValue in
                                coordinator.sneakPeek.value = newValue
                                updateSystemValue(newValue)
                            }
                        ), colorMode: .volume)
                        .frame(width: 60, height: 4)
                        
                        if Defaults[.showProgressPercentages] {
                            Text("\(Int(coordinator.sneakPeek.value * 100))%")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(width: 32, alignment: .trailing)
                        }
                    }
                } else {
                    DraggableProgressBar(value: Binding(
                        get: { coordinator.sneakPeek.value },
                        set: { newValue in
                            coordinator.sneakPeek.value = newValue
                            updateSystemValue(newValue)
                        }
                    ))
                    .frame(width: 60, height: 4)
                    
                    if Defaults[.showProgressPercentages] {
                        Text("\(Int(coordinator.sneakPeek.value * 100))%")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.black)
        )
        .animation(.smooth(duration: 0.2), value: coordinator.sneakPeek.value.isZero)
    }
    
    private func calculateHUDWidth() -> CGFloat {
        // Base width for HUD content + clipboard button
        var width: CGFloat = 140
        
        // Add width to cover clipboard button (30px button + 4px spacing)
        if Defaults[.enableClipboardManager] && Defaults[.showClipboardIcon] {
            width += 34
        }
        
        return width
    }
    
    private func calculateHUDOffset() -> CGFloat {
        // Simple offset to cover clipboard button without going too far left
        // Just enough to cover the clipboard button (30px + 4px spacing = 34px)
        if Defaults[.enableClipboardManager] && Defaults[.showClipboardIcon] {
            return -34
        }
        return 0
    }
    
    private func speakerIcon(for value: CGFloat) -> String {
        switch value {
        case 0:
            return "speaker"
        case 0...0.3:
            return "speaker.wave.1"
        case 0.3...0.8:
            return "speaker.wave.2"
        case 0.8...1:
            return "speaker.wave.3"
        default:
            return "speaker.wave.2"
        }
    }
    
    private func brightnessIcon(for value: CGFloat) -> String {
        switch value {
        case 0...0.6:
            return "sun.min"
        case 0.6...1:
            return "sun.max"
        default:
            return "sun.max"
        }
    }
    
    private func backlightIcon(for value: CGFloat) -> String {
        switch value {
        case 0:
            return "keyboard"
        case 0...0.5:
            return "keyboard"
        case 0.5...1:
            return "keyboard"
        default:
            return "keyboard"
        }
    }
    
    private func updateSystemValue(_ value: CGFloat) {
        switch coordinator.sneakPeek.type {
        case .volume:
            SystemVolumeController.shared.setVolume(Float(value))
        case .brightness:
            SystemBrightnessController.shared.setBrightness(Float(value))
        case .backlight:
            SystemKeyboardBacklightController.shared.setLevel(Float(value))
        default:
            break
        }
    }
}

#Preview {
    DynamicIslandHeader()
        .environmentObject(DynamicIslandViewModel())
        .environmentObject(WebcamManager.shared)
}
