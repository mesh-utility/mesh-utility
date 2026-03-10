#!/usr/bin/env bash
set -euo pipefail

# Mesh Utility Linux installer
# - Downloads release archive + checksum from GitHub
# - Verifies archive checksum
# - Installs into ~/.local/opt/mesh-utility
# - Creates ~/.local/bin/mesh-utility symlink
# - Creates desktop launcher entry with app icon

REPO="${REPO:-mesh-utility/mesh-utility}"
TAG="${1:-Alpha-3}"
ASSET_NAME="${ASSET_NAME:-mesh-utility-1.0.0-alpha.3-linux-x64.tar.gz}"

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/opt/mesh-utility}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
APP_DIR="${APP_DIR:-$HOME/.local/share/applications}"
ICON_DIR="${ICON_DIR:-$HOME/.local/share/icons/hicolor/256x256/apps}"

RELEASE_BASE="https://github.com/${REPO}/releases/download/${TAG}"

TMP_DIR="$(mktemp -d)"
ARCHIVE_PATH="${TMP_DIR}/${ASSET_NAME}"
SUMS_PATH="${TMP_DIR}/SHA256SUMS.txt"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "==> Downloading ${ASSET_NAME} from ${RELEASE_BASE}"
curl -fL -o "${ARCHIVE_PATH}" "${RELEASE_BASE}/${ASSET_NAME}"

echo "==> Downloading checksums"
curl -fL -o "${SUMS_PATH}" "${RELEASE_BASE}/SHA256SUMS.txt"

if grep -q " ${ASSET_NAME}$" "${SUMS_PATH}"; then
  echo "==> Verifying checksum"
  (
    cd "${TMP_DIR}"
    sha256sum -c "${SUMS_PATH}" --ignore-missing
  )
else
  echo "WARNING: ${ASSET_NAME} not listed in SHA256SUMS.txt; skipping checksum verification"
fi

echo "==> Installing to ${INSTALL_DIR}"
rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
tar -xzf "${ARCHIVE_PATH}" -C "${INSTALL_DIR}"

echo "==> Creating launcher symlink"
mkdir -p "${BIN_DIR}"
ln -sf "${INSTALL_DIR}/mesh_utility" "${BIN_DIR}/mesh-utility"

mkdir -p "${APP_DIR}" "${ICON_DIR}"
ICON_SRC="${INSTALL_DIR}/data/flutter_assets/assets/app-icon.png"
ICON_DEST="${ICON_DIR}/mesh-utility.png"
if [[ -f "${ICON_SRC}" ]]; then
  cp "${ICON_SRC}" "${ICON_DEST}"
else
  ICON_DEST=""
fi

DESKTOP_FILE="${APP_DIR}/mesh-utility.desktop"
echo "==> Creating desktop entry at ${DESKTOP_FILE}"
{
  echo "[Desktop Entry]"
  echo "Version=1.0"
  echo "Type=Application"
  echo "Name=Mesh Utility"
  echo "Comment=LoRa mesh coverage mapping utility"
  echo "Exec=${INSTALL_DIR}/mesh_utility"
  if [[ -n "${ICON_DEST}" ]]; then
    echo "Icon=${ICON_DEST}"
  fi
  echo "Terminal=false"
  echo "Categories=Utility;Network;"
  echo "StartupNotify=true"
} > "${DESKTOP_FILE}"
chmod +x "${DESKTOP_FILE}"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "${APP_DIR}" >/dev/null 2>&1 || true
fi

echo
echo "Install complete."
echo "Run from terminal: ${BIN_DIR}/mesh-utility"
echo "Or launch from your desktop menu: Mesh Utility"
