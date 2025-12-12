//
//  DynamicIslandViewModel.swift
//  DynamicIsland
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Combine
import Defaults
import SwiftUI

@MainActor
class DynamicIslandViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animationLibrary: DynamicIslandAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed

    @Published var dragDetectorTargeting: Bool = false
    @Published var dropZoneTargeting: Bool = false
    @Published var dropEvent: Bool = false
    @Published var anyDropZoneTargeting: Bool = false
    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = true
    @Published var isHoveringCalendar: Bool = false
    @Published var isBatteryPopoverActive: Bool = false
    @Published var isClipboardPopoverActive: Bool = false
    @Published var isColorPickerPopoverActive: Bool = false
    @Published var isStatsPopoverActive: Bool = false
    @Published var isReminderPopoverActive: Bool = false
    @Published var isMediaOutputPopoverActive: Bool = false
    @Published var isTimerPopoverActive: Bool = false
    @Published var shouldRecheckHover: Bool = false
    
    let webcamManager = WebcamManager.shared
    @Published var isCameraExpanded: Bool = false
    @Published var isRequestingAuthorization: Bool = false

    @Published var screen: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()
    
    private var cachedEffectiveClosedNotchHeight: CGFloat?
    
    @MainActor
    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screen: String? = nil) {
        animation = animationLibrary.animation

        super.init()
        
        self.screen = screen
        notchSize = getClosedNotchSize(screen: screen)
        closedNotchSize = notchSize

        Publishers.CombineLatest($dropZoneTargeting, $dragDetectorTargeting)
            .map { $0 || $1 }
            .assign(to: \.anyDropZoneTargeting, on: self)
            .store(in: &cancellables)
        
        setupDetectorObserver()

        // MARK: - Reminder Live Activity Observer
        ReminderLiveActivityManager.shared.$activeWindowReminders
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchState == .open else { return }
                guard self.notchSize != updatedTarget else { return }

                self.applyNotchSizeChange(
                    updatedTarget,
                    animateNotch: .smooth,
                    isMinimalistic: Defaults[.enableMinimalisticUI],
                    windowAnimated: false,
                    forceWindow: false
                )
            }
            .store(in: &cancellables)

        // MARK: - Lyrics Observer
        let enableLyricsPublisher = Defaults.publisher(.enableLyrics).map { $0.newValue }

        enableLyricsPublisher
            .combineLatest(MusicManager.shared.$currentLyrics)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard Defaults[.enableMinimalisticUI] else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchState == .open else { return }
                guard self.notchSize != updatedTarget else { return }

                self.applyNotchSizeChange(
                    updatedTarget,
                    animateNotch: .smooth,
                    isMinimalistic: Defaults[.enableMinimalisticUI],
                    windowAnimated: false,
                    forceWindow: false
                )
            }
            .store(in: &cancellables)

        // MARK: - Timer Observer
        TimerManager.shared.$activeSource
            .combineLatest(TimerManager.shared.$isTimerActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.handleMinimalisticTimerHeightChange()
            }
            .store(in: &cancellables)

        // MARK: - Stats Expansion Observer
        coordinator.$statsSecondRowExpansion
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.notchState == .open else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchSize != updatedTarget else { return }

                self.applyNotchSizeChange(
                    updatedTarget,
                    animateNotch: .easeInOut(duration: 0.3),
                    isMinimalistic: Defaults[.enableMinimalisticUI],
                    windowAnimated: false
                )
            }
            .store(in: &cancellables)

        // MARK: - Open Notch Width Observer
        Defaults.publisher(.openNotchWidth, options: [])
            .map { $0.newValue }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.notchState == .open else { return }
                guard !Defaults[.enableMinimalisticUI] else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchSize != updatedTarget else { return }

                self.applyNotchSizeChange(
                    updatedTarget,
                    animateNotch: .smooth,
                    isMinimalistic: false,
                    windowAnimated: false
                )
            }
            .store(in: &cancellables)

        // MARK: - HUD Sneak Peek Observer
        coordinator.$sneakPeek
            .removeDuplicates { old, new in
                let oldIsHUD = old.show && (old.type == .volume || old.type == .brightness || old.type == .backlight)
                let newIsHUD = new.show && (new.type == .volume || new.type == .brightness || new.type == .backlight)
                return oldIsHUD == newIsHUD && old.type == new.type
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard Defaults[.enableMinimalisticUI] else { return }
                guard self.notchState == .open else { return }
                let updatedTarget = self.calculateDynamicNotchSize()
                guard self.notchSize != updatedTarget else { return }

                self.applyNotchSizeChange(
                    updatedTarget,
                    animateNotch: .smooth,
                    isMinimalistic: Defaults[.enableMinimalisticUI],
                    windowAnimated: false
                )
            }
            .store(in: &cancellables)
    }

    private func handleMinimalisticTimerHeightChange() {
        guard Defaults[.enableMinimalisticUI] else { return }
        guard notchState == .open else { return }
        let updatedTarget = calculateDynamicNotchSize()
        guard notchSize != updatedTarget else { return }

        applyNotchSizeChange(
            updatedTarget,
            animateNotch: .smooth,
            isMinimalistic: Defaults[.enableMinimalisticUI],
            windowAnimated: false
        )
    }
    
    private func setupDetectorObserver() {
        let enabledPublisher = Defaults
            .publisher(.enableFullscreenMediaDetection)
            .map(\.newValue)

        let statusPublisher = $screen
            .compactMap { $0 }
            .removeDuplicates()
            .map { screenName in
                self.detector.$fullscreenStatus
                    .map { $0[screenName] ?? false }
                    .removeDuplicates()
            }
            .switchToLatest()

        Publishers.CombineLatest(statusPublisher, enabledPublisher)
            .map { status, enabled in enabled && status }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }
    
    var effectiveClosedNotchHeight: CGFloat {
        if notchState == .open {
            if let cached = cachedEffectiveClosedNotchHeight {
                return cached
            }
        }
        
        let currentScreen = NSScreen.screens.first { $0.localizedName == screen }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        let calculatedHeight = noNotchAndFullscreen ? 0 : closedNotchSize.height
        
        if notchState == .open {
            cachedEffectiveClosedNotchHeight = calculatedHeight
        }
        
        return calculatedHeight
    }

    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {
        let screenFrame = getScreenFrame(screen)
        if let frame = screenFrame {
            let baseY = frame.maxY - notchSize.height
            let baseX = frame.midX - notchSize.width / 2
            return position.y >= baseY && position.x >= baseX && position.x <= baseX + notchSize.width
        }
        return false
    }

    func open() {
        let targetSize = calculateDynamicNotchSize()

        applyNotchSizeChange(
            targetSize,
            animateNotch: animationLibrary.animation,
            isMinimalistic: Defaults[.enableMinimalisticUI],
            windowAnimated: false,
            forceWindow: true
        )

        notchState = .open
        MusicManager.shared.forceUpdate()
    }
    
    private func calculateDynamicNotchSize() -> CGSize {
        let baseSize = Defaults[.enableMinimalisticUI] ? minimalisticOpenNotchSize : openNotchSize
        return statsAdjustedNotchSize(
            from: baseSize,
            isStatsTabActive: DynamicIslandViewCoordinator.shared.currentView == .stats,
            secondRowProgress: coordinator.statsSecondRowExpansion
        )
    }

    func close() {
        let targetSize = getClosedNotchSize(screen: screen)
        notchSize = targetSize
        closedNotchSize = targetSize
        notchState = .closed
        cachedEffectiveClosedNotchHeight = nil

        if !ShelfStateViewModel.shared.isEmpty && Defaults[.openShelfByDefault] {
            coordinator.currentView = .shelf
        } else if !coordinator.openLastTabByDefault {
            coordinator.currentView = .home
        }
    }

    func closeForLockScreen() {
        let targetSize = getClosedNotchSize(screen: screen)
        withAnimation(.none) {
            notchSize = targetSize
            closedNotchSize = targetSize
            notchState = .closed
        }
        cachedEffectiveClosedNotchHeight = nil
    }

    func closeHello() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            self?.coordinator.firstLaunch = false
            withAnimation(self?.animationLibrary.animation) {
                self?.close()
            }
        }
    }
    
    func toggleCameraPreview() {
        if isRequestingAuthorization {
            return
        }

        switch webcamManager.authorizationStatus {
        case .authorized:
            if webcamManager.isSessionRunning {
                webcamManager.stopSession()
                isCameraExpanded = false
            } else if webcamManager.cameraAvailable {
                webcamManager.startSession()
                isCameraExpanded = true
            }

        case .denied, .restricted:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = "Camera Access Required"
                alert.informativeText = "Please allow camera access in System Settings."
                alert.addButton(withTitle: "OK")
                alert.runModal()

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .notDetermined:
            isRequestingAuthorization = true
            webcamManager.checkAndRequestVideoAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.isRequestingAuthorization = false
            }

        default:
            break
        }
    }

    // MARK: - NEW Helper: Apply notch size change safely
    private func applyNotchSizeChange(
        _ target: CGSize,
        animateNotch: Animation? = .smooth,
        isMinimalistic: Bool,
        windowAnimated: Bool = false,
        forceWindow: Bool = false
    ) {
        if let delegate = AppDelegate.shared {
            delegate.ensureWindowSize(
                addShadowPadding(to: target, isMinimalistic: isMinimalistic),
                animated: windowAnimated,
                force: forceWindow
            )
        }

        if let anim = animateNotch {
            withAnimation(anim) {
                self.notchSize = target
            }
        } else {
            self.notchSize = target
        }
    }
}
