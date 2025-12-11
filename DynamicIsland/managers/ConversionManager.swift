import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
class ConversionManager {
    static let shared = ConversionManager()
    
    private(set) var isConverting: Bool = false
    private(set) var isConversionCompleted: Bool = false
    
    private let coordinator = DynamicIslandViewCoordinator.shared
    private var completionTimer: Timer?
    
    private init() {}
    
    func startConversion() {
        updateConversionState(isActive: true)
    }
    
    func finishConversion(success: Bool = true) {
        if success {
            updateConversionState(isActive: false)
        } else {
            closeConversionViewImmediately()
        }
    }
    
    private func updateConversionState(isActive: Bool) {
        completionTimer?.invalidate()
        completionTimer = nil
        
        if isActive {
            isConversionCompleted = false
            
            if !isConverting {
                withAnimation(.smooth) {
                    isConverting = true
                }
                coordinator.toggleExpandingView(
                    status: true,
                    type: .conversion,
                    value: 0
                )
            }
            
        } else {
            if isConverting {
                withAnimation(.smooth) {
                    isConversionCompleted = true
                }
                
                completionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.closeConversionView()
                    }
                }
            }
        }
    }
    
    private func closeConversionView() {
        withAnimation(.smooth) {
            isConverting = false
            isConversionCompleted = false
        }
        
        coordinator.toggleExpandingView(
            status: false,
            type: .conversion,
            value: 0
        )
    }
    
    private func closeConversionViewImmediately() {
        completionTimer?.invalidate()
        completionTimer = nil
        
        withAnimation(.smooth) {
            isConverting = false
            isConversionCompleted = false
        }
        
        coordinator.toggleExpandingView(
            status: false,
            type: .conversion,
            value: 0
        )
    }
}
