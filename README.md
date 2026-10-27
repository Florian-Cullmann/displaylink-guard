# DisplayLink Guard

Ein kleines natives macOS-Hilfsprogramm, das die Mach-Ports von WindowServer überwacht und bei dauerhaft hohen Werten DisplayLink Manager neu startet. Es braucht keine Administratorrechte, kein Python und kein Dock- oder Menüleistensymbol.

Ein Benutzer-LaunchAgent prüft alle 60 Sekunden und startet auch nach der nächsten Anmeldung wieder. Zwischen den Prüfungen läuft kein eigener Prozess. Der Mac wird dafür nicht aus dem Ruhezustand geweckt.

## Installation

Voraussetzungen: macOS 13 oder neuer, Xcode Command Line Tools und DisplayLink Manager unter `/Applications/DisplayLink Manager.app`.

```sh
bash scripts/install.sh
```

Der Installer baut das native Programm, installiert es nach `~/Library/Application Support/DisplayLinkGuard/` und aktiviert `~/Library/LaunchAgents/de.fcullmann.displaylink-guard.plist`. Keine Dateien müssen im Projektordner bleiben, damit der installierte Dienst funktioniert.

## Verhalten

- Neustart ab **45.000 Mach-Ports**, bestätigt durch **drei Messungen** im Minutenabstand.
- Mindestens **sechs Stunden Abstand** zwischen Versuchen und höchstens **drei Versuche in 24 Stunden**. Auch fehlgeschlagene Versuche zählen, damit keine Wiederholungsschleife entsteht.
- Fünf Minuten Schonzeit nach dem ersten Start bzw. einem neuen WindowServer; nach längeren Messpausen zwei Minuten. Die Bestätigung beginnt danach neu.
- DisplayLink muss mindestens 15 Minuten laufen. Manuell beendetes DisplayLink bleibt geschlossen.
- Falls das Hilfsprogramm während eines eigenen Neustarts zwischen Beenden und Öffnen abbricht, versucht die nächste Prüfung innerhalb von fünf Minuten einmalig, DisplayLink wieder zu öffnen. Diese Ausnahme gilt nur für einen protokollierten, begonnenen Neustart in derselben Sitzung.
- Neustarts erfolgen nur für die eigene aktive macOS-Anmeldung und bei einem externen Bildschirm.
- Nur der vorher erneut überprüfte DisplayLink-Prozess des eigenen Benutzers erhält SIGTERM. WindowServer wird nicht beendet und DisplayLink nicht zwangsweise abgeschossen.
- Nach dem Start wartet der Dienst bis zu 90 Sekunden auf die vorherigen aktiven Bildschirme mit denselben Auflösungen und Bildraten. Abweichungen werden protokolliert; Auflösungen werden nicht geändert.

Der angeschlossene DisplayLink-Monitor wird beim Neustart vorübergehend schwarz und Fenster können sich verschieben. Die Wiederverbindung kann mehrere zehn Sekunden dauern. Die Zahl der Mach-Ports ist ein Indikator, kein Beweis für die Ursache eines Rucklers. Hohe Werte können nach einem Neustart bestehen bleiben; deshalb sind die Begrenzungen nötig. Dies ist ein Workaround für einen reproduzierbar durch DisplayLink-Neustart gebesserten Zustand.

## Status, Konfiguration und Entfernen

```sh
"$HOME/Library/Application Support/DisplayLinkGuard/displaylink-guard" status
"$HOME/Library/Application Support/DisplayLinkGuard/displaylink-guard" check --dry-run
"$HOME/Library/Application Support/DisplayLinkGuard/displaylink-guard" uninstall
```

`check --dry-run` misst und zeigt die Entscheidung, schreibt keinen Zustand und startet nichts neu. `uninstall` beendet die Überwachung und entfernt den Autostart; Konfiguration und Protokoll bleiben erhalten.

Die Datei `~/Library/Application Support/DisplayLinkGuard/settings.json` wird bei jeder Prüfung neu gelesen. Änderungen brauchen keine Neuinstallation. Alle Felder müssen vorhanden sein; ungültige oder beschädigte Konfiguration bzw. Zustandsdaten verhindern einen Neustart.

| Einstellung | Standard | Gültiger Bereich |
| --- | ---: | ---: |
| `thresholdPorts` | 45000 | 1000–10000000 |
| `consecutiveSamples` | 3 | 2–20 |
| `cooldownSeconds` | 21600 | 900–604800 |
| `maximumRestartsPerDay` | 3 | 1–12 |
| `startupGraceSeconds` | 300 | 0–86400 |
| `resumeGraceSeconds` | 120 | 0–3600 |
| `minimumDisplayLinkAgeSeconds` | 900 | 0–86400 |

Der Zustand liegt in `state.json` im selben Verzeichnis. Das Ereignisprotokoll liegt unter `~/Library/Logs/DisplayLinkGuard/events.log` und wird bei 1 MiB einmal rotiert. Protokolliert werden Messwerte, Entscheidungen und Neustartergebnisse; es gibt keine Netzwerkverbindung und keine Aufzeichnung von Bildschirminhalten.

## Entwicklung

```sh
swift test
swift build --configuration release
.build/release/displaylink-guard check --dry-run
```

Die Prüfungen verwenden das mit macOS gelieferte `ps` und `top`. Externe Befehle bekommen einzelne Argumente statt Shell-Text, eine feste Umgebung und ein Zeitlimit. Gleichzeitige Prüfungen werden über eine Dateisperre ausgeschlossen. Ein anstehender Neustart wird vor dem ersten Signal dauerhaft gespeichert; auch ein Abbruch des Hilfsprogramms hebt die Sperrzeit nicht auf.
