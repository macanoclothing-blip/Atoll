/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import Cocoa
import Defaults
import Foundation
import IOKit.ps
import SwiftUI

enum BatteryTemporaryActivityKind: Equatable {
    case charging
    case lowPower
    case fullPower
}

struct BatteryTemporaryActivityState: Identifiable, Equatable {
    let id = UUID()
    let kind: BatteryTemporaryActivityKind
    let batteryLevel: Int
}

/// A view model that manages and monitors the battery status of the device
class BatteryStatusViewModel: ObservableObject {

    var animations: DynamicIslandAnimations = DynamicIslandAnimations()
    private let lowBatteryAlertSoundPlayer = AudioPlayer()

    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared

    @Published private(set) var levelBattery: Float = 0.0
    @Published private(set) var maxCapacity: Float = 0.0
    @Published private(set) var isPluggedIn: Bool = false
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isInLowPowerMode: Bool = false
    @Published private(set) var isInitial: Bool = false
    @Published private(set) var timeToFullCharge: Int = 0
    @Published private(set) var statusText: String = ""
    @Published private(set) var activeNotification: BatteryTemporaryActivityState?

    private let managerBattery = BatteryActivityManager.shared
    private var managerBatteryId: Int?

    static let shared = BatteryStatusViewModel()

    /// Initializes the view model with a given BoringViewModel instance
    /// - Parameter vm: The BoringViewModel instance
    private init() {
        setupPowerStatus()
        setupMonitor()
    }

    /// Sets up the initial power status by fetching battery information
    private func setupPowerStatus() {
        let batteryInfo = managerBattery.initializeBatteryInfo()
        updateBatteryInfo(batteryInfo)
    }

    /// Sets up the monitor to observe battery events
    private func setupMonitor() {
        managerBatteryId = managerBattery.addObserver { [weak self] event in
            guard let self = self else { return }
            self.handleBatteryEvent(event)
        }
    }

    /// Handles battery events and updates the corresponding properties
    /// - Parameter event: The battery event to handle
    private func handleBatteryEvent(_ event: BatteryActivityManager.BatteryEvent) {
        switch event {
        case .powerSourceChanged(let isPluggedIn):
            print("🔌 Power source: \(isPluggedIn ? "Connected" : "Disconnected")")
            withAnimation {
                self.isPluggedIn = isPluggedIn
                self.statusText = isPluggedIn ? String(localized: "Plugged In") : String(localized: "Unplugged")
            }

        case .batteryLevelChanged(let level):
            print("🔋 Battery level: \(Int(level))%")
            let previousLevel = self.levelBattery
            withAnimation {
                self.levelBattery = level
            }
            self.handleLevelBasedNotifications(previousLevel: previousLevel, newLevel: level)

        case .lowPowerModeChanged(let isEnabled):
            print("⚡ Low power mode: \(isEnabled ? "Enabled" : "Disabled")")
            let previousValue = self.isInLowPowerMode
            withAnimation {
                self.isInLowPowerMode = isEnabled
                self.statusText = String(localized: "Low Power: \(self.isInLowPowerMode ? String(localized: "On") : String(localized: "Off"))")
            }
            if !previousValue && isEnabled && Defaults[.showLowBatteryNotification] {
                self.statusText = String(localized: "Low battery")
                self.presentTemporaryActivity(
                    .lowPower,
                    duration: Defaults[.lowBatteryNotificationDuration],
                    displayLevel: Int(self.levelBattery.rounded())
                )
            }

        case .isChargingChanged(let isCharging):
            print("🔌 Charging: \(isCharging ? "Yes" : "No")")
            print("maxCapacity: \(self.maxCapacity)")
            print("levelBattery: \(self.levelBattery)")
            let previousValue = self.isCharging
            withAnimation {
                self.isCharging = isCharging
                self.statusText =
                    isCharging
                    ? String(localized: "Charging battery")
                    : (self.levelBattery < self.maxCapacity ? String(localized: "Not charging") : String(localized: "Full charge"))
            }
            if !previousValue && isCharging && Defaults[.showChargingBatteryNotification] {
                self.presentTemporaryActivity(
                    .charging,
                    duration: Defaults[.chargingNotificationDuration],
                    displayLevel: Int(self.levelBattery.rounded())
                )
            }

        case .timeToFullChargeChanged(let time):
            print("🕒 Time to full charge: \(time) minutes")
            withAnimation {
                self.timeToFullCharge = time
            }

        case .maxCapacityChanged(let capacity):
            print("🔋 Max capacity: \(capacity)")
            withAnimation {
                self.maxCapacity = capacity
            }

        case .error(let description):
            print("⚠️ Error: \(description)")
        }
    }

    /// Updates the battery information with the given BatteryInfo instance
    /// - Parameter batteryInfo: The BatteryInfo instance containing the battery data
    private func updateBatteryInfo(_ batteryInfo: BatteryInfo) {
        withAnimation {
            self.levelBattery = batteryInfo.currentCapacity
            self.isPluggedIn = batteryInfo.isPluggedIn
            self.isCharging = batteryInfo.isCharging
            self.isInLowPowerMode = batteryInfo.isInLowPowerMode
            self.timeToFullCharge = batteryInfo.timeToFullCharge
            self.maxCapacity = batteryInfo.maxCapacity
            self.statusText = batteryInfo.isPluggedIn ? String(localized: "Plugged In") : String(localized: "Unplugged")
        }
    }

    private func handleLevelBasedNotifications(previousLevel: Float, newLevel: Float) {
        if shouldTriggerLowBatteryNotification(previousLevel: previousLevel, newLevel: newLevel) {
            self.statusText = String(localized: "Low battery")
            self.presentTemporaryActivity(
                .lowPower,
                duration: Defaults[.lowBatteryNotificationDuration],
                displayLevel: Int(newLevel.rounded())
            )

            if Defaults[.playLowBatteryAlertSound] {
                playLowBatteryAlertSound()
            }
        }

        if shouldTriggerFullBatteryNotification(previousLevel: previousLevel, newLevel: newLevel) {
            self.statusText = String(localized: "Full charge")
            self.presentTemporaryActivity(
                .fullPower,
                duration: Defaults[.fullBatteryNotificationDuration],
                displayLevel: Int(newLevel.rounded())
            )
        }
    }

    private func shouldTriggerLowBatteryNotification(previousLevel: Float, newLevel: Float) -> Bool {
        guard Defaults[.showLowBatteryNotification] else { return false }
        guard !isPluggedIn, !isCharging else { return false }
        guard newLevel < previousLevel else { return false }

        let threshold = Float(Defaults[.lowBatteryNotificationThreshold])
        return previousLevel > threshold && newLevel <= threshold
    }

    private func shouldTriggerFullBatteryNotification(previousLevel: Float, newLevel: Float) -> Bool {
        guard Defaults[.showFullBatteryNotification] else { return false }
        guard newLevel > previousLevel else { return false }

        let threshold = Float(Defaults[.fullBatteryNotificationThreshold])
        return previousLevel < threshold && newLevel >= threshold
    }

    private func presentTemporaryActivity(
        _ kind: BatteryTemporaryActivityKind,
        duration: TimeInterval,
        displayLevel: Int? = nil
    ) {
        activeNotification = BatteryTemporaryActivityState(
            kind: kind,
            batteryLevel: resolvedNotificationLevel(for: kind, override: displayLevel)
        )
        coordinator.toggleExpandingView(
            status: true,
            type: .battery,
            duration: duration
        )
    }

    private func resolvedNotificationLevel(for kind: BatteryTemporaryActivityKind, override: Int?) -> Int {
        if let override {
            return clampedBatteryLevel(override)
        }

        let currentLevel = Int(levelBattery.rounded())

        switch kind {
        case .charging:
            return clampedBatteryLevel(currentLevel)
        case .lowPower:
            return clampedBatteryLevel(min(currentLevel, Defaults[.lowBatteryNotificationThreshold]))
        case .fullPower:
            return clampedBatteryLevel(max(currentLevel, Defaults[.fullBatteryNotificationThreshold]))
        }
    }

    private func clampedBatteryLevel(_ value: Int) -> Int {
        max(0, min(value, 100))
    }

    private func playLowBatteryAlertSound() {
        lowBatteryAlertSoundPlayer.play(fileName: "lowbattery", fileExtension: "mp3")
    }

    /// Forces a notification to appear for testing purposes
    func forceTriggerNotification(kind: BatteryTemporaryActivityKind) {
        let duration: TimeInterval
        let previewLevel: Int

        switch kind {
        case .charging:
            duration = Defaults[.chargingNotificationDuration]
            previewLevel = min(max(Int(levelBattery.rounded()), 67), 96)
        case .lowPower:
            duration = Defaults[.lowBatteryNotificationDuration]
            previewLevel = max(5, min(Defaults[.lowBatteryNotificationThreshold], 20))
        case .fullPower:
            duration = Defaults[.fullBatteryNotificationDuration]
            previewLevel = Defaults[.fullBatteryNotificationThreshold]
        }

        presentTemporaryActivity(kind, duration: duration, displayLevel: previewLevel)
    }

    deinit {
        print("🔌 Cleaning up battery monitoring...")
        if let managerBatteryId: Int = managerBatteryId {
            managerBattery.removeObserver(byId: managerBatteryId)
        }
    }

}
