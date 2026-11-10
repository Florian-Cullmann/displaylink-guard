# DisplayLink Guard

Ein natives macOS-Hilfsprogramm gegen den Speicheranstieg des privilegierten DisplayLink-Helfers. Ein Benutzer-LaunchAgent misst **alle drei Stunden** dessen Speicher-Footprint (`top` → `MEM`, einschließlich komprimiertem Speicher). Ab **2048 MiB (2 GiB)** genügt eine Messung für einen Neustart. Es gibt **kein Tageslimit**.

Neugestartet wird ausschließlich der Systemdienst `system/com.displaylink.DisplayLinkManager.PrivilegedHelper` mit `launchctl kickstart -k`. WindowServer und DisplayLinkUserAgent werden nicht beendet. Der Monitor kann beim Neustart kurz schwarz werden; Fenster können sich verschieben. Der zugrunde liegende DisplayLink-Fehler wird damit nicht behoben.

Hintergrund: [DisplayLink-Forum, Supportbestätigung vom 20.10.2026 und Helper-Workaround](https://www.displaylink.org/forum/printthread.php?t=69953).

## Installation und Aktualisierung

Voraussetzungen: macOS 13 oder neuer, Xcode Command Line Tools, DisplayLink Manager unter `/Applications/DisplayLink Manager.app` und ein laufender privilegierter DisplayLink-Hilfsdienst.

```sh
bash scripts/install.sh
```

Im normalen aktiven Benutzerkonto ausführen. Der Installer baut das Programm und fragt einmal nach dem Administratorpasswort. Er installiert eine mit `visudo` geprüfte, root-eigene sudoers-Regel für **genau diesen Benutzer und genau diesen Befehl**:

```sh
/bin/launchctl kickstart -k system/com.displaylink.DisplayLinkManager.PrivilegedHelper
```

Es werden keine beliebigen Befehle oder benutzerveränderbaren Programme zur Ausführung als root freigegeben. Das Tool selbst bleibt ein Benutzerprozess. Automatische Neustarts verwenden `sudo -n` und können keine Passwortabfrage auslösen.

Das Programm wird nach `~/Library/Application Support/DisplayLinkGuard/` kopiert und der LaunchAgent `~/Library/LaunchAgents/de.fcullmann.displaylink-guard.plist` ersetzt. Bestehende Port-Konfigurationen werden bei `install` migriert und als `*.v1-backup` gesichert. Der alte Grenzwert und das Tageslimit entfallen; ein gespeicherter letzter Neustartversuch bleibt erhalten. Alte Konfigurationen werden erst bei der Installation umgestellt.

## Verhalten

- Prüfung beim Laden des LaunchAgents und danach alle 10800 Sekunden. Der Mac wird nicht geweckt; Schlaf kann Prüfungen verzögern.
- Ein Messwert ab dem Grenzwert genügt. Zwischen Neustartversuchen liegen mindestens drei Stunden, auch nach Fehlern oder manuellen Aufrufen. Kein Tageslimit.
- Fünf Minuten Schonzeit beim ersten Check bzw. neuem WindowServer; nach Messpausen über 4,5 Stunden oder rückwärts springender Uhr zwei Minuten. Ein während der Schonzeit übersprungener Check wird beim nächsten regulären Intervall wiederholt.
- Der Helper muss mindestens 15 Minuten laufen. DisplayLink Manager muss im eigenen aktiven Benutzerkonto laufen und ein externer Bildschirm aktiv sein.
- Der Helper-PID wird aus dem fest vorgegebenen Systemdienst ermittelt und gegen UID 0 und den erwarteten Programmpfad geprüft; unmittelbar vor dem Neustart erneut.
- Der Versuch wird vor `kickstart` gespeichert. Nach einem Abbruch wird kein unmittelbarer weiterer Neustart ausgelöst.
- Bis zu 90 Sekunden Kontrolle: neuer Helper-PID, vorherige aktive Bildschirmmodi und gesunkener Speicherverbrauch. Vorher-/Nachher-Werte werden protokolliert. Fehlende Bestätigungen ergeben `restart_verification_incomplete`, ohne weiteren Neustart.
- Messfehler, fehlende Rechte oder beschädigte Konfigurationen werden protokolliert. Fehlende Messwerte lösen keinen Neustart aus.

## Bedienung

```sh
"$HOME/Library/Application Support/DisplayLinkGuard/displaylink-guard" status
"$HOME/Library/Application Support/DisplayLinkGuard/displaylink-guard" check --dry-run
"$HOME/Library/Application Support/DisplayLinkGuard/displaylink-guard" check
"$HOME/Library/Application Support/DisplayLinkGuard/displaylink-guard" uninstall
```

`check --dry-run` misst ohne Zustandsänderung oder Neustart. `check` durchläuft die normale Entscheidung einschließlich Grenzwert und Sperrzeit. `uninstall` entfernt den Autostart; Konfiguration und Logs bleiben. Die separat installierte Neustartberechtigung entfernen:

```sh
sudo rm "/private/etc/sudoers.d/displaylink-guard-$(id -u)"
```

## Konfiguration

`~/Library/Application Support/DisplayLinkGuard/settings.json` wird bei jeder Prüfung gelesen. Alle Felder müssen vorhanden sein. Änderungen erfordern keine Neuinstallation.

| Einstellung | Standard | Gültiger Bereich |
| --- | ---: | ---: |
| `thresholdMemoryMiB` | 2048 | 1–1048576 |
| `cooldownSeconds` | 10800 | 10800–604800 |
| `startupGraceSeconds` | 300 | 0–86400 |
| `resumeGraceSeconds` | 120 | 0–3600 |
| `minimumHelperAgeSeconds` | 900 | 0–86400 |

Sehr niedrige Grenzwerte sind für Funktionstests vorgesehen. Der Prüfzyklus bleibt fest bei drei Stunden. Status in `state.json` im selben Verzeichnis; Logs in `~/Library/Logs/DisplayLinkGuard/events.log`, bei 1 MiB einmal rotiert. Keine Netzwerkverbindung oder Bildschirmaufzeichnung.

## Entwicklung

```sh
swift test
swift build --configuration release
.build/release/displaylink-guard check --dry-run
```

Tests prüfen Entscheidungen, Sperrzeiten, PID-/UID-Prüfung, Speicherparsing und Neustartkontrolle mit simuliertem Systemzugriff. Sie lösen keinen echten Neustart aus. Ein Live-Test erfolgt ausschließlich über `check`; nötigenfalls vorher den Grenzwert vorübergehend senken und danach wiederherstellen.
