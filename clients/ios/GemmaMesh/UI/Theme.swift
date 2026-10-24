import SwiftUI

/// The Android app's palette: warm stone neutrals, teal for the phone, blue for the mesh, amber for the cloud.
enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let background = dyn(0xFAFAF9, 0x0C0A09)
    static let surface = dyn(0xF2F0EE, 0x1C1917)
    static let surfaceHigh = dyn(0xECE9E6, 0x292524)
    static let card = dyn(0xFFFFFF, 0x0C0A09)
    static let outline = dyn(0xD6D3D1, 0x44403C)
    static let outlineSoft = dyn(0xE7E5E4, 0x292524)
    static let text = dyn(0x1C1917, 0xF5F5F4)
    static let muted = dyn(0x57534E, 0xA8A29E)
    static let userBubble = dyn(0xEDEAE7, 0x2E2A27)
    static let warnBg = dyn(0xFDEBC8, 0x4A2E07)
    static let warnFg = dyn(0x6B3206, 0xFDE3A8)
    static let accent = dyn(0x1C1917, 0xFAFAF9)

    static let phone = dyn(0x0F766E, 0x2DD4BF)
    static let mesh = dyn(0x2563EB, 0x60A5FA)
    static let cloud = dyn(0xB45309, 0xFBBF24)
    static let off = dyn(0xA8A29E, 0x57534E)

    /// T0 the phone, T1–T3 the mesh, T4 the cloud.
    static func tier(_ t: String?) -> Color {
        switch t {
        case "T0": return phone
        case "T4": return cloud
        case nil, "", "?": return mesh
        default: return mesh
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

struct Dot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}
