#!/usr/bin/env bash
# Abnahmetest fuer .github/workflows/set-server-secrets.yml.
#
# Fuehrt die Schritte DIESES Workflows unveraendert aus (extrahiert aus der YAML,
# keine zweite Kopie) gegen einen echten, lokal gestarteten sshd und eine
# Wegwerf-.env. Der Server-Teil laeuft also ueber genau den Weg wie in Produktion:
# ssh -> sh -c "$(printf %s <base64> | base64 -d)" mit den Werten auf stdin.
#
#   test/run.sh            alles
# Laeuft lokal (macOS/Linux) und in CI (.github/workflows/test.yml).
set -u
cd "$(dirname "$0")/.."
WF=".github/workflows/set-server-secrets.yml"
T=$(mktemp -d /tmp/dbs-test.XXXXXX)
SSHD_PID=""
PS_PID=""
trap '[ -z "$SSHD_PID" ] || kill "$SSHD_PID" 2>/dev/null; [ -z "$PS_PID" ] || kill "$PS_PID" 2>/dev/null; rm -rf "$T"' EXIT

PASS=0; FAIL=0
gut()   { PASS=$((PASS+1)); echo "  ok    $1"; }
schlecht() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -z "${2:-}" ] || sed 's/^/          | /' <<<"$2"; }
pruefe() { local was="$1"; shift; if "$@" >/dev/null 2>&1; then gut "$was"; else schlecht "$was"; fi; }
pruefe_nicht() { local was="$1"; shift; if "$@" >/dev/null 2>&1; then schlecht "$was"; else gut "$was"; fi; }
summe() { cksum < "$1" | cut -d' ' -f1,2; }

# --- Schritte aus der YAML holen -------------------------------------------
schritt() {
  ruby -ryaml -e '
    y = YAML.load_file(ARGV[0])
    s = y["jobs"]["set-secrets"]["steps"].find { |x| x["id"] == ARGV[1] } or abort("kein Schritt #{ARGV[1]}")
    print s["run"]' "$WF" "$1" > "$T/schritt-$1.sh"
}
for id in pruefen ssh eintragen aufraeumen; do schritt "$id"; done

# --- lokaler sshd -----------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -f "$T/host"      >/dev/null
ssh-keygen -q -t ed25519 -N '' -f "$T/fremd"     >/dev/null   # "falscher" Hostschluessel
ssh-keygen -q -t ed25519 -N '' -f "$T/client"    >/dev/null
cp "$T/client.pub" "$T/authorized_keys"
PORT=$((22000 + RANDOM % 2000))
cat > "$T/sshd_config" <<CONF
Port $PORT
ListenAddress 127.0.0.1
HostKey $T/host
PidFile $T/sshd.pid
AuthorizedKeysFile $T/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
LogLevel INFO
CONF
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
[ -d /run/sshd ] || [ "$(uname)" = Darwin ] || sudo mkdir -p /run/sshd
"$SSHD" -D -f "$T/sshd_config" -E "$T/sshd.log" &
SSHD_PID=$!
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done
(exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || { echo "sshd startet nicht:"; cat "$T/sshd.log"; exit 2; }
ANMELDUNGEN() { grep -c "Accepted publickey" "$T/sshd.log" 2>/dev/null || true; }

# --- ein Lauf: die drei Schritte wie in GitHub, dann Aufraeumen -------------
HOSTKEY_ECHT=$(cut -d' ' -f1,2 "$T/host.pub")
HOSTKEY_FREMD=$(cut -d' ' -f1,2 "$T/fremd.pub")
SRV="$T/srv"; mkdir -p "$SRV"
ENVF="$SRV/app.env"

# Standardbelegung; ein Test ueberschreibt einzelne Variablen vor lauf().
standard() {
  IN_HOST=127.0.0.1; IN_USER=$(id -un); IN_PORT=$PORT; IN_ENVFILE="$ENVF"
  IN_HOSTKEY="$HOSTKEY_ECHT"
  IN_NAMES=$'V01=GOOGLE_CLIENT_ID\nV02=GOOGLE_CLIENT_SECRET'
  IN_PLAIN='R2_BUCKET=mein-bucket-1'
  IN_RANDOM='SESSION_JWT_SECRET AUTH_STATE_SECRET'
  IN_PATTERNS='GOOGLE_CLIENT_ID=^[0-9]+-[A-Za-z0-9_-]+[.]apps[.]googleusercontent[.]com$'
  IN_DRY=false
  SSH_KEY=$(cat "$T/client")
  V01='1234567890-abcDEF_gh.apps.googleusercontent.com'
  V02='GOCSPX-geheimGEHEIM_12345'
  V03=''; V04=''; V05=''; V06=''; V07=''; V08=''; V09=''; V10=''
}
lauf() {  # $1 = Logdatei; Rueckgabe = Exitcode des ersten fehlgeschlagenen Schritts
  local log="$1" rc=0 id
  export RUNNER_TEMP="$T/runner.$RANDOM"; mkdir -p "$RUNNER_TEMP"
  export GITHUB_REPOSITORY=test/repo
  export IN_HOST IN_USER IN_PORT IN_ENVFILE IN_HOSTKEY IN_NAMES IN_PLAIN IN_RANDOM IN_PATTERNS IN_DRY SSH_KEY \
         V01 V02 V03 V04 V05 V06 V07 V08 V09 V10
  : > "$log"
  for id in pruefen ssh eintragen; do
    bash --noprofile --norc -eo pipefail "$T/schritt-$id.sh" >> "$log" 2>&1 || { rc=$?; break; }
  done
  bash --noprofile --norc -eo pipefail "$T/schritt-aufraeumen.sh" >> "$log" 2>&1 || true
  LETZTES_RUNNER_TEMP="$RUNNER_TEMP"
  return $rc
}
frische_env() {
  rm -f "$ENVF" "$ENVF".* 
  cat > "$ENVF" <<'ENVTXT'
# Kommentar bleibt
NODE_ENV=production
PORT=3000
DATABASE_URL="postgresql://app:pw@localhost/db?sslmode=disable"

FEATURE_X=on
ENVTXT
  chmod 600 "$ENVF"
}
ohne_verwaltete() { grep -v -e '^GOOGLE_CLIENT_ID=' -e '^GOOGLE_CLIENT_SECRET=' -e '^R2_BUCKET=' -e '^SESSION_JWT_SECRET=' -e '^AUTH_STATE_SECRET=' "$1"; }
wert_von() { grep "^$1=" "$ENVF" | tail -n 1 | cut -d= -f2-; }
modus() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# --- Gegenprobe der Gegenprobe: gibt es die Markierungen ueberhaupt? --------
M1='1234567890-abcDEF_gh.apps.googleusercontent.com'
M2='GOCSPX-geheimGEHEIM_12345'
kein_wert_im() { ! grep -q -e "$M1" -e "$M2" "$1"; }

echo "== 1. Erstlauf =="
standard; frische_env
cp "$ENVF" "$T/vorher.env"
( while :; do ps -axww -o args= 2>/dev/null; sleep 0.02; done > "$T/ps.log" ) 2>/dev/null & PS_PID=$!
lauf "$T/l1.log"; RC=$?
kill "$PS_PID" 2>/dev/null; wait "$PS_PID" 2>/dev/null; PS_PID=""
[ $RC -eq 0 ] && gut "Exitcode 0" || schlecht "Exitcode 0 (war $RC)" "$(cat "$T/l1.log")"
pruefe "Log: GOOGLE_CLIENT_ID gesetzt"       grep -qx 'OK  GOOGLE_CLIENT_ID: gesetzt' "$T/l1.log"
pruefe "Log: GOOGLE_CLIENT_SECRET gesetzt"   grep -qx 'OK  GOOGLE_CLIENT_SECRET: gesetzt' "$T/l1.log"
pruefe "Log: R2_BUCKET gesetzt"              grep -qx 'OK  R2_BUCKET: gesetzt' "$T/l1.log"
pruefe "Log: Zufallswert SESSION_JWT_SECRET gesetzt" grep -qx 'OK  SESSION_JWT_SECRET: gesetzt' "$T/l1.log"
pruefe "Log: Zufallswert AUTH_STATE_SECRET gesetzt"  grep -qx 'OK  AUTH_STATE_SECRET: gesetzt' "$T/l1.log"
pruefe "Werte stehen in der .env" test "$(wert_von GOOGLE_CLIENT_ID)" = "$M1" -a "$(wert_von GOOGLE_CLIENT_SECRET)" = "$M2"
pruefe "Zufallswerte: 64 Hex-Zeichen" bash -c "wert_von() { grep \"^\$1=\" '$ENVF' | tail -n 1 | cut -d= -f2-; }; wert_von SESSION_JWT_SECRET | grep -Eq '^[0-9a-f]{64}\$' && wert_von AUTH_STATE_SECRET | grep -Eq '^[0-9a-f]{64}\$'"
pruefe "Uebrige Zeilen bytegleich (inkl. Kommentar, Anfuehrungszeichen, Leerzeile)" cmp -s <(ohne_verwaltete "$T/vorher.env") <(ohne_verwaltete "$ENVF")
pruefe "Rechte 600" test "$(modus "$ENVF")" = 600
pruefe "Sicherung .bak-vor-secrets = alte Datei" cmp -s "$T/vorher.env" "$ENVF.bak-vor-secrets"
pruefe "Kein Wert im Log" kein_wert_im "$T/l1.log"
if kein_wert_im "$T/ps.log"; then gut "Kein Wert in der Prozessliste des Runners (best effort, 20-ms-Abtastung; $(grep -c 'dbs-ziel' "$T/ps.log") Abtastungen sahen den ssh-Aufruf)"; else schlecht "Wert in der Prozessliste gesehen" "$(grep -e "$M1" -e "$M2" "$T/ps.log" | cut -c1-200 | head -5)"; fi
pruefe "Nur .env + Sicherung im Zielordner (keine Reste)" test "$(ls -A "$SRV" | sort | tr '\n' ' ')" = "app.env app.env.bak-vor-secrets "
pruefe "Runner-Aufraeumen: Nutzlast und Schluessel weg" bash -c "[ ! -e '$LETZTES_RUNNER_TEMP/dbs-payload' ] && [ ! -e '$LETZTES_RUNNER_TEMP/dbs-ssh' ]"

echo "== 2. Wiederholung: Datei bytegleich, Zufallswerte unveraendert =="
S_VOR=$(summe "$ENVF"); Z1=$(wert_von SESSION_JWT_SECRET); Z2=$(wert_von AUTH_STATE_SECRET); BAK_VOR=$(summe "$ENVF.bak-vor-secrets")
standard; lauf "$T/l2.log"; RC=$?
[ $RC -eq 0 ] && gut "Exitcode 0" || schlecht "Exitcode 0 (war $RC)" "$(cat "$T/l2.log")"
pruefe "Datei bytegleich" test "$(summe "$ENVF")" = "$S_VOR"
pruefe "Zufallswerte unveraendert" test "$(wert_von SESSION_JWT_SECRET)" = "$Z1" -a "$(wert_von AUTH_STATE_SECRET)" = "$Z2"
pruefe "Log: alles unveraendert" bash -c "! grep -q ': gesetzt' '$T/l2.log' && grep -q 'Nichts zu aendern' '$T/l2.log'"
pruefe "Sicherung nicht angefasst" test "$(summe "$ENVF.bak-vor-secrets")" = "$BAK_VOR"

echo "== 3. Ein Wert aendert sich: nur der, Zufallswerte bleiben =="
standard; V02='GOCSPX-NEUneuNEU_98765'
S_VOR=$(summe "$ENVF"); cp "$ENVF" "$T/vor3.env"
lauf "$T/l3.log"; RC=$?
[ $RC -eq 0 ] && gut "Exitcode 0" || schlecht "Exitcode 0 (war $RC)" "$(cat "$T/l3.log")"
pruefe "Log: nur GOOGLE_CLIENT_SECRET gesetzt" bash -c "grep -qx 'OK  GOOGLE_CLIENT_SECRET: gesetzt' '$T/l3.log' && grep -qx 'OK  GOOGLE_CLIENT_ID: unveraendert' '$T/l3.log' && grep -qx 'OK  SESSION_JWT_SECRET: unveraendert' '$T/l3.log'"
pruefe "Neuer Wert steht drin, alter weg" test "$(wert_von GOOGLE_CLIENT_SECRET)" = "GOCSPX-NEUneuNEU_98765" -a "$(grep -c '^GOOGLE_CLIENT_SECRET=' "$ENVF")" = 1
pruefe "Zufallswerte unveraendert" test "$(wert_von SESSION_JWT_SECRET)" = "$Z1" -a "$(wert_von AUTH_STATE_SECRET)" = "$Z2"
pruefe "Uebrige Zeilen bytegleich" cmp -s <(ohne_verwaltete "$T/vor3.env") <(ohne_verwaltete "$ENVF")
pruefe "Rechte 600" test "$(modus "$ENVF")" = 600
pruefe "Sicherung enthaelt den Stand VOR diesem Lauf" cmp -s "$T/vor3.env" "$ENVF.bak-vor-secrets"

echo "== 4. Fehlendes Secret: Abbruch mit NAMEN, nichts geschrieben, kein Verbindungsaufbau =="
standard; V02=''
S_VOR=$(summe "$ENVF"); A_VOR=$(ANMELDUNGEN)
lauf "$T/l4.log"; RC=$?
[ $RC -ne 0 ] && gut "Exitcode != 0" || schlecht "Exitcode != 0"
pruefe "Log nennt FEHLT GOOGLE_CLIENT_SECRET" grep -qx 'FEHLT GOOGLE_CLIENT_SECRET' "$T/l4.log"
pruefe ".env unveraendert" test "$(summe "$ENVF")" = "$S_VOR"
pruefe "Keine SSH-Anmeldung erfolgt" test "$(ANMELDUNGEN)" = "$A_VOR"
pruefe "Kein Wert im Log" kein_wert_im "$T/l4.log"
standard; SSH_KEY=''
lauf "$T/l4b.log"; RC=$?
[ $RC -ne 0 ] && gut "Fehlender SSH_KEY: Exitcode != 0" || schlecht "Fehlender SSH_KEY: Exitcode != 0"
pruefe "Log nennt FEHLT SSH_KEY" grep -qx 'FEHLT SSH_KEY' "$T/l4b.log"
standard; V01=''; V02=''
lauf "$T/l4c.log" || true
pruefe "Mehrere fehlend: beide Namen genannt" bash -c "grep -qx 'FEHLT GOOGLE_CLIENT_ID' '$T/l4c.log' && grep -qx 'FEHLT GOOGLE_CLIENT_SECRET' '$T/l4c.log'"

echo "== 5. Falscher Hostschluessel: Abbruch, keine Anmeldung, nichts geschrieben =="
standard; IN_HOSTKEY="$HOSTKEY_FREMD"; V02='GOCSPX-nichtSchreiben_1'
S_VOR=$(summe "$ENVF"); A_VOR=$(ANMELDUNGEN)
lauf "$T/l5.log"; RC=$?
[ $RC -ne 0 ] && gut "Exitcode != 0" || schlecht "Exitcode != 0"
pruefe "Log: Host key verification failed" grep -q 'Host key verification failed' "$T/l5.log"
pruefe ".env unveraendert" test "$(summe "$ENVF")" = "$S_VOR"
pruefe "Keine SSH-Anmeldung erfolgt (Werte nie gesendet)" test "$(ANMELDUNGEN)" = "$A_VOR"
pruefe "Kein Wert im Log" bash -c "! grep -q 'nichtSchreiben' '$T/l5.log'"
echo "   -- Hostschluessel-Eingabe wird streng geprueft:"
for schlecht_key in "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC" "$HOSTKEY_ECHT
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFremdFremdFremdFremdFremdFremdFremdFremdFremd" "" "ssh-ed25519 AAAA"; do
  standard; IN_HOSTKEY="$schlecht_key"
  lauf "$T/l5b.log"; RC=$?
  [ $RC -ne 0 ] && grep -q 'host-key muss' "$T/l5b.log" && gut "abgelehnt: '$(printf '%s' "$schlecht_key" | head -c 24 | tr '\n' '|')...'" || schlecht "nicht abgelehnt: '$(printf '%s' "$schlecht_key" | head -c 24)'" "$(cat "$T/l5b.log")"
done
pruefe "Nach allem: .env weiter unveraendert" test "$(summe "$ENVF")" = "$S_VOR"

echo "== 6. Formfehler in Werten: Abbruch, nichts geschrieben =="
S_VOR=$(summe "$ENVF")
fall() {  # Beschreibung, Erwartung im Log
  local was="$1" erw="$2"
  lauf "$T/l6.log"; local rc=$?
  if [ $rc -ne 0 ] && grep -q -- "$erw" "$T/l6.log" && [ "$(summe "$ENVF")" = "$S_VOR" ]; then gut "$was"; else schlecht "$was (rc=$rc)" "$(cat "$T/l6.log")"; fi
}
standard; V01=$'1234567890-x.apps.googleusercontent.com\nEVIL=1'
fall "Zeilenumbruch im Secret (Injektion einer zweiten Zeile)" 'GOOGLE_CLIENT_ID enthaelt unerlaubte Zeichen'
pruefe "  ... und der Injektionswert taucht nirgends auf" bash -c "! grep -q 'EVIL' '$ENVF'"
standard; V02='mit Leerzeichen'
fall "Leerzeichen im Secret" 'GOOGLE_CLIENT_SECRET enthaelt unerlaubte Zeichen'
standard; V02='mit"anfuehrung'
fall "Anfuehrungszeichen im Secret" 'GOOGLE_CLIENT_SECRET enthaelt unerlaubte Zeichen'
standard; V02='abc$(id)def'
fall 'Dollar/Klammern im Secret' 'GOOGLE_CLIENT_SECRET enthaelt unerlaubte Zeichen'
standard; V02='abc#kommentar'
fall "Doppelkreuz im Secret" 'GOOGLE_CLIENT_SECRET enthaelt unerlaubte Zeichen'
standard; V02="$(head -c 5000 /dev/zero | tr '\0' 'a')"
fall "Wert laenger als 4096" 'laenger als 4096'
standard; V01='nicht-die-google-form'
fall "Muster aus patterns verletzt (vertauschter Slot faellt so auf)" 'GOOGLE_CLIENT_ID hat nicht die erwartete Form'
standard; IN_PATTERNS='GOOGLE_CLIENT_ID=([unbalanced'
fall "Ungueltiges Muster" 'kein gueltiger Ausdruck'
standard; IN_PATTERNS='NICHT_DA=^x$'
fall "Muster fuer unbekannten Namen" 'kein uebergebener Wert'
standard; V03='irgendwas'
fall "Slot belegt, aber nicht benannt" 'Slot V03 ist belegt'
standard; IN_NAMES=$'V01=GOOGLE_CLIENT_ID\nV01=ANDERER'
fall "Slot doppelt benannt" 'Slot V01 doppelt'
standard; IN_NAMES=$'V01=GOOGLE_CLIENT_ID\nV02=GOOGLE_CLIENT_ID'
fall "Name doppelt" 'Name GOOGLE_CLIENT_ID doppelt'
standard; IN_NAMES=$'V11=X'
fall "Slot ausserhalb V01..V10" 'nicht der Form V01=NAME'
standard; IN_NAMES=$'V01=1BAD'
fall "Ungueltiger Schluesselname" 'nicht der Form V01=NAME'
standard; IN_RANDOM='GOOGLE_CLIENT_ID'
fall "Zufallsname kollidiert mit Wert" 'kommt schon anderswo vor'
standard; IN_PLAIN='GOOGLE_CLIENT_ID=x'
fall "Klartextname kollidiert mit Secret" 'kommt schon anderswo vor'
standard; IN_ENVFILE='../etc/passwd'
fall "Pfad relativ" 'env-file muss ein absoluter Pfad'
standard; IN_ENVFILE="$SRV/../x"
fall "Pfad mit .." 'darf kein'
standard; IN_ENVFILE="/tmp/mit leerzeichen"
fall "Pfad mit Leerzeichen" 'env-file muss ein absoluter Pfad'
standard; IN_HOST='a;b'
fall "Host mit Sonderzeichen" 'host ist kein Servername'
standard; IN_USER='Root;x'
fall "Nutzer mit Sonderzeichen" 'user ist kein gueltiger'
standard; IN_PORT='22;x'
fall "Port keine Zahl" 'port ist keine Zahl'
standard; IN_DRY=vielleicht
fall "dry-run weder true noch false" 'dry-run muss true oder false'
standard; IN_NAMES=''; IN_PLAIN=''; V01=''; V02=''
fall "Weder secret-names noch plain-values" 'Mindestens ein Wert noetig'

echo "== 7. Dry-Run: prueft und meldet, fasst nichts an =="
standard; IN_DRY=true; V02='GOCSPX-nurProbe_77777'; IN_RANDOM='SESSION_JWT_SECRET NEU_ZUFALL'
S_VOR=$(summe "$ENVF"); BAK_VOR=$(summe "$ENVF.bak-vor-secrets")
lauf "$T/l7.log"; RC=$?
[ $RC -eq 0 ] && gut "Exitcode 0" || schlecht "Exitcode 0 (war $RC)" "$(cat "$T/l7.log")"
pruefe "Log: wuerde setzen" grep -qx 'OK  GOOGLE_CLIENT_SECRET: wuerde gesetzt' "$T/l7.log"
pruefe "Log: DRY-RUN-Meldung" grep -q 'DRY-RUN: Pruefung bestanden' "$T/l7.log"
pruefe ".env bytegleich" test "$(summe "$ENVF")" = "$S_VOR"
pruefe "Sicherung nicht neu geschrieben" test "$(summe "$ENVF.bak-vor-secrets")" = "$BAK_VOR"
pruefe "Keine Reste im Zielordner" test "$(ls -A "$SRV" | sort | tr '\n' ' ')" = "app.env app.env.bak-vor-secrets "
pruefe "Kein Wert im Log" kein_wert_im "$T/l7.log"

echo "== 8. Sonderfaelle der .env =="
standard
frische_env
printf 'GOOGLE_CLIENT_ID="alt-quoted"\nGOOGLE_CLIENT_ID=alt-doppelt\nSESSION_JWT_SECRET="bestehend-mit-quotes"\n' >> "$ENVF"
cp "$ENVF" "$T/vor8.env"
lauf "$T/l8.log"; RC=$?
[ $RC -eq 0 ] && gut "Exitcode 0" || schlecht "Exitcode 0 (war $RC)" "$(cat "$T/l8.log")"
pruefe "Doppelte Zeilen eines verwalteten Schluessels: danach genau eine" test "$(grep -c '^GOOGLE_CLIENT_ID=' "$ENVF")" = 1 -a "$(wert_von GOOGLE_CLIENT_ID)" = "$M1"
pruefe "Bestehender Zufallswert (mit Anfuehrungszeichen) unveraendert, Zeile bytegleich" grep -qx 'SESSION_JWT_SECRET="bestehend-mit-quotes"' "$ENVF"
pruefe "Log: bestehender Zufallswert unveraendert, fehlender gesetzt" bash -c "grep -qx 'OK  SESSION_JWT_SECRET: unveraendert' '$T/l8.log' && grep -qx 'OK  AUTH_STATE_SECRET: gesetzt' '$T/l8.log'"
pruefe "Uebrige Zeilen bytegleich" cmp -s <(ohne_verwaltete "$T/vor8.env") <(ohne_verwaltete "$ENVF")

# Wert unveraendert, aber mit Anfuehrungszeichen in der Datei: gilt als unveraendert, Zeile bleibt
frische_env; printf 'GOOGLE_CLIENT_ID="%s"\nGOOGLE_CLIENT_SECRET=%s\nR2_BUCKET=mein-bucket-1\nSESSION_JWT_SECRET=aaaa\nAUTH_STATE_SECRET=bbbb\n' "$M1" "$M2" >> "$ENVF"
S_VOR=$(summe "$ENVF")
standard; lauf "$T/l8b.log"; RC=$?
pruefe "Wert gleich, nur mit Anfuehrungszeichen in der Datei: nichts zu aendern, bytegleich" test $RC -eq 0 -a "$(summe "$ENVF")" = "$S_VOR"

# Datei ohne abschliessenden Zeilenumbruch
rm -f "$ENVF" "$ENVF".*; printf 'A=1\nLETZTE=ohne-umbruch' > "$ENVF"; chmod 600 "$ENVF"
standard; lauf "$T/l8c.log"; RC=$?
pruefe "Datei ohne Schluss-Zeilenumbruch: Zeilen nicht verklebt" bash -c "[ $RC -eq 0 ] && grep -qx 'LETZTE=ohne-umbruch' '$ENVF' && grep -qx 'GOOGLE_CLIENT_ID=$M1' '$ENVF'"

# fehlende .env / Symlink
rm -f "$ENVF" "$ENVF".*
standard; lauf "$T/l8d.log"; RC=$?
pruefe "Fehlende .env: Abbruch, es entsteht keine" bash -c "[ $RC -ne 0 ] && [ ! -e '$ENVF' ] && grep -q 'Keine regulaere Datei' '$T/l8d.log'"
frische_env; mv "$ENVF" "$SRV/echt.env"; ln -s "$SRV/echt.env" "$ENVF"
S_VOR=$(summe "$SRV/echt.env")
standard; lauf "$T/l8e.log"; RC=$?
pruefe "Symlink als .env: Abbruch, Ziel unberuehrt" bash -c "[ $RC -ne 0 ] && grep -q 'Keine regulaere Datei' '$T/l8e.log'" 
pruefe "  ... Ziel bytegleich" test "$(summe "$SRV/echt.env")" = "$S_VOR"
rm -f "$ENVF" "$SRV/echt.env"

echo "== 8b. Nur Klartextwerte, kein Secret (Weg pruefen ohne echtes Geheimnis) =="
frische_env; S_VOR=$(summe "$ENVF")
standard; IN_NAMES=''; IN_PLAIN='DBS_PROBE=probe-1'; IN_RANDOM=''; IN_PATTERNS=''; V01=''; V02=''
lauf "$T/l8f.log"; RC=$?
pruefe "plain-values allein: Exitcode 0, Wert steht drin" bash -c "[ $RC -eq 0 ] && grep -qx 'DBS_PROBE=probe-1' '$ENVF' && grep -qx 'OK  DBS_PROBE: gesetzt' '$T/l8f.log'"
standard; IN_NAMES=''; IN_PLAIN='DBS_PROBE=probe-1'; IN_RANDOM=''; IN_PATTERNS=''; V01=''; V02=''; IN_ENVFILE="$SRV/gibt-es-nicht.env"
lauf "$T/l8g.log"; RC=$?
pruefe "Nicht vorhandene Datei + dry-run-Stufe 1: SSH/Pinning/Skript laufen, Server-Teil bricht ohne Schreiben ab" bash -c "[ $RC -ne 0 ] && grep -q 'Keine regulaere Datei' '$T/l8g.log' && [ ! -e '$SRV/gibt-es-nicht.env' ]"

echo "== 9. Port ungleich 22 und Nutzlast direkt gegen den Server-Teil =="
# Server-Teil allein, mit absichtlich kaputten Nutzlasten (Verteidigung in der Tiefe)
frische_env; S_VOR=$(summe "$ENVF")
REMOTE_SH="$T/remote.sh"
ruby -e 's=File.read(ARGV[0]); k="<<\x27REMOTE_SCRIPT\x27\n"; a=s.index(k)+k.size; b=s.index("\nREMOTE_SCRIPT\n",a); print s[a..b]' "$T/schritt-eintragen.sh" > "$REMOTE_SH"
remote() { sh "$REMOTE_SH" < "$1" 2>&1; }
nutzlast() { printf '%s\n' "$@" > "$T/nl"; }
nutzlast '#DBS1' "#ENV=$ENVF" '#DRY=0' '#KEYS=GOOGLE_CLIENT_ID' '#ZUFALL=' 'GOOGLE_CLIENT_ID=abc' 'EXTRA=eingeschleust'
OUT=$(remote "$T/nl"); RC=$?
pruefe "Nutzlast mit eingeschleustem Extra-Schluessel: Abbruch, Datei bytegleich" bash -c "echo '$OUT' | grep -q 'passt nicht zur Schluesselliste' && [ '$(summe "$ENVF")' = '$S_VOR' ]"
nutzlast '#DBS1' "#ENV=$ENVF" '#DRY=0' '#KEYS=GOOGLE_CLIENT_ID' '#ZUFALL=' 'GOOGLE_CLIENT_ID=ab cd'
OUT=$(remote "$T/nl"); pruefe "Leerzeichen in der Nutzlast: Abbruch" bash -c "echo '$OUT' | grep -q 'unzulaessige Zeile' && [ '$(summe "$ENVF")' = '$S_VOR' ]"
nutzlast '#DBS1' "#ENV=$ENVF" '#DRY=0' '#KEYS=' '#ZUFALL=' 
OUT=$(remote "$T/nl"); pruefe "Leere Schluesselliste: Abbruch" bash -c "echo '$OUT' | grep -q 'Keine Schluessel' && [ '$(summe "$ENVF")' = '$S_VOR' ]"
nutzlast '#DBS2' "#ENV=$ENVF"
OUT=$(remote "$T/nl"); pruefe "Unbekannte Nutzlast-Version: Abbruch" bash -c "echo '$OUT' | grep -q 'Nutzlast unbekannt'"
nutzlast '#DBS1' "#ENV=/etc/../etc/passwd" '#DRY=0' '#KEYS=A' '#ZUFALL=' 'A=b'
OUT=$(remote "$T/nl"); pruefe "Pfad mit .. auch serverseitig abgelehnt" bash -c "echo '$OUT' | grep -q 'Pfad der .env ungueltig'"
nutzlast '#DBS1' "#ENV=$ENVF" '#DRY=0' '#KEYS=A;id' '#ZUFALL=' 'A=b'
OUT=$(remote "$T/nl"); pruefe "Schluesselname mit Sonderzeichen serverseitig abgelehnt" bash -c "echo '$OUT' | grep -q 'Schluesselname ungueltig'"

pruefe "known_hosts-Eintrag hat fuer Port != 22 die Form [host]:port (der Test-sshd laeuft auf $PORT, jeder Lauf oben belegt es)" grep -q "printf '\\[%s\\]:%s %s" "$T/schritt-ssh.sh"

echo "== 10. Statische Pruefung: was nie im Workflow stehen darf =="
alle_schritte() { cat "$WF"; }
pruefe_nicht "kein ssh-keyscan"                        grep -q 'ssh-keyscan' <(grep -v '^[[:space:]]*#' "$WF")
pruefe_nicht "kein StrictHostKeyChecking no/accept-new" grep -Eq 'StrictHostKeyChecking (no|accept-new|off)' "$WF"
pruefe "StrictHostKeyChecking yes"                     grep -q 'StrictHostKeyChecking yes' "$WF"
pruefe "System-known_hosts abgeschaltet"               grep -q 'GlobalKnownHostsFile /dev/null' "$WF"
pruefe_nicht "nichts nach GITHUB_ENV/GITHUB_OUTPUT"    grep -Eq '>>[[:space:]]*"?\$?\{?GITHUB_(ENV|OUTPUT)' "$WF"
pruefe_nicht "kein set -x / bash -x"                   grep -Eq '(^|[^+])set -[a-z]*x|bash -[a-z]*x' <(grep -v '^[[:space:]]*#' "$WF")
pruefe "set +x in jedem run-Schritt"                   bash -c "[ \$(grep -c 'set +x' '$WF') -ge 3 ]"
pruefe "permissions: {} auf Workflow-Ebene"            grep -q '^permissions: {}' "$WF"
pruefe_nicht "keine fremden Actions (uses:)"           grep -Eq '^[[:space:]]*-?[[:space:]]*uses:' "$WF"
pruefe_nicht "kein secrets: inherit"                   grep -Eq 'secrets:[[:space:]]*inherit' <(grep -v '^[[:space:]]*#' "$WF")
pruefe_nicht "nur workflow_call als Ausloeser"         ruby -ryaml -e 'y=YAML.load_file(ARGV[0]); exit((y[true]||y["on"]).keys == ["workflow_call"] ? 1 : 0)' "$WF"
pruefe_nicht "kein echo/printf eines Werts (V01..V10, SSH_KEY, WERT__) ins Log" grep -Eq '(echo|printf)[^|>]*\$\{?(V(0[1-9]|10)|SSH_KEY|!slot|WERT__)' <(grep -v '^[[:space:]]*#' "$WF" | grep -v -e '>[[:space:]]*"\$D/key"' -e '"\$PAYLOAD"')
pruefe "Ein Argumentvektor ohne Werte: ssh-Aufruf enthaelt nur B64 des Skripts" bash -c "grep -E '^[[:space:]]*ssh -F' '$WF' | grep -vq -e '\$V0' -e 'SSH_KEY' -e 'PAYLOAD\"\$' -e 'WERT'"

echo
echo "==> $PASS bestanden, $FAIL fehlgeschlagen"
[ "$FAIL" -eq 0 ]
