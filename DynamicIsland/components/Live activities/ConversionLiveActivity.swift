import SwiftUI

struct ConversionLiveActivity: View {
    @State private var manager = ConversionManager.shared
    
    var body: some View {
        HStack(spacing: 60) {
            // Animated Icon
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative.reversing, isActive: !manager.isConversionCompleted)
            
            // Status Text
            Text(manager.isConversionCompleted ? "Converted" : "Converting...")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            
            // Progress Indicator
            if manager.isConversionCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                SpinningCircleDownloadView()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: manager.isConversionCompleted)
    }
}
