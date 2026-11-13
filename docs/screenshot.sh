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
    [("09:00", "#vacation")],
    [("08:30", "#webshop Sprint Planning"), ("10:30", "#api Deployment"), ("12:15", "pause"),
     ("13:00", "#internal Training"), ("17:00", "feierabend")],
]
workdays, day = [], now
while len(workdays) < len(days):
    day -= timedelta(days=1)
    if day.weekday() < 5:
        workdays.insert(0, day)
# Older weeks for the calendar: rotating workdays, a few days off, back about two months.
templates = [
    [("08:30", "#webshop Daily"), ("08:45", "#webshop Feature work"), ("12:15", "pause"),
     ("13:00", "#api Review"), ("17:00", "feierabend")],
    [("08:00", "#api Backend"), ("12:00", "pause"), ("12:30", "#internal Team meeting"),
     ("13:30", "#api Backend"), ("16:15", "feierabend")],
    [("09:00", "#webshop Daily"), ("09:15", "#webshop Bugfixes"), ("12:30", "pause"),
     ("13:15", "#webshop Bugfixes"), ("18:00", "feierabend")],
    [("08:45", "#internal Email"), ("09:15", "#api Deployment"), ("12:00", "pause"),
     ("12:45", "#webshop Rework"), ("15:30", "feierabend")],
]
older, day, i = [], workdays[0], 0
while (workdays[0] - day).days < 62:
    day -= timedelta(days=1)
    if day.weekday() < 5:
        i += 1
        entries = [("09:00", "#vacation")] if i in (9, 10, 11) else [("09:00", "#sick")] if i == 23 \
            else templates[i % len(templates)]
        older.insert(0, (day, entries))
today = [(245, "#internal Email"), (230, "#webshop Daily"), (215, "#api Invoice endpoint"),
         (110, "pause"), (80, "#api Invoice tests"), (40, "#webshop Checkout page")]
with open(f"{out}/log.csv", "w") as f:
    f.write("Zeit,Tätigkeit\n")
    for day, entries in older + list(zip(workdays, days)):
        for time, text in entries:
            f.write(f'{day.strftime("%Y-%m-%d")} {time},"{text}"\n')
    for minutes, text in today:
        f.write(f'{(now - timedelta(minutes=minutes)).strftime("%Y-%m-%d %H:%M")},"{text}"\n')
json.dump({"webshop": {"account": "Customer A", "project": "Webshop 2.0"},
           "api": {"account": "Customer B", "project": "Invoicing API"},
           "internal": {"account": "Internal", "project": "General"},
           "vacation": {"kind": "vacation"}, "sick": {"kind": "sick"}}, open(f"{out}/labels.json", "w"))
# Presence today, matching the entries (the break left out), so no proposal shows.
f = "%Y-%m-%d %H:%M:%S"
first, lunch, back = (now - timedelta(minutes=m) for m in (today[0][0] + 3, today[3][0] - 2, today[4][0] - 1))
open(f"{out}/activity.csv", "w").write(
    f"Von,Bis\n{first.strftime(f)},{lunch.strftime(f)}\n{back.strftime(f)},{(now + timedelta(minutes=30)).strftime(f)}\n")
# A second data folder for the break proposal: today without the break and what followed, the user
# away over lunch and back now.
import os, shutil
os.makedirs(f"{out}/proposal")
shutil.copy(f"{out}/labels.json", f"{out}/proposal/labels.json")
lines = open(f"{out}/log.csv").read().splitlines(keepends=True)
cut = {(now - timedelta(minutes=m)).strftime("%Y-%m-%d %H:%M") for m, _ in today[3:]}
open(f"{out}/proposal/log.csv", "w").writelines(l for l in lines if l[:16] not in cut)
shutil.copy(f"{out}/activity.csv", f"{out}/proposal/activity.csv")
# Status item as zeyt shows it: label and duration of the running entry
running = datetime.now() - (now - timedelta(minutes=today[-1][0]))
minutes = int(running.total_seconds()) // 60
open(f"{out}/title", "w").write(f" webshop · {minutes // 60}:{minutes % 60:02d}")
minutes = int((datetime.now() - (now - timedelta(minutes=today[2][0]))).total_seconds()) // 60
open(f"{out}/title-proposal", "w").write(f" api · {minutes // 60}:{minutes % 60:02d}")
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
settings reminder
settings presence
settings export
labels
calendar CALENDAR_MONTH
target calendar
click 880 272
move 300 20
wait 400
snap calendar-highlight
quit
EOF
# The calendar shows a full month: the last one early in the month.
sed -i '' "s/CALENDAR_MONTH/$(( $(date +%-d) < 20 ? -1 : 0 ))/" "$TMP/script.txt"

./build.sh uitest
# Settings of the test instance (own domain): show the list of labels left out of the hours, offer
# proposals afresh.
defaults write xyz.oberbichler.zeyt.uitest uncountedEnabled -bool true
defaults delete xyz.oberbichler.zeyt.uitest dismissedProposals 2>/dev/null || true
defaults delete xyz.oberbichler.zeyt.uitest autoBreaks 2>/dev/null || true
pkill -x zeyt || true
open -g -W --env ZEYT_DATA_DIR="$TMP" --env ZEYT_UISCRIPT="$TMP/script.txt" --env ZEYT_UIOUT="$TMP/out" build/zeyt-uitest.app \
    --args -AppleLanguages "(en)"

printf 'notifications on\nmove 1 1\nappearance light\nwait 500\nsnap proposal\nquit\n' > "$TMP/proposal.txt"
open -g -W --env ZEYT_DATA_DIR="$TMP/proposal" --env ZEYT_UISCRIPT="$TMP/proposal.txt" --env ZEYT_UIOUT="$TMP/out-proposal" \
    build/zeyt-uitest.app --args -AppleLanguages "(en)"
mv $TMP/out-proposal/*-proposal.png "$TMP/out/"

TITLE=$(<"$TMP/title")
shot() { swift docs/make-screenshot.swift $TMP/out/*-$1.png "docs/$2.png" "${@:3}" }
shot light screenshot-light light popover "$TITLE"
shot dark screenshot-dark dark popover "$TITLE"
shot entry entry light popover "$TITLE"
shot settings-reminder reminders light window "zeyt – Settings"
shot settings-presence presence light window "zeyt – Settings"
shot settings-export export light window "zeyt – Settings"
shot proposal proposal light popover "$(<"$TMP/title-proposal")"
shot labels labels light window "zeyt – Labels"
shot calendar-highlight calendar light window "zeyt – Calendar"
rm -rf "$TMP"
[[ -d ~/Applications/zeyt.app ]] && open ~/Applications/zeyt.app
ls docs/*.png
