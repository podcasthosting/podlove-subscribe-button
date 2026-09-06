#!/usr/bin/env bash
#
# Installation / Deployment des Podlove Subscribe Buttons auf dem Live-Server.
#
# Ablauf:
#   1. Voraussetzungen prüfen (root, git, rsync, node, yarn)
#   2. Install-User "deployer" anlegen (falls nicht vorhanden)
#   3. Repository nach ~deployer/src/podlove-subscribe-button klonen bzw. aktualisieren
#   4. Abhängigkeiten installieren und Build (gulp) als "deployer" ausführen
#   5. dist/ per rsync in den Zielordner unter /var/www spiegeln
#
# Aufruf (als root):
#   ./install-live.sh                 # deployt master
#   ./install-live.sh --ref v1.2.0    # deployt Tag/Branch/Commit
#   ./install-live.sh --dry-run       # baut, zeigt aber nur an, was rsync tun würde
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Konfiguration (per Umgebungsvariable überschreibbar)
# ---------------------------------------------------------------------------
DEPLOY_USER="${DEPLOY_USER:-deployer}"
# SSH-URL setzt einen Deploy-Key für den User "deployer" voraus.
# Für ein öffentliches Repo alternativ:
#   REPO_URL=https://github.com/podcasthosting/podlove-subscribe-button.git
REPO_URL="${REPO_URL:-git@github.com:podcasthosting/podlove-subscribe-button.git}"
REPO_REF="${REPO_REF:-master}"                       # Branch, Tag oder Commit
CHECKOUT_SUBDIR="${CHECKOUT_SUBDIR:-src/podlove-subscribe-button}"  # relativ zum Home
WWW_DIR="${WWW_DIR:-/var/www/podlove-subscribe-button}"      # Zielordner im Webroot
WWW_OWNER="${WWW_OWNER:-www-data:www-data}"          # Besitzer der ausgelieferten Dateien
BACKUP_DIR="${BACKUP_DIR:-/var/backups/podlove-subscribe-button}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"
DRY_RUN=0

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fehler]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# Führt einen Befehl in einer Login-Shell des Deploy-Users aus
# (Login-Shell, damit z. B. nvm/PATH aus ~/.profile bzw. ~/.bashrc greifen).
as_deployer() {
  if command -v runuser >/dev/null 2>&1; then
    runuser -l "$DEPLOY_USER" -c "$*"
  else
    su -l "$DEPLOY_USER" -c "$*"
  fi
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)     REPO_REF="${2:?--ref benötigt einen Wert}"; shift 2 ;;
    --repo)    REPO_URL="${2:?--repo benötigt einen Wert}"; shift 2 ;;
    --target)  WWW_DIR="${2:?--target benötigt einen Wert}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *)         die "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Voraussetzungen
# ---------------------------------------------------------------------------
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Dieses Skript muss als root laufen."

# Schutz vor Tippfehlern im Zielpfad: es wird mit --delete gespiegelt.
case "$WWW_DIR" in
  /var/www/?*) : ;;
  *) die "Zielordner muss ein Unterverzeichnis von /var/www sein (aktuell: '$WWW_DIR')." ;;
esac

for bin in git rsync; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' ist nicht installiert (z. B. 'apt-get install -y $bin')."
done

# ---------------------------------------------------------------------------
# 2. Install-User
# ---------------------------------------------------------------------------
if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  log "Benutzer '$DEPLOY_USER' existiert bereits."
else
  log "Lege Benutzer '$DEPLOY_USER' an."
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi

DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
[[ -n "$DEPLOY_HOME" && -d "$DEPLOY_HOME" ]] || die "Home-Verzeichnis von '$DEPLOY_USER' nicht gefunden."
SRC_DIR="$DEPLOY_HOME/$CHECKOUT_SUBDIR"

# ---------------------------------------------------------------------------
# 3. Quellen von GitHub holen
# ---------------------------------------------------------------------------
if [[ "$REPO_URL" != http* ]]; then
  # Host-Key von github.com hinterlegen, damit das Klonen nicht interaktiv nachfragt.
  SSH_DIR="$DEPLOY_HOME/.ssh"
  install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SSH_DIR"
  if ! grep -q '^github\.com ' "$SSH_DIR/known_hosts" 2>/dev/null; then
    log "Hinterlege GitHub-Hostkey in $SSH_DIR/known_hosts."
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> "$SSH_DIR/known_hosts" 2>/dev/null \
      || warn "ssh-keyscan fehlgeschlagen – Klonen könnte interaktiv nachfragen."
    chown "$DEPLOY_USER:$DEPLOY_USER" "$SSH_DIR/known_hosts"
    chmod 600 "$SSH_DIR/known_hosts"
  fi
  [[ -f "$SSH_DIR/id_rsa" || -f "$SSH_DIR/id_ed25519" ]] \
    || warn "Kein SSH-Key für '$DEPLOY_USER' gefunden – für SSH-Clone wird ein Deploy-Key benötigt."
fi

install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$(dirname "$SRC_DIR")"

if [[ -d "$SRC_DIR/.git" ]]; then
  log "Aktualisiere vorhandenes Checkout in $SRC_DIR (Ref: $REPO_REF)."
  as_deployer "cd '$SRC_DIR' \
    && git remote set-url origin '$REPO_URL' \
    && git fetch --prune --tags origin \
    && git checkout --force '$REPO_REF' \
    && (git symbolic-ref -q HEAD >/dev/null && git reset --hard 'origin/$REPO_REF' || true) \
    && git clean -fdx --exclude=node_modules"
else
  log "Klone $REPO_URL nach $SRC_DIR (Ref: $REPO_REF)."
  as_deployer "git clone --branch '$REPO_REF' '$REPO_URL' '$SRC_DIR'"
fi

VERSION="$(as_deployer "cd '$SRC_DIR' && git describe --tags --always --dirty" 2>/dev/null || echo unbekannt)"
log "Ausgechecktes Release: $VERSION"

# ---------------------------------------------------------------------------
# 4. Abhängigkeiten installieren und bauen
# ---------------------------------------------------------------------------
as_deployer "command -v node >/dev/null 2>&1" \
  || die "node ist für '$DEPLOY_USER' nicht im PATH (Node.js bzw. nvm installieren)."
log "Node: $(as_deployer 'node --version')"

if as_deployer "command -v yarn >/dev/null 2>&1"; then
  PKG_INSTALL="yarn install --frozen-lockfile --non-interactive"
else
  warn "yarn nicht gefunden – benutze npm."
  PKG_INSTALL="npm install --no-audit --no-fund"
fi

log "Installiere Abhängigkeiten in $SRC_DIR."
as_deployer "cd '$SRC_DIR' && $PKG_INSTALL"

# Sicherheitsnetz: node-sass wurde durch dart-sass ersetzt und baut auf aktuellen
# Node-Versionen nicht mehr (node-gyp/libsass). Taucht es doch wieder im Baum auf,
# lieber laut abbrechen als mit einem kryptischen gyp-Fehler.
if as_deployer "cd '$SRC_DIR' && [ -d node_modules/node-sass ]"; then
  die "node-sass ist wieder in den Abhängigkeiten – es baut auf modernen Node-Versionen nicht mehr. Bitte entfernen (der Build nutzt 'sass'/dart-sass)."
fi

log "Baue Assets (gulp)."
as_deployer "cd '$SRC_DIR' && npm run clean --silent && npm run build --silent"

DIST_DIR="$SRC_DIR/dist"
[[ -f "$DIST_DIR/button.html" && -f "$DIST_DIR/javascripts/app.js" ]] \
  || die "Build unvollständig: $DIST_DIR enthält kein button.html / javascripts/app.js."

# ---------------------------------------------------------------------------
# 5. Ausrollen nach /var/www
# ---------------------------------------------------------------------------
install -d -m 755 "$WWW_DIR"

if [[ $DRY_RUN -eq 0 && -n "$(ls -A "$WWW_DIR" 2>/dev/null)" ]]; then
  install -d -m 750 "$BACKUP_DIR"
  BACKUP_FILE="$BACKUP_DIR/$(basename "$WWW_DIR")-$(date +%Y%m%d-%H%M%S).tar.gz"
  log "Sichere aktuellen Stand nach $BACKUP_FILE."
  tar -czf "$BACKUP_FILE" -C "$WWW_DIR" .
  # Nur die letzten $KEEP_BACKUPS Sicherungen behalten.
  ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n "+$((KEEP_BACKUPS + 1))" | xargs -r rm -f
fi

RSYNC_OPTS=(-rlt --delete --chmod=D2755,F644 --human-readable --itemize-changes)
[[ $DRY_RUN -eq 1 ]] && RSYNC_OPTS+=(--dry-run)

log "Spiegele $DIST_DIR/ nach $WWW_DIR/$([[ $DRY_RUN -eq 1 ]] && echo ' (dry-run)')."
rsync "${RSYNC_OPTS[@]}" "$DIST_DIR/" "$WWW_DIR/"

if [[ $DRY_RUN -eq 0 ]]; then
  chown -R "$WWW_OWNER" "$WWW_DIR"
  printf '%s\n' "$VERSION" > "$WWW_DIR/.deployed-version"
  chown "$WWW_OWNER" "$WWW_DIR/.deployed-version"
  chmod 644 "$WWW_DIR/.deployed-version"
  log "Fertig: $VERSION ist unter $WWW_DIR ausgerollt."
else
  log "Dry-run beendet – es wurde nichts nach $WWW_DIR geschrieben."
fi
