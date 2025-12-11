import SwiftUI
import Defaults

struct ConversionPopoverView: View {
    var body: some View {
        ConversionActionView(isPopover: true)
            .frame(width: 300, height: 200)
    }
}
