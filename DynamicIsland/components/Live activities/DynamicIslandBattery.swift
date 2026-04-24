/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import Defaults

/// A view that displays the battery status with an icon and charging indicator.
struct BatteryView: View {

    var levelBattery: Float
    var isPluggedIn: Bool
    var isCharging: Bool
    var isInLowPowerMode: Bool
    var batteryWidth: CGFloat = 26
    var isForNotification: Bool

    var animationStyle: DynamicIslandAnimations = DynamicIslandAnimations()

    var icon: String = "battery.0"

    /// Determines the icon to display when charging.
    var iconStatus: String {
        if isCharging {
            return "bolt"
        }
        else if isPluggedIn {
            return "plug"
        }
        else {
            return ""
        }
    }

    /// Determines the color of the battery based on its status.
    var batteryColor: Color {
        if isInLowPowerMode {
            return .yellow
        } else if levelBattery <= 20 && !isCharging && !isPluggedIn {
            return .red
        } else if isCharging || isPluggedIn || levelBattery == 100 {
            return .green
        } else {
            return .white
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {

            Image(systemName: icon)
                .resizable()
                .fontWeight(.thin)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.white.opacity(0.5))
                .frame(
                    width: batteryWidth + 1
                )

            RoundedRectangle(cornerRadius: 2.5)
                .fill(batteryColor)
                .frame(
                    width: CGFloat(((CGFloat(CFloat(levelBattery)) / 100) * (batteryWidth - 6))),
                    height: (batteryWidth - 2.75) - 18
                )
                .padding(.leading, 2)

            if iconStatus != "" && (isForNotification || Defaults[.showPowerStatusIcons]) {
                ZStack {
                    Image(iconStatus)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(.white)
                        .frame(
                            width: 17,
                            height: 17
                        )
                }
                .frame(width: batteryWidth, height: batteryWidth)
            }
        }
    }
}

/// A view that displays detailed battery information and settings.
struct BatteryMenuView: View {
    
    var isPluggedIn: Bool
    var isCharging: Bool
    var levelBattery: Float
    var maxCapacity: Float
    var timeToFullCharge: Int
    var isInLowPowerMode: Bool
    var onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack {
                Text("Battery Status")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(Int(levelBattery))%")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Max Capacity: \(Int(maxCapacity))%")
                    .font(.subheadline)
                    .fontWeight(.regular)
                if isInLowPowerMode {
                    Label("Low Power Mode", systemImage: "bolt.circle")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isCharging {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isPluggedIn {
                    Label("Plugged In", systemImage: "powerplug.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if timeToFullCharge > 0 {
                    Label("Time to Full Charge: \(timeToFullCharge) min", systemImage: "clock")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if !isCharging && isPluggedIn && levelBattery >= 80 {
                    Label("Charging on Hold: Desktop Mode", systemImage: "desktopcomputer")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                    
            }
            .padding(.vertical, 8)

            Divider().background(Color.white)

            Button(action: openBatteryPreferences) {
                Label("Battery Settings", systemImage: "gearshape")
                    .fontWeight(.regular)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
        .padding()
        .frame(width: 280)
        .foregroundColor(.white)
    }

    private func openBatteryPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            openURL(url)
            onDismiss()
        }
    }
}


/// A view that displays the battery status and allows interaction to show detailed information.
struct DynamicIslandBatteryView: View {
    
    @State var batteryWidth: CGFloat = 26
    var isCharging: Bool = false
    var isInLowPowerMode: Bool = false
    var isPluggedIn: Bool = false
    var levelBattery: Float = 0
    var maxCapacity: Float = 0
    var timeToFullCharge: Int = 0
    @State var isForNotification: Bool = false
    
    @State private var showPopupMenu: Bool = false
    @State private var isPressed: Bool = false
    @State private var isHoveringPopover: Bool = false

    @EnvironmentObject var vm: DynamicIslandViewModel

    var body: some View {
        HStack {
            if Defaults[.showBatteryPercentage] {
                ZStack(alignment: .trailing) {
                    Text("100%")
                        .font(.callout)
                        .hidden()
                    
                    Text("\(Int32(levelBattery))%")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            BatteryView(
                levelBattery: levelBattery,
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                isInLowPowerMode: isInLowPowerMode,
                batteryWidth: batteryWidth,
                isForNotification: isForNotification
            )
        }
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isPressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    withAnimation {
                        isPressed = false
                        showPopupMenu.toggle()
                    }
                }
        )
        .popover(
            isPresented: $showPopupMenu,
            arrowEdge: .bottom) {
            BatteryMenuView(
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                levelBattery: levelBattery,
                maxCapacity: maxCapacity,
                timeToFullCharge: timeToFullCharge,
                isInLowPowerMode: isInLowPowerMode,
                onDismiss: { 
                    showPopupMenu = false
                }
            )
            .onHover { hovering in
                isHoveringPopover = hovering
            }
        }
        .onChange(of: showPopupMenu) { _, _ in
            updateBatteryPopoverActiveState()
        }
        .onChange(of: isHoveringPopover) { _, _ in
            updateBatteryPopoverActiveState()
        }
    }

    private func updateBatteryPopoverActiveState() {
        vm.isBatteryPopoverActive = showPopupMenu && isHoveringPopover
    }
}

/// Battery temporary activity views adapted from jackson-storm/DynamicNotch's battery feature.
struct BatteryTemporaryActivityView: View {
    let kind: BatteryTemporaryActivityKind
    let batteryLevel: Int
    let isLowPowerMode: Bool
    let baseWidth: CGFloat
    let baseHeight: CGFloat
    let styleOverride: BatteryNotificationStyle?
    let usesDefaultStrokeOverride: Bool?

    init(
        kind: BatteryTemporaryActivityKind,
        batteryLevel: Int,
        isLowPowerMode: Bool,
        baseWidth: CGFloat,
        baseHeight: CGFloat,
        styleOverride: BatteryNotificationStyle? = nil,
        usesDefaultStrokeOverride: Bool? = nil
    ) {
        self.kind = kind
        self.batteryLevel = batteryLevel
        self.isLowPowerMode = isLowPowerMode
        self.baseWidth = baseWidth
        self.baseHeight = baseHeight
        self.styleOverride = styleOverride
        self.usesDefaultStrokeOverride = usesDefaultStrokeOverride
    }

    private let appearanceAnimation = Animation.interactiveSpring(
        response: 0.42,
        dampingFraction: 0.86,
        blendDuration: 0.12
    )

    private var style: BatteryNotificationStyle {
        if let styleOverride {
            return styleOverride
        }

        switch kind {
        case .charging:
            return .compact
        case .lowPower:
            return Defaults[.lowBatteryNotificationStyle]
        case .fullPower:
            return Defaults[.fullBatteryNotificationStyle]
        }
    }

    private var usesDefaultStroke: Bool {
        if let usesDefaultStrokeOverride {
            return usesDefaultStrokeOverride
        }

        switch kind {
        case .charging:
            return false
        case .lowPower:
            return Defaults[.lowBatteryUsesDefaultStroke]
        case .fullPower:
            return Defaults[.fullBatteryUsesDefaultStroke]
        }
    }

    private var strokeColor: Color {
        switch kind {
        case .charging:
            return (isLowPowerMode ? Color.yellow : Color.green).opacity(0.3)
        case .lowPower:
            if usesDefaultStroke {
                return .white.opacity(0.2)
            }
            return (isLowPowerMode ? Color.yellow : Color.red).opacity(0.3)
        case .fullPower:
            if usesDefaultStroke {
                return .white.opacity(0.2)
            }
            return (isLowPowerMode ? Color.yellow : Color.green).opacity(0.3)
        }
    }

    private var compactSurfaceHeight: CGFloat {
        max(baseHeight, 24)
    }

    private var size: CGSize {
        switch (kind, style) {
        case (.charging, _):
            return .init(width: baseWidth, height: compactSurfaceHeight)
        case (.lowPower, .compact):
            return .init(width: baseWidth, height: compactSurfaceHeight)
        case (.fullPower, .compact):
            return .init(width: baseWidth, height: compactSurfaceHeight)
        case (.lowPower, .standard):
            return .init(width: baseWidth + 100, height: baseHeight + 75)
        case (.fullPower, .standard):
            return .init(width: baseWidth + 80, height: baseHeight + 70)
        }
    }

    private var cornerRadii: (top: CGFloat, bottom: CGFloat) {
        switch (kind, style) {
        case (.charging, _), (.lowPower, .compact), (.fullPower, .compact):
            return (
                top: max(size.height * 0.22, 6),
                bottom: max(size.height * 0.54, 14)
            )
        case (.lowPower, .standard):
            return (top: 22, bottom: 40)
        case (.fullPower, .standard):
            return (top: 18, bottom: 36)
        }
    }

    private var surfaceShape: NotchShape {
        NotchShape(
            topCornerRadius: cornerRadii.top,
            bottomCornerRadius: cornerRadii.bottom
        )
    }

    private var topStrokeCoverHeight: CGFloat {
        2.4
    }

    private var topStrokeHorizontalInset: CGFloat {
        max(cornerRadii.top + 1.2, 8)
    }

    var body: some View {
        ZStack {
            surfaceShape
                .fill(.black)

            switch kind {
            case .charging:
                ChargingBatteryTemporaryView(
                    batteryLevel: batteryLevel,
                    isLowPowerMode: isLowPowerMode,
                    compactHeight: compactSurfaceHeight
                )
            case .lowPower:
                LowPowerBatteryTemporaryView(
                    batteryLevel: batteryLevel,
                    isLowPowerMode: isLowPowerMode,
                    style: style,
                    compactHeight: compactSurfaceHeight
                )
            case .fullPower:
                FullBatteryTemporaryView(
                    batteryLevel: batteryLevel,
                    isLowPowerMode: isLowPowerMode,
                    style: style,
                    compactHeight: compactSurfaceHeight
                )
            }
        }
        .overlay {
            surfaceShape
                .stroke(strokeColor, lineWidth: 1.2)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.black)
                .frame(height: topStrokeCoverHeight)
                .padding(.horizontal, topStrokeHorizontalInset)
                .offset(y: -0.3)
        }
        .clipShape(surfaceShape)
        .frame(width: size.width, height: size.height)
        .shadow(color: strokeColor.opacity(style == .compact ? 0.18 : 0.12), radius: 8, x: 0, y: 2)
        .animation(appearanceAnimation, value: kind)
        .animation(appearanceAnimation, value: style.id)
        .animation(appearanceAnimation, value: batteryLevel)
    }
}

struct BatteryCompactTemporaryView: View {
    let title: String
    let batteryLevel: Int
    let tint: Color
    let compactHeight: CGFloat

    private var titleFontSize: CGFloat {
        max(12, compactHeight * 0.46)
    }

    private var valueFontSize: CGFloat {
        max(12, compactHeight * 0.45)
    }

    private var horizontalPadding: CGFloat {
        max(12, compactHeight * 0.44)
    }

    private var barWidth: CGFloat {
        max(24, compactHeight * 1.02)
    }

    private var barHeight: CGFloat {
        max(14, compactHeight * 0.6)
    }

    private var barCornerRadius: CGFloat {
        max(5, barHeight * 0.38)
    }

    private var terminalWidth: CGFloat {
        max(2, compactHeight * 0.08)
    }

    private var terminalHeight: CGFloat {
        max(5, compactHeight * 0.2)
    }

    var body: some View {
        HStack {
            Text(verbatim: title)
                .font(.system(size: titleFontSize, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer()

            HStack(spacing: max(4, compactHeight * 0.14)) {
                Text("\(batteryLevel)%")
                    .font(.system(size: valueFontSize, weight: .semibold, design: .rounded))
                    .foregroundColor(tint)
                    .monospacedDigit()

                HStack(spacing: max(1.5, compactHeight * 0.05)) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous)
                            .fill(tint.opacity(0.3))

                        GeometryReader { geo in
                            let clamped = max(0, min(batteryLevel, 100))
                            let fraction = CGFloat(clamped) / 100
                            let width = fraction * geo.size.width

                            Rectangle()
                                .fill(tint.gradient)
                                .frame(width: max(0, width))
                        }
                    }
                    .frame(width: barWidth, height: barHeight)
                    .clipShape(RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous))
                    .animation(.smooth(duration: 0.24), value: batteryLevel)

                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(batteryLevel == 100 ? tint.gradient : tint.opacity(0.3).gradient)
                        .frame(width: terminalWidth, height: terminalHeight)
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: compactHeight)
    }
}

struct ChargingBatteryTemporaryView: View {
    let batteryLevel: Int
    let isLowPowerMode: Bool
    let compactHeight: CGFloat

    private var batteryColor: Color {
        if isLowPowerMode {
            return .yellow
        } else if batteryLevel <= 20 {
            return .red
        } else {
            return .green
        }
    }

    var body: some View {
        BatteryCompactTemporaryView(
            title: "Charging",
            batteryLevel: batteryLevel,
            tint: batteryColor,
            compactHeight: compactHeight
        )
    }
}

struct LowPowerBatteryTemporaryView: View {
    let batteryLevel: Int
    let isLowPowerMode: Bool
    let style: BatteryNotificationStyle
    let compactHeight: CGFloat

    @State private var pulse = false

    private var batteryColor: Color {
        isLowPowerMode ? .yellow : .red
    }

    private func startPulse() {
        pulse = false
        withAnimation(
            .easeInOut(duration: 1)
            .repeatForever(autoreverses: true)
        ) {
            pulse = true
        }
    }

    var body: some View {
        Group {
            if style == .compact {
                BatteryCompactTemporaryView(
                    title: "Low Battery",
                    batteryLevel: batteryLevel,
                    tint: batteryColor,
                    compactHeight: compactHeight
                )
            } else {
                VStack {
                    Spacer()

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            title
                            description
                        }

                        Spacer()

                        if isLowPowerMode {
                            yellowIndicator
                        } else {
                            redIndicator
                        }
                    }
                }
                .padding(.bottom, 20)
                .padding(.horizontal, 45)
            }
        }
    }

    @ViewBuilder
    private var title: some View {
        HStack {
            Text(verbatim: "Battery Low")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
                .fontWeight(.semibold)
                .lineLimit(1)

            Text("\(batteryLevel)%")
                .font(.system(size: 12))
                .fontWeight(.semibold)
                .foregroundStyle(batteryColor)
        }
    }

    @ViewBuilder
    private var description: some View {
        if isLowPowerMode {
            Text(verbatim: "Low Power Mode enabled")
                .foregroundColor(.yellow)
                .font(.system(size: 10, weight: .medium))
            + Text(verbatim: ", it is recommended to charge it.")
                .foregroundColor(.gray.opacity(0.6))
                .font(.system(size: 10, weight: .medium))
        } else {
            Text(verbatim: "Turn on Low Power Mode or it \nis recommended to charge it.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray.opacity(0.6))
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var redIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.red.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.4))
                    .frame(width: 40, height: 24)

                RoundedRectangle(cornerRadius: 10)
                    .fill(.red.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
            .padding(.trailing, 5)

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.gradient)
                .frame(width: 8, height: 14)
                .opacity(pulse ? 1 : 0.3)
                .offset(x: -15)
                .onAppear { startPulse() }

            RoundedRectangle(cornerRadius: 30)
                .stroke(Color.red.opacity(0.9).gradient, lineWidth: 1.5)
                .frame(width: pulse ? 8 : 30, height: pulse ? 14 : 32)
                .offset(x: -15)
                .opacity(pulse ? 0.3 : 1)
        }
    }

    @ViewBuilder
    private var yellowIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.yellow.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 40, height: 24)

                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
            .padding(.trailing, 5)

            RoundedRectangle(cornerRadius: 8)
                .fill(.yellow.gradient)
                .frame(width: 8, height: 14)
                .offset(x: -15)
        }
    }
}

struct FullBatteryTemporaryView: View {
    let batteryLevel: Int
    let isLowPowerMode: Bool
    let style: BatteryNotificationStyle
    let compactHeight: CGFloat

    @State private var pulse = false
    @State private var showBatteryIndicator = false
    @State private var changeBatteryIndicator = false

    private var batteryColor: Color {
        isLowPowerMode ? .yellow : .green
    }

    private func startPulse() {
        pulse = false
        withAnimation(
            .easeInOut(duration: 1)
            .repeatForever(autoreverses: true)
        ) {
            pulse = true
        }
    }

    var body: some View {
        Group {
            if style == .compact {
                BatteryCompactTemporaryView(
                    title: "Full Battery",
                    batteryLevel: batteryLevel,
                    tint: batteryColor,
                    compactHeight: compactHeight
                )
            } else {
                VStack {
                    Spacer()

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            title
                            description
                        }

                        Spacer()

                        if showBatteryIndicator {
                            if isLowPowerMode {
                                yellowIndicator
                                    .transition(.scale.combined(with: .opacity))
                            } else {
                                greenIndicator
                                    .transition(.scale.combined(with: .opacity))
                            }
                        } else {
                            magSafeIndicator
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
                .onAppear {
                    showBatteryIndicator = false
                    changeBatteryIndicator = true

                    withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.84, blendDuration: 0.1)) {
                        showBatteryIndicator = true
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if showBatteryIndicator {
                            withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.9, blendDuration: 0.1)) {
                                showBatteryIndicator = false
                            }
                        }
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if changeBatteryIndicator {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                changeBatteryIndicator = false
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var title: some View {
        HStack {
            Text(verbatim: "Full Battery")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
                .fontWeight(.semibold)
                .lineLimit(1)

            Text("\(batteryLevel)%")
                .font(.system(size: 13))
                .fontWeight(.semibold)
                .foregroundStyle(batteryColor)
        }
    }

    @ViewBuilder
    private var description: some View {
        Text(verbatim: "Your Mac is fully charged.")
            .font(.system(size: 10))
            .foregroundStyle(.gray.opacity(0.6))
            .fontWeight(.medium)
            .lineLimit(1)
    }

    @ViewBuilder
    private var greenIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.green.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.green.opacity(0.4))
                    .frame(width: 44, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.gradient)
                            .frame(width: 34, height: 14)
                            .opacity(pulse ? 1 : 0.4)
                            .onAppear {
                                startPulse()
                            }
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(.green.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
        }
    }

    @ViewBuilder
    private var yellowIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(.yellow.opacity(0.2))
                .frame(width: 70, height: 40)

            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 44, height: 24)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.yellow.gradient)
                            .frame(width: 34, height: 14)
                            .opacity(pulse ? 1 : 0.4)
                            .onAppear {
                                startPulse()
                            }
                    )

                RoundedRectangle(cornerRadius: 10)
                    .fill(.yellow.opacity(0.4))
                    .frame(width: 3, height: 8)
            }
        }
    }

    @ViewBuilder
    private var magSafeIndicator: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.gray.opacity(0.15))
                .frame(width: 30, height: 5)

            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.gray.opacity(0.2).gradient)
                    .frame(width: 30, height: 40)

                Circle()
                    .fill(changeBatteryIndicator ? .orange : .green)
                    .shadow(color: changeBatteryIndicator ? .orange : .green, radius: 5)
                    .frame(width: 5, height: 5)
            }

            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 3, height: 32)
        }
    }
}

#Preview {
    DynamicIslandBatteryView(
        batteryWidth: 30,
        isCharging: false,
        isInLowPowerMode: false,
        isPluggedIn: true,
        levelBattery: 80,
        maxCapacity: 100,
        timeToFullCharge: 10,
        isForNotification: false
    ).frame(width: 200, height: 200)
}
