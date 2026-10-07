#!/usr/bin/env bash
#
# OpenCut Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:     OpenCut Classic – Open-Source CapCut-Alternative (Next.js, Port 3100)
# Upstream: https://github.com/OpenCut-app/opencut-classic
# Stack:   Next.js (Docker-Compose Build) + PostgreSQL 17 + Redis 7 + serverless-redis-http
# Läuft:   vollständig lokal im LXC, keine Cloud nötig
# Host:    DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenCutProxmox/main/install/opencut.sh)"
#   CT_ID=101 CORES=2 RAM=4096 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenCutProxmox/main/install/opencut.sh)"
#   bash opencut.sh --ctid 101 --cores 2 --memory 4096 --disk 20 --bridge vmbr0 --debug
#
# Hinweis: web-Dienst braucht `docker compose build` (kein reiner Pull).
# Erster Start zieht ~2-3 GB + Build-Zeit einplanen (Poll bis 300 s).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="opencut"                                   # Container-Hostname + Service-Name
PORT="3100"                                     # OpenCut Classic Web UI (Compose: 3100:3000)
UPSTREAM_REPO="https://github.com/OpenCut-app/opencut-classic.git"
UPSTREAM_DIR="/opt/opencut/opencut-classic"     # Clone-Ziel im LXC
INSTALLER_REPO="https://raw.githubusercontent.com/HatchetMan111/OpenCutProxmox/main/install/opencut.sh"

DEFAULT_CORES="4"                               # vCPU (Build braucht 4, sonst Type-Check-Thrash)
DEFAULT_RAM="8192"                              # RAM in MB (Build braucht 8 GB, mit 4 GB Swap-Thrash)
DEFAULT_SWAP="2048"                             # Swap (MB)
DEFAULT_DISK="20"                               # Disk in GB (Images + Build + DB, min. 12)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                  # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"                 # Template-Familie (Docker-getestet)
UNPRIVILEGED="1"
FEATURES="nesting=1,keyctl=1"                   # nesting/keyctl = Docker im LXC nötig

# Umgebungs-Overrides erlauben: CT_ID=101 CORES=4 RAM=8192 DISK=20 ./opencut.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe zusätzlich ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash opencut.sh [OPTIONEN]
  CT_ID=101 bash opencut.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO})"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM}, Minimum 4096 empfohlen)
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --debug, -x          set -x + maximale Fehlermeldungskette
  --help, -h           diese Hilfe

Nach der Installation:
  Web UI: http://<LXC-IP>:${PORT}
  Health: http://<LXC-IP>:${PORT}/api/health
EOF
}

# ---------------------------------------------------------------------------
# Debugging: komplette Fehlermeldungskette (Stacktrace, stderr/stdout, Exit-Code, Logs)
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +x
  if ((${#cmd} > 2000)); then
    cmd="${cmd:0:2000}… [gekürzt, vollständiger Befehl in $LOG_FILE]"
  fi
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $SCRIPT_ARGS"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Stacktrace (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]]; then
    msg_error "--- pct config ${CTID} ---"
    pct config "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- pct status ${CTID} ---"
    pct status "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- systemctl status im Container (opencut) ---"
    pct exec "${CTID}" -- systemctl status "${APP}" --no-pager --full 2>&1 || true
    echo ""
    msg_error "--- journalctl im Container (opencut, letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- journalctl -u "${APP}" --no-pager -n 100 2>&1 || true
    echo ""
    msg_error "--- docker ps im Container ---"
    pct exec "${CTID}" -- docker ps -a 2>&1 || true
    echo ""
    msg_error "--- docker compose logs (letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- docker compose -f /opt/opencut/opencut-classic/docker-compose.yml logs --tail=100 --no-color 2>&1 || true
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  msg_error "  bash -x opencut.sh $SCRIPT_ARGS"
  msg_error "  oder: DEBUG=1 bash opencut.sh $SCRIPT_ARGS"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CT_ID_ARG"
HOSTNAME_ARG="$APP"
CORES="$CORES_ARG"
RAM="$RAM_ARG"
DISK="$DISK_ARG"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
ROOT_PASSWORD=""
SSH_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)            CTID="${2:?--ctid braucht einen Wert}"; shift 2 ;;
    --hostname)        HOSTNAME_ARG="${2:?--hostname braucht einen Wert}"; shift 2 ;;
    --cores)           CORES="${2:?}"; shift 2 ;;
    --memory)          RAM="${2:?}"; shift 2 ;;
    --disk)            DISK="${2:?}"; shift 2 ;;
    --storage)         STORAGE_ARG="${2:?}"; shift 2 ;;
    --template-store)  TEMPLATE_STORE="${2:?}"; shift 2 ;;
    --bridge)          BRIDGE="${2:?}"; shift 2 ;;
    --password)        ROOT_PASSWORD="${2:?}"; shift 2 ;;
    --ssh-key)         SSH_KEY="${2:?}"; shift 2 ;;
    --debug|-x)        DEBUG="1"; set -x; shift ;;
    --help|-h)         usage; exit 0 ;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1 ;;
  esac
done

# Trap NACH dem Parsen setzen, damit SCRIPT_ARGS die echten Args enthält
# shellcheck disable=SC2064
trap "on_error \$? \$LINENO \"\$BASH_COMMAND\"" ERR

# ---------------------------------------------------------------------------
# Pre-Checks (muss auf dem Proxmox-Host als root laufen)
# ---------------------------------------------------------------------------
msg_info "Prüfe Voraussetzungen (Proxmox-Host, root, Tools) ..."
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  msg_error "Bitte als root auf dem Proxmox-Host ausführen (sudo -i)."
  exit 1
fi
for bin in pct pveam pvesh pvesm wget curl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    msg_error "Benötigtes Tool fehlt: $bin – läuft das Skript wirklich auf einem Proxmox-VE-Host?"
    exit 1
  fi
done
if [[ "$RAM" -lt 4096 ]]; then
  msg_warn "RAM=${RAM} MB < 4096 MB – OpenCut Classic (web+db+redis+srh) braucht min. 4 GB, sonst OOM."
fi
if [[ "$DISK" -lt 12 ]]; then
  msg_warn "DISK=${DISK} GB < 12 GB – Docker-Images + Build + DB brauchen min. ~12 GB."
fi
msg_ok "Host-Checks bestanden."

# ---------------------------------------------------------------------------
# CT-ID: immer die nächste freie ID nehmen (außer explizit gesetzt)
# ---------------------------------------------------------------------------
if [[ -z "$CTID" ]]; then
  msg_info "Ermittle nächste freie CT-ID ..."
  CTID="$(pvesh get /cluster/nextid)"
  msg_ok "Nächste freie CT-ID: $CTID"
else
  msg_info "CT-ID vorgegeben: $CTID"
fi

HOSTNAME_FINAL="$HOSTNAME_ARG"
if [[ ! "$HOSTNAME_FINAL" =~ ^[a-zA-Z0-9-]+$ ]]; then
  msg_error "Ungültiger Hostname: $HOSTNAME_FINAL (nur Buchstaben, Zahlen, Bindestrich)"
  exit 1
fi

# ---------------------------------------------------------------------------
# Storage-Erkennung (idempotent: vorhandene Storages nutzen)
# ---------------------------------------------------------------------------
detect_storage() {
  local s
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | grep -x "local-lvm" || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  s="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && /active/ {print $1}' | head -n1 || true)"
  if [[ -n "$s" ]]; then echo "$s"; return 0; fi
  echo "local-lvm"
}
if [[ -z "$STORAGE_ARG" ]]; then
  STORAGE_ARG="$(detect_storage)"
  msg_info "RootFS-Storage (auto): $STORAGE_ARG"
else
  msg_info "RootFS-Storage (vorgegeben): $STORAGE_ARG"
fi

# ---------------------------------------------------------------------------
# Template sicherstellen
# ---------------------------------------------------------------------------
msg_info "Aktualisiere Template-Liste (pveam update) ..."
pveam update

msg_info "Suche neuestes ${DEFAULT_OS}-Template auf ${TEMPLATE_STORE} ..."
TEMPLATE_FILE="$(pveam available --section system 2>/dev/null \
  | grep -o "${DEFAULT_OS}[^ ]*\\.tar\\.zst" | sort -V | tail -n1 || true)"
if [[ -z "$TEMPLATE_FILE" ]]; then
  msg_error "Kein Template für ${DEFAULT_OS} gefunden. Verfügbare Debian-Templates:"
  pveam available --section system 2>&1 | grep -i debian || true
  exit 1
fi
TEMPLATE_REF="${TEMPLATE_STORE}:vztmpl/${TEMPLATE_FILE}"
msg_info "Template: $TEMPLATE_REF"
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE_FILE"; then
  msg_info "Lade Template herunter (kann dauern) ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE_FILE"
else
  msg_ok "Template bereits vorhanden – Download übersprungen (idempotent)."
fi

# ---------------------------------------------------------------------------
# Container erstellen (idempotent: existiert die CT-ID schon, wiederverwenden)
# ---------------------------------------------------------------------------
CREATED_NOW=0
GENERATED_PW=0
if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "Container $CTID existiert bereits – wird wiederverwendet (idempotent, kein Neu-Erstellen)."
  EXISTING_HOST="$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}' || true)"
  msg_info "Bestehender Hostname: ${EXISTING_HOST:-unbekannt}"
else
  if [[ -z "$ROOT_PASSWORD" ]]; then
    ROOT_PASSWORD="$(openssl rand -hex 8)"
    GENERATED_PW=1
  fi
  msg_info "Erstelle LXC $CTID (hostname=${HOSTNAME_FINAL}, cores=${CORES}, ram=${RAM}MB, disk=${DISK}G) ..."
  CREATE_ARGS=(
    "$CTID" "$TEMPLATE_REF"
    --hostname "$HOSTNAME_FINAL"
    --cores "$CORES"
    --memory "$RAM"
    --swap "$DEFAULT_SWAP"
    --rootfs "${STORAGE_ARG}:${DISK}"
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp"
    --ostype debian
    --unprivileged "$UNPRIVILEGED"
    --features "$FEATURES"
    --onboot 1
    --start 0
    --password "$ROOT_PASSWORD"
  )
  if [[ -n "$SSH_KEY" ]]; then
    if [[ ! -f "$SSH_KEY" ]]; then msg_error "SSH-Key nicht gefunden: $SSH_KEY"; exit 1; fi
    CREATE_ARGS+=(--ssh-public-keys "$SSH_KEY")
  fi
  pct create "${CREATE_ARGS[@]}"
  # onboot + nesting explizit sicherstellen (Reboot-sicher, Docker-fähig)
  pct set "$CTID" --onboot 1 --features "$FEATURES"
  CREATED_NOW=1
  msg_ok "Container $CTID erstellt (Name: $HOSTNAME_FINAL, onboot=1, features=$FEATURES)."
fi

msg_info "Starte Container $CTID ..."
if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
  pct start "$CTID"
fi
for i in $(seq 1 30); do
  if pct exec "$CTID" -- true >/dev/null 2>&1; then break; fi
  sleep 2
  if [[ "$i" -eq 30 ]]; then msg_error "Container $CTID reagiert nicht auf 'pct exec'."; exit 1; fi
done
msg_ok "Container $CTID läuft."

sleep 5

# ---------------------------------------------------------------------------
# Installation IM Container (idempotentes Setup-Skript via pct push + exec)
# ---------------------------------------------------------------------------
msg_info "Installiere ${APP} im Container (Docker + Compose: web/db/redis/srh) ..."

# systemd-Unit-Vorlage (identisch zu systemd/opencut.service im Repo)
read -r -d '' UNIT_FILE <<'UNIT_EOF' || true
[Unit]
Description=OpenCut Classic – Open-Source Video-Editor (Docker Compose: web + db + redis + serverless-redis-http)
Documentation=https://github.com/OpenCut-app/opencut-classic
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/opencut/opencut-classic
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_EOF

# Setup-Skript lokal bauen (Host-Variablen werden HIER expandiert,
# Container-Variablen sind mit \$ escaped und werden ERST im LXC expandiert).
TMP_SETUP="$(mktemp /tmp/opencut-setup.XXXXXX.sh)"
cat > "$TMP_SETUP" <<SETUP_EOF
#!/usr/bin/env bash
set -euo pipefail
APP="${APP}"
PORT="${PORT}"
UPSTREAM_REPO="${UPSTREAM_REPO}"
UPSTREAM_DIR="${UPSTREAM_DIR}"

echo "[LXC] apt update + Basis-Pakete ..."
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates openssl git iproute2 procps

echo "[LXC] Docker sicherstellen (idempotent) ..."
DOCKER_OK=0
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "[LXC] Docker + Compose bereits vorhanden: \$(docker --version) / \$(docker compose version --short)"
  DOCKER_OK=1
fi
if [[ "\$DOCKER_OK" != "1" ]]; then
  echo "[LXC] Installiere Docker aus dem offiziellen Docker-Repo ..."
  apt-get install -y --no-install-recommends gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 3 --max-time 60 https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  DARCH="\$(dpkg --print-architecture)"
  DCODENAME="\$(. /etc/os-release && echo "\$VERSION_CODENAME")"
  echo "deb [arch=\$DARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$DCODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  if apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin; then
    echo "[LXC] Docker aus offiziellem Repo installiert."
  else
    echo "[LXC][WARN] Offizielles Docker-Repo fehlgeschlagen – Fallback: docker.io + Compose-Plugin-Binary von GitHub."
    rm -f /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y --no-install-recommends docker.io
    CMACHINE="\$(uname -m)"
    case "\$CMACHINE" in
      x86_64) CMARCH="x86_64" ;;
      aarch64|arm64) CMARCH="aarch64" ;;
      *) echo "[LXC][ERROR] Nicht unterstützte Architektur für Compose-Fallback: \$CMACHINE" >&2; exit 1 ;;
    esac
    mkdir -p /usr/libexec/docker/cli-plugins
    curl -fSL --retry 3 --max-time 180 -o /usr/libexec/docker/cli-plugins/docker-compose "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-\$CMARCH"
    chmod +x /usr/libexec/docker/cli-plugins/docker-compose
  fi
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
fi
docker --version
docker compose version
if ! docker buildx version >/dev/null 2>&1; then
  echo "[LXC] buildx-Plugin fehlt (klassischer Builder aktiv) – installiere nach ..."
  apt-get install -y --no-install-recommends docker-buildx-plugin || echo "[LXC][WARN] buildx-Install fehlgeschlagen – weiter mit klassischem Builder."
  docker buildx version >/dev/null 2>&1 || true
fi

echo "[LXC] Container-IP ermitteln (fuer NEXT_PUBLIC_SITE_URL) ..."
LXC_IP="\$(ip -4 -o addr show eth0 2>/dev/null | awk '\$4 !~ /^127\\./ {print \$4}' | cut -d/ -f1 | head -n1 || true)"
if [[ -z "\$LXC_IP" ]]; then LXC_IP="127.0.0.1"; fi
echo "[LXC] IP: \$LXC_IP"

echo "[LXC] OpenCut Classic klonen/updaten (idempotent) ..."
mkdir -p /opt/opencut
if [[ -d "\$UPSTREAM_DIR/.git" ]]; then
  git -C "\$UPSTREAM_DIR" pull --ff-only || echo "[LXC][WARN] git pull fehlgeschlagen – weiter mit vorhandenem Stand."
else
  rm -rf "\$UPSTREAM_DIR"
  git clone --depth 1 "\$UPSTREAM_REPO" "\$UPSTREAM_DIR"
fi

echo "[LXC] Upstream-Fix pruefen (archiviertes Repo: isShortcutKey-Guard fehlt an HEAD) ..."
KEYBINDING_FILE="\$UPSTREAM_DIR/apps/web/src/actions/keybinding.ts"
if [[ -f "\$KEYBINDING_FILE" ]]; then
  if grep -q "export function isShortcutKey" "\$KEYBINDING_FILE"; then
    echo "[LXC] isShortcutKey bereits vorhanden – Patch uebersprungen (idempotent)."
  else
    echo "[LXC] Patche fehlenden isShortcutKey-Guard in keybinding.ts ..."
    cat >> "\$KEYBINDING_FILE" <<'PATCH_EOF'

const MODIFIER_KEYS: ReadonlySet<string> = new Set([
	"ctrl",
	"alt",
	"shift",
	"ctrl+shift",
	"alt+shift",
	"ctrl+alt",
	"ctrl+alt+shift",
]);

export function isShortcutKey(value: string): value is ShortcutKey {
	if (isKey(value)) return true;
	const separatorIndex = value.lastIndexOf("+");
	if (separatorIndex <= 0) return false;
	const modifier = value.slice(0, separatorIndex);
	const key = value.slice(separatorIndex + 1);
	return MODIFIER_KEYS.has(modifier) && isKey(key);
}
PATCH_EOF
  fi
else
  echo "[LXC][WARN] \$KEYBINDING_FILE nicht gefunden – Patch uebersprungen."
fi

echo "[LXC] Upstream-Fix 2 pruefen (archiviertes Repo: isActionWithOptionalArgs-Guard fehlt an HEAD) ..."
ACTIONS_DEFS="\$UPSTREAM_DIR/apps/web/src/actions/definitions.ts"
if [[ -f "\$ACTIONS_DEFS" ]]; then
  if grep -q "export function isActionWithOptionalArgs" "\$ACTIONS_DEFS"; then
    echo "[LXC] isActionWithOptionalArgs bereits vorhanden – Patch uebersprungen (idempotent)."
  else
    echo "[LXC] Patche fehlenden isActionWithOptionalArgs-Guard in definitions.ts ..."
    cat >> "\$ACTIONS_DEFS" <<'PATCH_EOF'

const ACTIONS_WITH_REQUIRED_ARGS: ReadonlySet<string> = new Set([
	"remove-media-asset",
	"remove-media-assets",
]);

export function isActionWithOptionalArgs(
	value: string,
): value is TActionWithOptionalArgs {
	return (
		Object.prototype.hasOwnProperty.call(ACTIONS, value) &&
		!ACTIONS_WITH_REQUIRED_ARGS.has(value)
	);
}
PATCH_EOF
  fi
else
  echo "[LXC][WARN] \$ACTIONS_DEFS nicht gefunden – Patch uebersprungen."
fi

echo "[LXC] Upstream-Fix 3 pruefen (archiviertes Repo: IndexedDBAdapter positional statt Object-Params) ..."
RUNNER_PATH="\$UPSTREAM_DIR/apps/web/src/services/storage/migrations/runner.ts"
V1V2_PATH="\$UPSTREAM_DIR/apps/web/src/services/storage/migrations/v1-to-v2.ts"
python3 - "\$RUNNER_PATH" "\$V1V2_PATH" <<'PYEOF'
import sys

RUNNER, V1V2 = sys.argv[1], sys.argv[2]

def patch(path, marker, replacements):
    try:
        with open(path) as f:
            src = f.read()
    except FileNotFoundError:
        print(f"[LXC][WARN] {path} nicht gefunden – Patch uebersprungen.")
        return
    if marker in src:
        print(f"[LXC] {path} bereits gepatcht – uebersprungen (idempotent).")
        return
    for old, new in replacements:
        count = src.count(old)
        if count != 1:
            print(f"[LXC][ERROR] Erwartet 1 Treffer, gefunden {count} in {path} fuer: {old[:60]!r}")
            sys.exit(1)
        src = src.replace(old, new)
    with open(path, "w") as f:
        f.write(src)
    print(f"[LXC] {path} gepatcht ({len(replacements)} Ersetzungen).")

T = "\t"
BT = chr(96)  # Backtick ohne Backtick im Source (Bash-Heredoc wuerde sonst substituieren)
DOL = chr(36)  # "$" ohne Dollarzeichen im Source (Bash-Heredoc- + Python-Escape-sicher)
patch(RUNNER, 'dbName: "video-editor-projects"', [
    (
        'new IndexedDBAdapter<ProjectRecord>(\n' + T*2 + '"video-editor-projects",\n' + T*2 + '"projects",\n' + T*2 + '1,\n' + T + ')',
        'new IndexedDBAdapter<ProjectRecord>({\n' + T*2 + 'dbName: "video-editor-projects",\n' + T*2 + 'storeName: "projects",\n' + T*2 + 'version: 1,\n' + T + '})',
    ),
    (
        'projectsAdapter.set(projectId, result.project)',
        'projectsAdapter.set({\n' + T*3 + 'key: projectId,\n' + T*3 + 'value: result.project,\n' + T*2 + '})',
    ),
])
patch(V1V2, 'dbName: sceneDbName', [
    (
        'new IndexedDBAdapter<LegacyTimelineData>(\n' + T*2 + 'sceneDbName,\n' + T*2 + '"timeline",\n' + T*2 + '1,\n' + T + ')',
        'new IndexedDBAdapter<LegacyTimelineData>({\n' + T*2 + 'dbName: sceneDbName,\n' + T*2 + 'storeName: "timeline",\n' + T*2 + 'version: 1,\n' + T + '})',
    ),
    (
        'new IndexedDBAdapter<LegacyTimelineData>(\n' + T*3 + 'projectDbName,\n' + T*3 + '"timeline",\n' + T*3 + '1,\n' + T*2 + ')',
        'new IndexedDBAdapter<LegacyTimelineData>({\n' + T*3 + 'dbName: projectDbName,\n' + T*3 + 'storeName: "timeline",\n' + T*3 + 'version: 1,\n' + T*2 + '})',
    ),
    (
        'new IndexedDBAdapter<MediaAssetData>(\n' + T*2 + BT + 'video-editor-media-' + DOL + '{projectId}' + BT + ',\n' + T*2 + '"media-metadata",\n' + T*2 + '1,\n' + T + ')',
        'new IndexedDBAdapter<MediaAssetData>({\n' + T*2 + 'dbName: ' + BT + 'video-editor-media-' + DOL + '{projectId}' + BT + ',\n' + T*2 + 'storeName: "media-metadata",\n' + T*2 + 'version: 1,\n' + T + '})',
    ),
])
PYEOF

echo "[LXC] Upstream-Fix 4 pruefen (archiviertes Repo: stickers register positional statt Object-Param) ..."
STICKERS_PATH="\$UPSTREAM_DIR/apps/web/src/stickers/providers/index.ts"
python3 - "\$STICKERS_PATH" <<'PYEOF'
import sys

TARGET = sys.argv[1]
T = "\t"
try:
    with open(TARGET) as f:
        src = f.read()
except FileNotFoundError:
    print(f"[LXC][WARN] {TARGET} nicht gefunden – Patch uebersprungen.")
    sys.exit(0)
if "key: provider.id" in src:
    print(f"[LXC] {TARGET} bereits gepatcht – uebersprungen (idempotent).")
    sys.exit(0)
old = "stickersRegistry.register(provider.id, provider);"
if src.count(old) != 1:
    print(f"[LXC][ERROR] Erwartet 1 Treffer, gefunden {src.count(old)} in {TARGET}.")
    sys.exit(1)
new = "stickersRegistry.register({\n" + T*3 + "key: provider.id,\n" + T*3 + "definition: provider,\n" + T*2 + "});"
src = src.replace(old, new)
with open(TARGET, "w") as f:
    f.write(src)
print(f"[LXC] {TARGET} gepatcht (1 Ersetzung).")
PYEOF

echo "[LXC] .env schreiben (Secrets behalten, SITE_URL auf aktuelle IP) ..."
ENV_PATH="\$UPSTREAM_DIR/.env"
touch "\$ENV_PATH"
get_env() { grep -E "^\$1=" "\$ENV_PATH" 2>/dev/null | cut -d= -f2- || true; }
DB_PASS="\$(get_env POSTGRES_PASSWORD)"
if [[ -z "\$DB_PASS" ]]; then DB_PASS="\$(openssl rand -hex 16)"; echo "[LXC] Neues DB-Passwort erzeugt."; fi
AUTH_SECRET="\$(get_env BETTER_AUTH_SECRET)"
if [[ -z "\$AUTH_SECRET" || "\$AUTH_SECRET" == "your-production-secret-key-here" || "\$AUTH_SECRET" == "your_better_auth_secret" ]]; then AUTH_SECRET="\$(openssl rand -hex 32)"; echo "[LXC] Neues BETTER_AUTH_SECRET erzeugt."; fi
SRH_TOKEN="\$(get_env SRH_TOKEN)"
if [[ -z "\$SRH_TOKEN" ]]; then SRH_TOKEN="\$(openssl rand -hex 16)"; echo "[LXC] Neues SRH_TOKEN erzeugt."; fi
cat > "\$ENV_PATH" <<ENVEOF
# OpenCut Classic – vom Proxmox-Installer verwaltet (idempotent: Secrets bleiben, SITE_URL wird je Lauf aktualisiert)
POSTGRES_USER=opencut
POSTGRES_PASSWORD=\$DB_PASS
POSTGRES_DB=opencut
DATABASE_URL=postgresql://opencut:\$DB_PASS@db:5432/opencut
BETTER_AUTH_SECRET=\$AUTH_SECRET
SRH_TOKEN=\$SRH_TOKEN
SRH_MODE=env
SRH_CONNECTION_STRING=redis://redis:6379
UPSTASH_REDIS_REST_URL=http://serverless-redis-http:80
UPSTASH_REDIS_REST_TOKEN=\$SRH_TOKEN
NEXT_PUBLIC_SITE_URL=http://\$LXC_IP:${PORT}
NEXT_PUBLIC_MARBLE_API_URL=https://api.marblecms.com
MARBLE_WORKSPACE_KEY=placeholder
NODE_ENV=production
ENVEOF
chmod 600 "\$ENV_PATH"

echo "[LXC] systemd-Unit schreiben ..."
cat > /etc/systemd/system/${APP}.service <<'UNITEOF_PLACEHOLDER'
__UNIT_FILE__
UNITEOF_PLACEHOLDER
systemctl daemon-reload
systemctl enable ${APP}
systemctl stop ${APP} || true

echo "[LXC] Compose-Build + Start (kann beim ersten Mal mehrere Minuten dauern) ..."
cd "\$UPSTREAM_DIR"
echo "[LXC] Service stoppen (verhindert Compose-Race zwischen Service und Setup) ..."
systemctl stop ${APP} || true
docker compose build || { echo "[LXC][ERROR] docker compose build fehlgeschlagen." >&2; exit 1; }
echo "[LXC] Alte/orphan Container aus frueheren Laeufen aufraeumen ..."
docker compose down --remove-orphans || true
echo "[LXC] Stack ueber systemd-Service starten (Service besitzt 'docker compose up') ..."
systemctl restart ${APP} || systemctl start ${APP}
systemctl is-active ${APP} || { echo "[LXC][ERROR] Service ${APP} nicht active." >&2; systemctl status ${APP} --no-pager --full || true; exit 1; }
echo "[LXC] Setup fertig: systemctl is-active ${APP} = \$(systemctl is-active ${APP})"
SETUP_EOF

# Unit-Text in Setup einsetzen (Platzhalter ersetzen, ohne Secrets zu loggen)
UNIT_TMP="$(mktemp /tmp/opencut-unit.XXXXXX)"
printf '%s\n' "$UNIT_FILE" > "$UNIT_TMP"
python3 - "$TMP_SETUP" "$UNIT_TMP" <<'PYEOF'
import sys
setup_path, unit_path = sys.argv[1], sys.argv[2]
with open(unit_path) as f:
    unit = f.read()
with open(setup_path) as f:
    setup = f.read()
setup = setup.replace("__UNIT_FILE__", unit)
with open(setup_path, "w") as f:
    f.write(setup)
PYEOF
rm -f "$UNIT_TMP"

msg_info "Kopiere Setup-Skript in Container und führe aus ..."
pct push "$CTID" "$TMP_SETUP" /tmp/opencut-setup.sh
pct exec "$CTID" -- bash /tmp/opencut-setup.sh
rm -f "$TMP_SETUP"
msg_ok "App im Container installiert, Service läuft."

# ---------------------------------------------------------------------------
# Verifikation: Service + Web UI (HTTP-Check auf localhost:PORT/api/health)
# ---------------------------------------------------------------------------
msg_info "Verifiziere Service + Web UI (bis zu 300 s, Build braucht beim ersten Mal) ..."
pct exec "$CTID" -- systemctl is-active "$APP" | grep -q "^active$" \
  || { msg_error "Service $APP ist nicht active."; exit 1; }
msg_ok "Service läuft (systemctl is-active $APP = active)."

HEALTH_OK=0
for i in $(seq 1 60); do
  if pct exec "$CTID" -- curl -fs "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    HEALTH_OK=1
    break
  fi
  sleep 5
done
if [[ "$HEALTH_OK" != "1" ]]; then
  msg_error "Web UI antwortet nicht (60x5s Poll auf localhost:${PORT}/api/health fehlgeschlagen)."
  exit 1
fi
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${PORT}/api/health)."

# Container-IP für finale URL
LXC_IP="$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
if [[ -z "$LXC_IP" ]]; then LXC_IP="<LXC-IP>"; fi

# onboot-Check
if pct config "$CTID" 2>/dev/null | grep -q "onboot: 1"; then
  msg_ok "Container startet automatisch (onboot: 1)."
else
  msg_warn "onboot nicht gesetzt – setze nachträglich ..."
  pct set "$CTID" --onboot 1
fi

# ---------------------------------------------------------------------------
# Erfolgsausgabe
# ---------------------------------------------------------------------------
echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : OpenCut Classic – Open-Source Video-Editor"
echo "  Container    : CT $CTID (Hostname: $HOSTNAME_FINAL, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${LXC_IP}:${PORT}"
echo "  Health       : http://${LXC_IP}:${PORT}/api/health"
if [[ "$GENERATED_PW" == "1" ]]; then
  echo "  Root-Passwort: $ROOT_PASSWORD (nur jetzt angezeigt – sicher ablegen!)"
fi
echo "  Service      : systemctl status $APP  (im Container via: pct enter $CTID)"
echo "  Stack        : cd $UPSTREAM_DIR && docker compose ps / docker compose logs -f (im Container)"
echo "  Update       : Skript erneut laufen lassen (idempotent, git pull + compose build + restart)"
echo "  Deinstall    : pct stop $CTID && pct destroy $CTID"
echo "  Reboot-Test  : pct reboot $CTID && sleep 90 && curl -fs http://${LXC_IP}:${PORT}/api/health >/dev/null && echo WEB-OK"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
