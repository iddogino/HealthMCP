import SwiftUI
import CoreImage.CIFilterBuiltins

enum Brand {
    static let background = Color(red: 0.028, green: 0.054, blue: 0.11)
    static let surface = Color(red: 0.066, green: 0.102, blue: 0.18)
    static let raised = Color(red: 0.10, green: 0.15, blue: 0.25)
    static let accent = Color(red: 0.46, green: 0.93, blue: 0.85)
    static let secondary = Color(red: 0.63, green: 0.70, blue: 0.81)
    static let border = Color.white.opacity(0.09)
}
struct BrandMark: View {
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: "waveform.path.ecg").font(.system(size: size * 0.48, weight: .bold))
            .foregroundStyle(Brand.background).frame(width: size, height: size)
            .background(Brand.accent, in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 0) { content }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Brand.surface, in: RoundedRectangle(cornerRadius: 26)).overlay(RoundedRectangle(cornerRadius: 26).stroke(Brand.border, lineWidth: 1)) }
}
struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 18).foregroundStyle(Brand.background).background(Brand.accent.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 18)) }
}
struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16).foregroundStyle(Brand.accent).background(Brand.raised.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 18)) }
}
struct Eyebrow: View { let text: String; var body: some View { Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Brand.secondary) } }
struct PrivateKeyView: View {
    let key: String
    var body: some View {
        VStack(spacing: 22) {
            if let image = qrImage(key) { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 180, height: 180).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 20)).accessibilityLabel("Private key QR code") }
            Text(HealthCrypto.formatted(key)).font(.system(.title3, design: .monospaced, weight: .semibold)).foregroundStyle(Brand.accent).minimumScaleFactor(0.7).lineLimit(1).textSelection(.enabled).accessibilityIdentifier("private-key")
            Button { UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: HealthCrypto.formatted(key)]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]) } label: { Label("Copy private key", systemImage: "doc.on.doc") }.buttonStyle(SecondaryButton())
        }.frame(maxWidth: .infinity)
    }
    private func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(HealthCrypto.formatted(value).utf8)
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let output = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: output)
    }
}
extension View { func healthBackground() -> some View { background(Brand.background.ignoresSafeArea()) } }
