#!/bin/zsh
# Erzeugt die Bilder in docs/ für die README:
# Beispieldaten (relativ zu jetzt, also nicht kurz nach Mitternacht laufen lassen), Popover per UI-Test
# aufnehmen (build/zeyt-uitest.app), Menüleiste dazuzeichnen (make-screenshot.swift).
# Beendet eine laufende zeyt-Instanz und startet ~/Applications/zeyt.app danach wieder.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
python3 - "$TMP" <<'EOF'
import json, sys
from datetime import datetime, timedelta
out = sys.argv[1]
now = datetime.now().replace(second=0, microsecond=0)
now -= timedelta(minutes=now.minute % 5)
days = [  # the last four workdays before today, oldest first
    [("08:30", "#webshop Daily"), ("08:45", "#webshop Rework cart"), ("12:00", "pause"),
     ("12:45", "#internal Interview"), ("14:00", "#webshop Review"), ("17:15", "feierabend")],
    [("08:15", "#api Debug login"), ("11:30", "#webshop Daily"), ("11:45", "pause"),
     ("12:30", "#api Add tests"), ("16:45", "feierabend")],
    [("09:00", "#urlaub")],
    [("08:30", "#webshop Sprint Planning"), ("10:30", "#api Deployment"), ("12:15", "pause"),
     ("13:00", "#internal Training"), ("17:00", "feierabend")],
]
workdays, day = [], now
while len(workdays) < len(days):
    day -= timedelta(days=1)
    if day.weekday() < 5:
        workdays.insert(0, day)
today = [(245, "#internal Email"), (230, "#webshop Daily"), (215, "#api Invoice endpoint"),
         (110, "pause"), (80, "#api Invoice tests"), (40, "#webshop Checkout page")]
with open(f"{out}/log.csv", "w") as f:
    f.write("Zeit,Tätigkeit\n")
    for day, entries in zip(workdays, days):
        for time, text in entries:
            f.write(f'{day.strftime("%Y-%m-%d")} {time},"{text}"\n')
    for minutes, text in today:
        f.write(f'{(now - timedelta(minutes=minutes)).strftime("%Y-%m-%d %H:%M")},"{text}"\n')
json.dump({"webshop": {"account": "Customer A", "project": "Webshop 2.0"},
           "api": {"account": "Customer B", "project": "Invoicing API"},
           "internal": {"account": "Internal", "project": "General"},
           "urlaub": {"account": "Internal", "project": "Absence"}}, open(f"{out}/labels.json", "w"))
# Status item as zeyt shows it: label and duration of the running entry
running = datetime.now() - (now - timedelta(minutes=today[-1][0]))
minutes = int(running.total_seconds()) // 60
open(f"{out}/title", "w").write(f" webshop · {minutes // 60}:{minutes % 60:02d}")
EOF
cat > "$TMP/script.txt" <<'EOF'
notifications on
move 1 1
appearance dark
wait 500
snap dark
appearance light
wait 500
snap light
type #we
wait 300
snap entry
settings general
settings export
labels
quit
EOF

./build.sh uitest
# Settings of the test instance (own domain): show the list of labels left out of the hours.
defaults write xyz.oberbichler.zeyt.uitest uncountedEnabled -bool true
pkill -x zeyt || true
open -g -W --env ZEYT_DATA_DIR="$TMP" --env ZEYT_UISCRIPT="$TMP/script.txt" --env ZEYT_UIOUT="$TMP/out" build/zeyt-uitest.app \
    --args -AppleLanguages "(en)"

TITLE=$(<"$TMP/title")
shot() { swift docs/make-screenshot.swift $TMP/out/*-$1.png "docs/$2.png" "${@:3}" }
shot light screenshot-light light popover "$TITLE"
shot dark screenshot-dark dark popover "$TITLE"
shot entry entry light popover "$TITLE"
shot settings-general reminders light window "zeyt – Settings"
shot settings-export export light window "zeyt – Settings"
shot labels labels light window "zeyt – Labels"
rm -rf "$TMP"
[[ -d ~/Applications/zeyt.app ]] && open ~/Applications/zeyt.app
ls docs/*.png
