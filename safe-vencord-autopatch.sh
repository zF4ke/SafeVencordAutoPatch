#!/usr/bin/env sh
set -eu

NAME="SafeVencordAutoPatch"
BRANCH="${BRANCH:-auto}"

case "$(uname -s)" in
  Darwin)
    OS="macos"
    APP_DIR="$HOME/Library/Application Support/$NAME"
    ASSET_NAME="VencordInstaller.MacOS.zip"
    INSTALLER_PATH="$APP_DIR/VencordInstaller.app/Contents/MacOS/VencordInstaller"
    ;;
  Linux)
    OS="linux"
    APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/$NAME"
    ASSET_NAME="VencordInstallerCli-linux"
    INSTALLER_PATH="$APP_DIR/VencordInstallerCli-linux"
    ;;
  *)
    echo "Unsupported OS"
    exit 1
    ;;
esac

CHECKSUM_PATH="$APP_DIR/checksums.sha256"
STATE_PATH="$APP_DIR/state"
LOG_PATH="$APP_DIR/patch.log"

log() {
  mkdir -p "$APP_DIR"
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$line"
  printf '%s\n' "$line" >> "$LOG_PATH"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

download() {
  url="$1"
  out="$2"
  case "$url" in
    https://github.com/Vencord/Installer/releases/latest/download/*|https://github.com/Vencord/Installer/releases/download/*) ;;
    *) echo "Refusing untrusted URL: $url"; exit 1 ;;
  esac

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$out"
  else
    echo "Need curl or wget"
    exit 1
  fi
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

expected_hash() {
  awk -v name="$ASSET_NAME" '$0 ~ name "$" { print $1; exit }' "$CHECKSUM_PATH"
}

get_official_installer() {
  mkdir -p "$APP_DIR"
  checksum_url="https://github.com/Vencord/Installer/releases/latest/download/checksums.sha256"
  asset_download_url="https://github.com/Vencord/Installer/releases/latest/download/$ASSET_NAME"

  download "$checksum_url" "$CHECKSUM_PATH"
  expected="$(expected_hash)"
  [ -n "$expected" ] || { echo "Could not find checksum for $ASSET_NAME"; exit 1; }

  if [ "$OS" = "macos" ]; then
    archive="$APP_DIR/$ASSET_NAME"
    current=""
    [ -f "$archive" ] && current="$(hash_file "$archive")"
    if [ "$current" != "$expected" ]; then
      log "Downloading official $ASSET_NAME"
      download "$asset_download_url" "$archive.download"
      actual="$(hash_file "$archive.download")"
      [ "$actual" = "$expected" ] || { rm -f "$archive.download"; echo "Hash mismatch"; exit 1; }
      mv "$archive.download" "$archive"
      rm -rf "$APP_DIR/VencordInstaller.app"
      unzip -q "$archive" -d "$APP_DIR"
      chmod +x "$INSTALLER_PATH" 2>/dev/null || true
    fi
  else
    current=""
    [ -f "$INSTALLER_PATH" ] && current="$(hash_file "$INSTALLER_PATH")"
    if [ "$current" != "$expected" ]; then
      log "Downloading official $ASSET_NAME"
      download "$asset_download_url" "$INSTALLER_PATH.download"
      actual="$(hash_file "$INSTALLER_PATH.download")"
      [ "$actual" = "$expected" ] || { rm -f "$INSTALLER_PATH.download"; echo "Hash mismatch"; exit 1; }
      mv "$INSTALLER_PATH.download" "$INSTALLER_PATH"
      chmod +x "$INSTALLER_PATH"
    fi
  fi
}

fingerprint() {
  if [ "$OS" = "macos" ]; then
    for app in "/Applications/Discord.app" "/Applications/Discord PTB.app" "/Applications/Discord Canary.app"; do
      asar="$app/Contents/Resources/app.asar"
      [ -f "$asar" ] && stat -f '%N|%z|%m' "$asar"
    done
  else
    for base in "$HOME/.config" /opt /usr/lib /usr/share "$HOME/.local/share/flatpak/app" /var/lib/flatpak/app; do
      [ -d "$base" ] || continue
      find "$base" -path '*[Dd]iscord*resources/app.asar' -type f -print 2>/dev/null |
        while IFS= read -r asar; do
          stat -c '%n|%s|%Y' "$asar"
        done
    done
  fi | sort
}

patch_if_needed() {
  current="$(fingerprint)"
  if [ -z "$current" ]; then
    log "No Discord install found"
    exit 0
  fi

  saved=""
  [ -f "$STATE_PATH" ] && saved="$(cat "$STATE_PATH")"
  if [ "${1:-}" != "force" ] && [ "$current" = "$saved" ]; then
    log "Discord unchanged; nothing to patch"
    exit 0
  fi

  get_official_installer
  log "Discord changed; running official Vencord installer"
  "$INSTALLER_PATH" -install -branch "$BRANCH" >> "$LOG_PATH" 2>&1
  fingerprint > "$STATE_PATH"
  log "Patch complete"
}

install_macos() {
  mkdir -p "$APP_DIR"
  cp "$0" "$APP_DIR/safe-vencord-autopatch.sh"
  chmod +x "$APP_DIR/safe-vencord-autopatch.sh"
  plist="$HOME/Library/LaunchAgents/com.safevencord.autopatch.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.safevencord.autopatch</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DIR/safe-vencord-autopatch.sh</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>12</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
</dict>
</plist>
EOF
  launchctl unload "$plist" >/dev/null 2>&1 || true
  launchctl load "$plist"
  log "Installed LaunchAgent"
}

install_linux() {
  need systemctl
  mkdir -p "$APP_DIR" "$HOME/.config/systemd/user"
  cp "$0" "$APP_DIR/safe-vencord-autopatch.sh"
  chmod +x "$APP_DIR/safe-vencord-autopatch.sh"

  cat > "$HOME/.config/systemd/user/safe-vencord-autopatch.service" <<EOF
[Unit]
Description=Safe Vencord auto patch

[Service]
Type=oneshot
ExecStart=$APP_DIR/safe-vencord-autopatch.sh run
EOF

  cat > "$HOME/.config/systemd/user/safe-vencord-autopatch.timer" <<EOF
[Unit]
Description=Check Discord updates for Vencord

[Timer]
OnBootSec=2min
OnCalendar=*-*-* 12:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now safe-vencord-autopatch.timer
  log "Installed user systemd timer"
}

uninstall_macos() {
  plist="$HOME/Library/LaunchAgents/com.safevencord.autopatch.plist"
  launchctl unload "$plist" >/dev/null 2>&1 || true
  rm -f "$plist"
  log "Removed LaunchAgent"
}

uninstall_linux() {
  systemctl --user disable --now safe-vencord-autopatch.timer >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/safe-vencord-autopatch.service" "$HOME/.config/systemd/user/safe-vencord-autopatch.timer"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  log "Removed user systemd timer"
}

case "${1:-run}" in
  install)
    if [ "$OS" = "macos" ]; then install_macos; else install_linux; fi
    patch_if_needed force
    ;;
  uninstall)
    if [ "$OS" = "macos" ]; then uninstall_macos; else uninstall_linux; fi
    ;;
  force)
    patch_if_needed force
    ;;
  run)
    patch_if_needed
    ;;
  *)
    echo "Usage: $0 [install|uninstall|run|force]"
    exit 1
    ;;
esac
