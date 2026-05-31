import SwiftUI

/// "This invoice has a watermark / Remove with Pro" upgrade nudge. Shared by the
/// pre-send preview and the (more-revisited) invoice detail screen so they can't drift.
struct WatermarkUpgradeBanner: View {
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This invoice has a watermark.")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("Remove watermark with Pro →").font(.caption).foregroundStyle(.tint)
                }
                Spacer()
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
