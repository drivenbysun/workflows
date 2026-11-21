# workflows

Geteilte, aufrufbare GitHub-Actions-Workflows (`workflow_call`) der Fabrik.

Derzeit einer:

| Workflow | Zweck |
|---|---|
| [`set-server-secrets.yml`](.github/workflows/set-server-secrets.yml) | Trägt Geheimnisse und Einstellwerte in die `.env` eines Dienstes auf einem **eigenen Server** ein — ohne dass ein Wert durch einen Chat oder eine Prozessliste läuft. |

Dieses Repo enthält **keine Geheimnisse, keine Servernamen, keine Schlüssel**. Alles
Konkrete (Host, Nutzer, Pfad, Hostschlüssel, Secret-Namen) liefert der Aufrufer.
Die Sicherheit beruht nicht auf Geheimhaltung des Codes, sondern auf den Regeln unten
und darauf, dass jeder Aufrufer eine **geprüfte Version fest anpinnt**.

---

## `set-server-secrets`

### Wofür

Wer den Server nicht selbst bedient, legt die Werte als **GitHub-Secret** im eigenen
Repo an. Der Workflow schreibt sie in die `.env`, die der Dienst beim Start liest
(z. B. als systemd-`EnvironmentFile`). Kein Chat, kein Kopieren, kein Root-Login von Hand.

Er startet **nichts neu** und deployt **nichts**. Wirksam wird der Wert beim nächsten
Neustart des Dienstes.

### Aufruf

Im Aufrufer-Repo, z. B. `.github/workflows/server-secrets.yml`:

```yaml
name: Server-Geheimnisse eintragen

on:
  workflow_dispatch:
    inputs:
      dry-run:
        description: "true = nur prüfen und melden, .env nicht anfassen"
        type: boolean
        default: true

permissions: {}

# gleiche Gruppe wie der Deploy: nie gleichzeitig an derselben .env
concurrency:
  group: deploy-mein-dienst
  cancel-in-progress: false

jobs:
  set-secrets:
    permissions: {}
    # IMMER auf einen vollständigen Commit-SHA pinnen, nie auf @main oder ein Tag
    # (ein bewegliches Ziel könnte die übergebenen Secrets abgreifen).
    uses: drivenbysun/workflows/.github/workflows/set-server-secrets.yml@<40-stelliger-commit-sha>
    with:
      host: 203.0.113.10
      user: meindienst
      env-file: /opt/meindienst/shared/.env
      # Öffentlicher Hostschlüssel des Servers, FEST eingetragen (siehe unten).
      host-key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."
      # SLOT=SCHLÜSSEL_IN_DER_.ENV
      secret-names: |
        V01=GOOGLE_CLIENT_ID
        V02=GOOGLE_CLIENT_SECRET
      # nicht geheim, steht im Klartext hier:
      plain-values: |
        STORAGE_BUCKET=mein-bucket
      # erzeugt der Server selbst, NUR wenn sie fehlen:
      random-keys: "SESSION_JWT_SECRET AUTH_STATE_SECRET"
      # Formprüfung (grep -E); fängt vertauschte Slots und Tippfehler:
      patterns: |
        GOOGLE_CLIENT_ID=^[0-9]+-[A-Za-z0-9_-]+[.]apps[.]googleusercontent[.]com$
      dry-run: ${{ inputs.dry-run }}
    secrets:
      SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
      V01: ${{ secrets.GOOGLE_CLIENT_ID }}
      V02: ${{ secrets.GOOGLE_CLIENT_SECRET }}
```

Die GitHub-Secret-Namen im Aufrufer sind frei wählbar; nur `V01=…` bestimmt, unter
welchem Schlüssel der Wert in der `.env` landet.

### Eingaben

| Eingabe | Pflicht | Bedeutung |
|---|---|---|
| `host` | ja | Servername oder IPv4 |
| `user` | ja | SSH-Nutzer; ihm muss die `.env` gehören |
| `port` | nein (22) | SSH-Port |
| `env-file` | ja | absoluter Pfad der `.env` (nur `A-Za-z0-9._/-`, kein `..`) |
| `host-key` | ja | **gepinnter** öffentlicher ED25519-Hostschlüssel, `ssh-ed25519 AAAA…` in einer Zeile |
| `secret-names` | nein* | je Zeile `V01=NAME` (Slot `V01`…`V10`) |
| `plain-values` | nein* | je Zeile `NAME=wert`, nicht geheim |
| `random-keys` | nein | Namen, die der Server per `openssl rand -hex 32` erzeugt, **nur wenn sie fehlen** |
| `patterns` | nein | je Zeile `NAME=ERE`, Formprüfung des Werts |
| `dry-run` | nein (false) | alles prüfen, aber die `.env` **nicht** verändern |

\* mindestens einer der beiden muss einen Wert enthalten.

Secrets: `SSH_KEY` (Pflicht, privater Schlüssel für `user@host`) und `V01`…`V10`.

**Warum feste Slots?** Ein aufrufbarer Workflow kann nur Secrets annehmen, die er beim
Namen kennt; eine dynamische Liste geht nicht. `secrets: inherit` würde dagegen *alle*
Secrets des Aufrufers durchreichen, das tut dieser Workflow bewusst nicht. Ein belegter,
aber in `secret-names` nicht benannter Slot bricht deshalb ab, ebenso ein benannter, aber
leerer.

### Den Hostschlüssel richtig besorgen

Der Hostschlüssel ist das, was verhindert, dass die Werte bei umgelenkter Verbindung
(DNS, Route) beim Falschen landen. Er wird **einmal bewusst** eingetragen und nie zur
Laufzeit geholt.

1. **Auf dem Server** (nicht über das Netz):
   ```sh
   cat /etc/ssh/ssh_host_ed25519_key.pub
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub     # Fingerabdruck SHA256:…
   ```
2. Die erste Zeile (`ssh-ed25519 AAAA…`, ohne Kommentar am Ende) ist der Wert für `host-key`.
3. Gegenprobe an einem Rechner, der den Server seit Langem kennt:
   `ssh-keygen -F <host>` und den Fingerabdruck vergleichen.

**Nie** `ssh-keyscan` als Quelle verwenden: das vertraut jedem, der im Moment antwortet.
Ändert sich der Serverschlüssel (Neuinstallation), bricht der Workflow ab — dann den
Schlüssel bewusst neu eintragen, nie blind übernehmen.

### Was garantiert ist

Jeder Punkt ist in [`test/run.sh`](test/run.sh) gegen einen echten `sshd` und eine
Wegwerf-`.env` geprüft.

- **Werte laufen nur als Step-`env` und per stdin zum Server.** Nie als Argument, nie in
  `GITHUB_ENV`, kein `echo`, kein `set -x`. Im Log stehen nur Namen:
  `OK  NAME: gesetzt` / `OK  NAME: unverändert` / `FEHLT NAME`.
- **Fehlt ein Secret**, bricht der Workflow **vor** jeder Verbindung mit dem *Namen* ab.
  Nichts wird geschrieben, kein leerer Wert.
- **Hostschlüssel gepinnt:** `StrictHostKeyChecking yes`, eigene `known_hosts` mit genau
  diesem Schlüssel, `GlobalKnownHostsFile /dev/null`, nur `ssh-ed25519`. Ein anderer
  Schlüssel → Abbruch vor der Anmeldung; die Werte verlassen den Runner nie.
- **Zeichensatz der Werte** `A-Za-z0-9_.:/+=@%,~-`, höchstens 4096 Zeichen. Leerzeichen,
  Zeilenumbruch, Anführungszeichen, Backslash, `$`, `#` werden abgelehnt (sie würden eine
  `EnvironmentFile` still verfälschen oder eine zweite Zeile einschleusen). Die Prüfung
  läuft auf dem Runner **und** noch einmal auf dem Server.
- **Neue Datei wird vor dem Austausch geprüft:** alle übrigen Zeilen unverändert (auch
  Kommentare, Leerzeilen, Anführungszeichen), jeder verwaltete Schlüssel genau einmal,
  nicht leer, mit dem erwarteten Wert. Erst dann atomar per `mv`, Rechte `600`.
  Gehört die `.env` nicht dem SSH-Nutzer, Abbruch statt Besitzerwechsel. Symlinks werden
  abgelehnt.
- **Zufallswerte nur, wenn sie fehlen.** Ein zweiter Lauf ändert nichts, sonst würden
  laufende Sitzungen ungültig.
- **Lauf ohne Änderung → Datei bytegleich**, keine neue Sicherung.
- Vor jeder echten Änderung entsteht `<env-file>.bak-vor-secrets` (Rechte bleiben).
- **`permissions: {}`**, keine fremden Actions (kein `uses:` im Workflow), kein Checkout.

### Grenzen (bewusst)

- Nur `ssh-ed25519`. Nur einzeilige Werte; ein PEM-Schlüssel gehört nicht in eine `.env`.
- Höchstens 10 Werte je Aufruf.
- Der Server braucht `sh`, `grep`, `sed`, `cut`, `tr`, `mktemp`, `stat`, `base64` und
  `openssl` (oder `/dev/urandom` + `od`). Gedacht für Linux mit `dash`/`bash`.
- Ein Geheimnis, das schon im Aufrufer-Repo als Secret liegt, schützt dieser Workflow
  nicht vor dem, der dort Workflows ändern darf: wer den Aufrufer-Workflow ändert, kann
  Secrets abgreifen. Schutz dagegen sind Branch-Schutz und der Commit-SHA-Pin.

### Version anheben

Aufrufer pinnen einen Commit-SHA. Ein neuer Stand kommt erst an, wenn der Aufrufer den SHA
**bewusst** in einem Pull Request ändert; dort die Änderung dieses Repos lesen. Änderungen
hier nur per Pull Request, und `test/run.sh` muss grün sein (läuft in
[`test.yml`](.github/workflows/test.yml)).

### Test

```sh
test/run.sh
```

Braucht `bash`, `ruby` (nur zum Lesen der YAML), `ssh`/`sshd`. Startet einen `sshd` auf
`127.0.0.1` mit eigenem Hostschlüssel, führt die Schritte des Workflows **unverändert aus
der YAML** aus und wirft alles danach weg.
