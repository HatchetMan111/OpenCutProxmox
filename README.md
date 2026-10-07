# OpenCut Classic auf Proxmox LXC – Einzeiler-Installation

> **Hinweis: Das ist NICHT das OpenCut-App-Repository.**
> Dieses Repo enthält **nur den Proxmox-LXC-Installer** für OpenCut Classic — keinen App-Code.
> Die eigentliche Anwendung liegt bei Upstream:
> `https://github.com/OpenCut-app/opencut-classic`. Das Install-Script klont deren
> Compose-Stack (`postgres:17`, `redis:7-alpine`, `serverless-redis-http`, `web` Build)
> und baut/startet ihn im Container — alles läuft vollständig lokal.

OpenCut Classic (Open-Source CapCut-Alternative, Next.js) läuft in einem
unprivilegierten LXC-Container mit Docker Compose: Web UI auf Port **3100**,
systemd-Service mit `Restart=always`, Container mit `onboot=1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `opencut` |
| Zweck | Video-Editor im Browser (Timeline, Export, Projekte) |
| Tech-Stack | Next.js (Docker-Compose Build) + PostgreSQL 17 + Redis 7 |
| Upstream-Repo | `https://github.com/OpenCut-app/opencut-classic` |
| Web UI | `http://<LXC-IP>:3100`, bind `0.0.0.0` via Docker-Ports |
| Health | `http://<LXC-IP>:3100/api/health` (Upstream-Healthcheck) |
| Standard-Ressourcen | 4 vCPU / 8192 MB RAM / 20 GB Disk (Build braucht 8 GB — mit 4 GB Swap-Thrash im Type-Check) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | `nesting=1,keyctl=1` (Docker-Voraussetzung), unprivilegiert |

> **Warum Classic statt Rewrite?** Upstream `OpenCut-app/OpenCut` wird gerade
> komplett neu geschrieben (Rust-Core, `moon`/`proto`, dev Ports 5173/8787) und hat
> keinen stabilen Self-Host-Pfad. Classic ist archiviert, aber „the one to reach
> for today" — mit dokumentiertem `docker compose up -d` Prod-Weg auf Port 3100.

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

Einfach kopieren und auf dem Proxmox-Host als `root` einfügen
(Community-Scripts-Stil, keine weitere Datei nötig):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenCutProxmox/main/install/opencut.sh)"
```

> Dieses Repo: `https://github.com/HatchetMan111/OpenCutProxmox`.

Anpassungen wahlweise per Umgebungsvariable oder Flag:

```bash
CT_ID=101 CORES=4 RAM=8192 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenCutProxmox/main/install/opencut.sh)"
bash opencut.sh --ctid 101 --cores 2 --memory 4096 --disk 20 --bridge vmbr0 --storage local-lvm
bash opencut.sh --debug   # = bash -x, maximale Fehlermeldungskette
```

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `opencut` (`onboot: 1`, unprivilegiert, `nesting=1,keyctl=1`),
3. installiert im Container Docker + Compose-Plugin, klont
   `/opt/opencut/opencut-classic` (`git pull --ff-only` bei Re-Run), schreibt
   `.env` (Secrets via `openssl rand`, `NEXT_PUBLIC_SITE_URL` je Lauf auf aktuelle
   IP), schreibt die systemd-Unit, `systemctl enable --now opencut`,
   `docker compose build + up -d`,
4. verifiziert `systemctl is-active opencut` + HTTP auf `127.0.0.1:3100/api/health`
   (Poll bis 300 s, Build braucht beim ersten Mal) und gibt finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active opencut = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:3100/api/health).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : OpenCut Classic – Open-Source Video-Editor
  Container    : CT 100 (Hostname: opencut, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 20 GB Disk
  Web UI       : http://192.168.1.100:3100
  Health       : http://192.168.1.100:3100/api/health
  Root-Passwort: aB3... (nur jetzt angezeigt – sicher ablegen!)
  Service      : systemctl status opencut  (im Container via: pct enter 100)
  Stack        : cd /opt/opencut/opencut-classic && docker compose ps / docker compose logs -f (im Container)
  Update       : Skript erneut laufen lassen (idempotent, git pull + compose build + restart)
  Deinstall    : pct stop 100 && pct destroy 100
  Reboot-Test  : pct reboot 100 && sleep 90 && curl -fs http://192.168.1.100:3100/api/health >/dev/null && echo WEB-OK
  Log          : /tmp/opencut-install-2026-....log
══════════════════════════════════════════════════════════
```

## 2. Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 90   # Erster Start nach Reboot: Docker + 4 Dienste brauchen ~60–90 s
pct exec $CT -- systemctl is-active opencut   # muss: active
pct exec $CT -- docker ps --format '{{.Names}} {{.Status}}'
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):3100/api/health >/dev/null && echo WEB-OK
pct config $CT | grep -i onboot              # muss: onboot: 1
```

## 3. Update (idempotent – einfach erneut laufen lassen)

```bash
bash opencut.sh --ctid 100
# git pull --ff-only + .env-Refresh (Secrets bleiben, SITE_URL neu),
# docker compose build + up -d, danach systemctl restart opencut
```

Manuell im Container:

```bash
pct enter 100
cd /opt/opencut/opencut-classic && docker compose pull && docker compose build && docker compose up -d
systemctl restart opencut && systemctl status opencut --no-pager --full
curl -fs http://127.0.0.1:3100/api/health >/dev/null && echo WEB-OK
```

## 4. Deinstallation

```bash
pct stop 100 && pct destroy 100
```

## 5. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/opencut-install-<Datum>.log`.
- Bei Fehlern druckt das Skript: Befehl, Zeile, Exit-Code, Stacktrace
  (`caller`), `pct config`/`pct status`, `journalctl -u opencut -n 100`,
  `systemctl status opencut`, `docker ps -a`, `docker compose logs --tail=100` —
  niemals nur die letzte Zeile.
- Re-run mit Trace:

```bash
bash -x opencut.sh --ctid 100
DEBUG=1 bash opencut.sh --ctid 100
# Log mitschicken:
tail -n 200 /tmp/opencut-install-*.log
pct exec 100 -- journalctl -u opencut --no-pager -n 100
pct exec 100 -- docker compose -f /opt/opencut/opencut-classic/docker-compose.yml logs --tail=100 --no-color
```

## 6. Dateien in diesem Paket

```text
opencut-proxmox/                 # dieses Repo: NUR Proxmox-Installer, kein App-Code
├── install/opencut.sh           # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── systemd/opencut.service      # systemd-Unit (Restart=always, After=network-online.target + docker.service)
└── README.md                    # diese Datei
```

`install/opencut.sh` bettet die Unit-Vorlage aus `systemd/opencut.service` ein,
damit der Einzeiler ohne weitere Dateien auskommt. Nach dem Clone patcht das Skript
idempotent den fehlenden `isShortcutKey`-Guard in Upstream-`keybinding.ts`
(archiviertes Repo, HEAD ohne Patch nicht baubar) und baut den Compose-Stack
(`postgres:17`, `redis:7-alpine`, `serverless-redis-http`, `web` Build) im
Container unter `/opt/opencut/opencut-classic`.

## 7. Hinweise

- **Warum Docker statt nativem Bun-Build?** Upstream baut mit `bun` + `turbo`-Monorepo —
  nativ im LXC wären das mehrere GB Build-Deps und 10+ Minuten Bauzeit plus fragile
  WASM/Rust-Schritte. Die Compose-Datei ist der dokumentierte Self-Host-Weg
  (`docker compose up -d`) und macht den Installer idempotent und schnell.
- **Warum 8 GB / 20 GB?** Web (Next.js Prod-Build, `tsc`-Type-Check) + Postgres + Redis + srh brauchen
  real ~2,5–3,5 GB RAM im Lauf, aber der **Build** braucht ~6–8 GB (zwei jest-Worker allein ~3 GB).
  Mit 4 GB läuft der Container in vollen Swap und der Build thrashd stundenlang ohne Fehlermeldung —
  darum sind 8192 MB + 2048 MB Swap Default (verifiziert 2026-10-07: Compile 3,5 min → 98 s nach Hochskalieren).
  Images + Build-Cache brauchen ~6–8 GB Disk — darum warnt das Skript unter 12 GB.
- **LXC statt VM:** Mit `nesting=1,keyctl=1` läuft Docker stabil im unprivilegierten
  LXC — keine VM nötig (Classic rendert client-side via WASM, kein GPU-Bedarf).
  Nur wenn der Host kein nesting erlaubt, auf VM wechseln.
- **DHCP-Hinweis:** Ändert sich die Container-IP, Installer erneut laufen lassen —
  er erkennt die neue IP und schreibt `NEXT_PUBLIC_SITE_URL` in
  `/opt/opencut/opencut-classic/.env` neu (Secrets bleiben). Für stabile URLs
  DHCP-Reservierung oder statische IP einrichten.
- Erster Start baut das Web-Image (`docker compose build`) — Web UI kann 3–6 Minuten
  brauchen (Health wird bis zu 300 s gepollt).
- Optionale Build-Args (`FREESOUND_*`, `MARBLE_*`) bleiben auf Upstream-Defaults;
  bei Bedarf in `.env` im Container ergänzen und `bash opencut.sh --ctid <CT>` erneut laufen lassen.
