# zeyt

macOS-Menüleisten-App zur Zeiterfassung (Swift, SwiftPM, AppKit + SwiftUI). Der Nutzer verwendet sie
täglich und lässt Änderungen und Fixes über Claude machen.

- Name immer klein: **zeyt** (App, Programmdatei, Modul, Texte). Bundle-ID `xyz.oberbichler.zeyt`.
- Oberfläche übersetzt: Quelltexte deutsch über `L("…")` (`Localization.swift`), Übersetzungen in
  `Sources/zeyt/Resources/<sprache>.lproj/Localizable.strings` (en, fr, es, it, pl, nl, pt; `de` leer, weil
  die Schlüssel deutsch sind). Neue oder geänderte Texte in allen Sprachen nachziehen, `LocalizationTests`
  prüft Vollständigkeit und Platzhalter. Eingabesyntax (`pause`, `feierabend`, `#urlaub` …) bleibt unübersetzt.
  App in einer Sprache starten: `open build/zeyt.app --args -AppleLanguages "(en)"`.
- Code-Kommentare englisch, Antworten an den Nutzer deutsch.
- Nur committen, wenn der Nutzer es verlangt.

## Ablauf für eine Änderung

1. Ursache im Code finden; Logik, die sich ohne UI testen lässt, gehört nach `Model.swift`/`EntryStore.swift`.
2. Test ergänzen (`Tests/zeytTests`, Swift Testing) und `./test.sh` laufen lassen.
3. `./build.sh install`: sichert die Daten, installiert nach `~/Applications/zeyt.app` und startet neu.
4. Dem Nutzer sagen, was geändert ist und was er ausprobieren soll.

```sh
./test.sh                  # Tests (läuft nur mit den Command Line Tools, ohne Xcode)
./build.sh                 # build/zeyt.app
./build.sh install         # Daten sichern, installieren, neu starten
./build.sh release 1.2.0   # Universal-App, dist/zeyt-1.2.0.zip, dist/zeyt.rb (Cask)
```

## Echte Daten – vorsichtig

- `~/Library/Application Support/zeyt/log.csv` (Einträge) und `labels.json`. Nie direkt ändern, außer
  der Nutzer verlangt es; dann vorher sichern.
- `backups/<Zeitstempel>/` darin: Stand vor jedem `./build.sh install` (die letzten 30).
- Zum Ausprobieren eine Kopie nehmen: `ZEYT_DATA_DIR=/tmp/… ` (eigener Datenordner).
- Einstellungen: `defaults read xyz.oberbichler.zeyt` (u. a. `agentToken`, `exportScript`).

## Die laufende App prüfen

- Agent-API: `curl -s -H "Authorization: Bearer $(defaults read xyz.oberbichler.zeyt agentToken)" http://127.0.0.1:7239/api/summary`
  (`GET /` listet alle Endpunkte). Nur lesend benutzen, solange der Nutzer nichts anderes sagt.
- Abstürze: `~/Library/Logs/DiagnosticReports/zeyt-*.ips`.
- Es läuft immer nur eine Instanz (`LSMultipleInstancesProhibited`). Eine Testinstanz mit
  `open -W --env ZEYT_DATA_DIR=… build/zeyt.app` startet nur, wenn vorher `pkill -x zeyt` lief;
  danach mit `./build.sh install` die echte App wieder starten.
- **UI-Tests per Skript** (Layout, Fokus, Ruckeln): `./build.sh uitest` baut `build/zeyt-uitest.app` mit
  `Sources/zeyt/UITestScript.swift` (nur mit `-DZEYT_UITEST` kompiliert, Befehle im Dateikopf: `key`, `type`,
  `click`, `snap`, `burst`, `frames`, `dump`, `reopen`, `appearance`, `settings`, `labels`, `notifications` …).
  Die Testinstanz hat die Bundle-ID `xyz.oberbichler.zeyt.uitest`, also eigene Einstellungen, und trägt sich
  nicht als Anmeldeobjekt ein. Start:
  `pkill -x zeyt; open -g -W --env ZEYT_DATA_DIR=<Kopie> --env ZEYT_UISCRIPT=<skript> --env ZEYT_UIOUT=<ordner> build/zeyt-uitest.app`,
  danach `./build.sh install`. Die Testinstanz aktiviert sich nicht und blockiert echte Tastendrücke, der
  Nutzer kann weiterarbeiten. `click` markiert den Feldinhalt (wie Tab), Shift+Enter lässt sich so nicht
  testen (`NSApp.currentEvent` fehlt).
- Auswerten: Bilder sind 2x. `burst N` nimmt nach jeder Aktion N Bilder im 16-ms-Takt auf; Bilder, die weder
  dem Zustand davor noch danach gleichen, sind Ruckeln/Flackern. Für Umbauten ohne sichtbare Änderung:
  Referenzbilder vorher/nachher aufnehmen und pixelweise vergleichen. Grundlinien lassen sich mit
  Testtext ohne Unterlängen (`#hh HHHH`) pixelgenau messen.
- Die Zwischenablage des Nutzers nicht überschreiben.
- README-Screenshots: `./docs/screenshot.sh` (Beispieldaten, UI-Test, Menüleiste bzw. Fensterrahmen per
  `docs/make-screenshot.swift` dazugezeichnet). Nach sichtbaren Änderungen am Popover neu erzeugen.

## Aufbau (`Sources/zeyt`)

| Datei | Inhalt |
| --- | --- |
| `main.swift`, `AppDelegate.swift` | Start, Menüleisten-Uhr, Popover, Fenster, Erinnerungs-Takt, Autostart |
| `Migration.swift` | übernimmt einmalig Einstellungen von `local.tmr` (früherer Name TMR) |
| `AppState.swift` | gemeinsamer Zustand von Popover und Einstellungen |
| `Model.swift` | testbare Regeln: Labels, Vorschläge, Zeiten, `DayText` (Tag als Text), `Block` (Dauer, Art) |
| `EntryStore.swift` | `Entry`, Abwesenheiten, Laden/Speichern von `log.csv` und `labels.json`, Einfügen/Rückgängig |
| `DayView.swift` | Popover: Kopf mit Wochenleiste, Tagesliste, Eingabezeile, Zahnrad-Menü, Toasts, Fokus/Navigation |
| `DayParts.swift` | Bausteine dazu: `DayBar`, `WeekDayCell`, `StatView`, `HoverRow`, `KindDot`, Knöpfe, `RowMetrics` |
| `Fields.swift`, `ComboBox.swift` | Eingabefelder (Zeit, Label, Kommentar) |
| `DayCopy.swift` | Tag kopieren/einfügen, Zwischenablage |
| `LabelsView.swift` | Fenster „Labels“ (Account, Projekt) |
| `SettingsView.swift`, `ExportSettings.swift` | Einstellungen (Tabs Allgemein, Export, Agent) |
| `ExportScript.swift`, `Export.swift` | Export per JavaScript (JavaScriptCore), Vorlagen Chronos und CSV |
| `Notifier.swift` | Erinnerung als macOS-Mitteilung mit Aktionen (Regel: `Reminder` in `Model.swift`) |
| `AgentAPI.swift`, `HTTPServer.swift` | REST-API auf 127.0.0.1:7239 mit Token |
| `Banners.swift`, `Toast.swift` | Hinweise im Popover, kurze Meldungen |
| `Localization.swift` | `L("…")` und `AppLanguage` (Sprache, Locale für Datumsformate) |
| `UITestScript.swift` | Skript-Steuerung für UI-Tests (nur in `./build.sh uitest`) |

Datenformat `log.csv`: Kopf `Zeit,Tätigkeit`, Zeilen `yyyy-MM-dd HH:mm,"#label Kommentar"`. Ein Eintrag
läuft bis zum nächsten; `pause`/`feierabend` sind Stopps (der letzte Stopp des Tages zählt als
Feierabend). `#urlaub`, `#krank`, `#kind-krank` sind Abwesenheiten.

## Release

Tag `v*` pushen → `.github/workflows/release.yml` baut, legt das GitHub-Release an und aktualisiert
`oberbichler/homebrew-tap` (Secret `HOMEBREW_TAP_TOKEN`). Der Cask (`packaging/zeyt.rb`) nutzt Homebrew-7-Syntax
(`postflight_steps`) und entfernt die Quarantäne, weil die App nur ad hoc signiert ist. Die Signatur
hat eine feste Anforderung (`designated => identifier …`), damit die Mitteilungs-Erlaubnis Updates übersteht.
