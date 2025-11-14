import SwiftUI

@_silgen_name("$s7SwiftUI5ImageV19_internalSystemNameACSS_tcfC")
private func _swiftUI_image(internalSystemName: String) -> Image?

extension Image {
    init?(internalSystemName systemName: String) {
        guard let systemImage = _swiftUI_image(internalSystemName: systemName) else {
            return nil
        }

        self = systemImage
    }
}
