import SwiftUI

/// Settings in tabs: general (prompts, menu bar, login item), export script, agent access.
struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var api: AgentAPI
    @ObservedObject var store: EntryStore
    @State private var copied = false
    @State private var newUncounted = ""

    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label(L("Allgemein"), systemImage: "gearshape") }.tag("general")
            Form { ExportSettings(store: store) }
                .formStyle(.grouped)
                .tabItem { Label(L("Export"), systemImage: "square.and.arrow.up") }.tag("export")
            agent.tabItem { Label(L("Agent"), systemImage: "sparkles") }.tag("agent")
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addUncounted(_ input: String) {
        let label = Rules.tag(input)
        if !label.isEmpty { store.setCounts(false, for: label) }
        newUncounted = ""
    }

    private var general: some View {
        Form {
            Section(L("Allgemein")) {
                Toggle(L("Bei Anmeldung starten"), isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
                Toggle(L("Laufende Tätigkeit in der Menüleiste zeigen"), isOn: $state.showInMenuBar)
            }

            Section {
                Toggle(L("Labels nicht mitzählen"), isOn: $state.uncountedEnabled)
                if state.uncountedEnabled {
                    ForEach(store.uncounted, id: \.self) { label in
                        HStack {
                            let kind = store.kind(label)
                            if kind.isAbsence {
                                Image(systemName: kind.icon).foregroundStyle(kind.color).frame(width: 18)
                            }
                            Text("#" + label)
                            Spacer()
                            Button { store.setCounts(true, for: label) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(L("Wieder mitzählen"))
                        }
                    }
                    HStack {
                        TextField("", text: $newUncounted, prompt: Text(L("#label hinzufügen")))
                            .labelsHidden()
                            .onSubmit { addUncounted(newUncounted) }
                        let candidates = store.labels.filter { store.counts($0) }
                        if !candidates.isEmpty {
                            Menu {
                                ForEach(candidates, id: \.self) { label in Button("#" + label) { addUncounted(label) } }
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help(L("Verwendetes Label wählen"))
                        }
                    }
                }
            } header: {
                Text(L("Stunden und BT"))
            } footer: {
                Text(L("Die Zeit dieser Labels zählt nicht zu den Stunden und BT von Tag, Woche und Wochenleiste. Abwesenheiten zählen anfangs nicht; Art und „Zählt“ lassen sich auch im Fenster „Labels“ einstellen. Ausgeschaltet zählt alles. Der Export entscheidet im Skript selbst."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("Erinnern, wenn der aktuellen Zeit kein Label zugeordnet ist"), isOn: $state.reminder.enabled)
                if state.reminder.enabled {
                    Picker(L("Erinnern nach"), selection: $state.reminder.minutes) {
                        ForEach(Reminder.intervals, id: \.self) { Text(L("%@ Minuten", "\($0)")).tag($0) }
                    }
                    HStack {
                        Text(L("Nur zwischen"))
                        Spacer()
                        MinutePicker(minutes: $state.reminder.from)
                        Text(L("und"))
                        MinutePicker(minutes: $state.reminder.to)
                    }
                    Toggle(L("Nur Montag bis Freitag"), isOn: $state.reminder.weekdaysOnly)
                    if !state.notificationsAllowed {
                        HStack {
                            Label(L("Mitteilungen für zeyt sind nicht erlaubt – Erinnerungen erscheinen nicht."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button(L("Erlauben …")) { Notifier.openSystemSettings() }
                        }
                    }
                    HStack {
                        Text(Self.describe(state.reminderStatus))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Jetzt erinnern")) { state.promptNow() }
                            .help(L("Zeigt die Erinnerung sofort, zum Ausprobieren"))
                    }
                }
            } header: {
                Text(L("Erinnerung"))
            } footer: {
                Text(L("Erinnert, solange heute noch nichts eingetragen ist oder der laufende Eintrag kein Label hat – zuerst nach der eingestellten Zeit, dann im selben Abstand. Keine Erinnerung während einer Pause, nach Feierabend und bei Urlaub, Krank oder Kind krank."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    static func describe(_ status: Reminder.Status) -> String {
        switch status {
        case .off: return L("Erinnerung aus")
        case .outside: return L("Gerade außerhalb der Erinnerungszeit")
        case .assigned(let e):
            guard let e else { return L("Keine Erinnerung nötig") }
            if e.isStop { return e.isEndOfDay ? L("Feierabend – keine Erinnerung") : L("Pause – keine Erinnerung") }
            if let a = e.absence { return L("%@ – keine Erinnerung", a.title) }
            return L("#%@ läuft – keine Erinnerung nötig", e.label)
        case .due(let since, let due):
            return L("Ohne Label seit %1$@ · Erinnerung um %2$@", Fmt.time.string(from: since), Fmt.time.string(from: due))
        }
    }

    private var agent: some View {
        Form {
            Section {
                Toggle(L("Agent-Zugriff über lokale API"), isOn: Binding(get: { api.enabled }, set: { api.enabled = $0 }))
                if let error = api.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if api.enabled {
                    Label(L("Läuft auf %@", "\(api.baseURL)"), systemImage: "circle.fill").foregroundStyle(.green)
                }
                if api.enabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(L("Prompt für deinen Agent"))
                            Text(L("Enthält deinen Token, halte ihn privat.")).font(.caption).foregroundStyle(.secondary)
                        }
                        ZStack(alignment: .topTrailing) {
                            Text(api.prompt)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .padding(.trailing, 24)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(api.prompt, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help(L("Kopieren"))
                            .padding(8)
                        }
                    }
                    Button(L("Token neu erzeugen")) { api.regenerateToken() }
                        .help(L("Bisher verbundene Agents verlieren den Zugriff."))
                }
            } header: {
                Text(L("Agent"))
            } footer: {
                Text(L("Ein KI-Agent (z. B. Claude Code) kann über die API Einträge lesen und bearbeiten. Den Prompt gibt es auch im Zahnrad-Menü; dort schaltet „Prompt für Agent kopieren“ den Zugriff bei Bedarf ein."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Time of day as minutes since midnight, edited as hours and minutes.
struct MinutePicker: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minutes * 60)) },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes = c.hour! * 60 + c.minute!
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .fixedSize()
    }
}
