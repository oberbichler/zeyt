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

/// A proposal from the presence detection: start, break or end of day, with apply and dismiss.
struct ProposalBanner: View {
    let proposal: Proposal
    let apply: () -> Void
    let other: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let t: (Date) -> String = { Fmt.time.string(from: $0) }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if case .start(let at, let label) = proposal {
                        if let label {
                            Button(L("#%1$@ ab %2$@", label, t(at)), action: apply).controlSize(.small)
                        }
                        Button(label == nil ? L("Ab %@ eintragen …", t(at)) : L("Andere …"), action: other).controlSize(.small)
                    } else {
                        Button(applyTitle, action: apply).controlSize(.small)
                    }
                    Spacer(minLength: 4)
                    Button(dismissTitle, action: dismiss)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
        .padding(.horizontal, 6)
    }

    private var icon: String {
        switch proposal {
        case .start: return "sunrise"
        case .pause: return "cup.and.saucer"
        case .endOfDay: return "moon"
        }
    }

    private var title: String {
        let t: (Date) -> String = { Fmt.time.string(from: $0) }
        switch proposal {
        case .start(let at, _): return L("Seit %@ am Mac", t(at))
        case .pause(let from, let to, _): return L("Weg von %1$@ bis %2$@", t(from), t(to))
        case .endOfDay(let at): return L("Feierabend um %@?", t(at))
        }
    }

    private var detail: String {
        switch proposal {
        case .start: return L("Noch nichts eingetragen – Arbeit ab da eintragen?")
        case .pause(_, _, let resume):
            return L("Als Pause eintragen? Danach weiter mit %@.", resume.label.isEmpty ? resume.title : "#" + resume.label)
        case .endOfDay(let at):
            return L("%1$@ war noch offen; zuletzt am Mac um %2$@.", Fmt.longDay.string(from: at), Fmt.time.string(from: at))
        }
    }

    private var applyTitle: String {
        if case .pause = proposal { return L("Pause eintragen") }
        return L("Feierabend eintragen")
    }

    private var dismissTitle: String {
        if case .pause = proposal { return L("War Arbeit") }
        return L("Ignorieren")
    }
}
