import SwiftUI

extension LabelKind {
    var color: Color {
        switch self {
        case .work: return .secondary
        case .vacation: return .teal
        case .sick: return .red
        case .childSick: return .orange
        case .otherAbsence: return .indigo
        }
    }
}

/// Shown in the popover while zeyt may not post notifications (the prompts need them).
struct NotificationsBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .foregroundStyle(Look.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Mitteilungen sind aus")).font(.system(size: 13, weight: .semibold))
                Text(L("Ohne sie fragt zeyt nicht alle 30 Minuten."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(L("Erlauben …")) { Notifier.openSystemSettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Look.warning.opacity(0.12)))
        .padding(.horizontal, 6)
    }
}
