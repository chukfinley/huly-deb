#!/bin/bash
set -euo pipefail

#
# build-deb.sh — Convert Huly AppImage to .deb package (local build)
#
# Prerequisites:  sudo apt install curl jq file dpkg-dev
#
# Usage:
#   ./build-deb.sh              # auto-detect latest version
#   ./build-deb.sh 0.7.382      # force specific version
#

HULY_GITHUB_REPO="hcengineering/platform"
PKG_NAME="huly"
DEB_MAINTAINER="Huly Deb Repackager <huly-deb@users.noreply.github.com>"
DEB_DESCRIPTION="Huly — All-in-One Project Management Platform"
DEB_HOMEPAGE="https://huly.io"

WORK_DIR="$(mktemp -d)"
trap 'echo "Cleaning up $WORK_DIR"; rm -rf "$WORK_DIR"' EXIT

echo "==> Working directory: $WORK_DIR"

# ── Step 1: Determine version ────────────────────────────────────────────────
if [ -n "${1:-}" ]; then
  VERSION="$1"
  echo "==> Forced version: $VERSION"
else
  echo "==> Querying latest version from GitHub..."
  VERSION=$(curl -sS "https://api.github.com/repos/${HULY_GITHUB_REPO}/releases/latest" \
    | jq -r '.tag_name' | sed 's/^v//')

  if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
    echo "ERROR: Could not determine latest Huly version"
    exit 1
  fi
  echo "==> Latest upstream version: $VERSION"
fi

APPIMAGE_URL="https://dist.huly.io/Huly-linux-${VERSION}.AppImage"
APPIMAGE_FILE="${WORK_DIR}/Huly-linux-${VERSION}.AppImage"

# ── Step 2: Download AppImage ─────────────────────────────────────────────────
echo "==> Downloading: $APPIMAGE_URL"
curl -fSL --retry 3 --retry-delay 5 --progress-bar -o "$APPIMAGE_FILE" "$APPIMAGE_URL"

if [ ! -s "$APPIMAGE_FILE" ]; then
  echo "ERROR: Downloaded AppImage is empty or missing"
  exit 1
fi

chmod +x "$APPIMAGE_FILE"
echo "==> Downloaded $(du -h "$APPIMAGE_FILE" | cut -f1) AppImage"

# ── Step 3: Extract AppImage ──────────────────────────────────────────────────
echo "==> Extracting AppImage..."
EXTRACT_DIR="${WORK_DIR}/squashfs-root"

# Run extraction from the work directory
(cd "$WORK_DIR" && "$APPIMAGE_FILE" --appimage-extract > /dev/null 2>&1)

if [ ! -d "$EXTRACT_DIR" ]; then
  echo "ERROR: AppImage extraction failed"
  exit 1
fi

echo "==> Extracted. Top-level contents:"
ls "$EXTRACT_DIR" | head -20

# ── Step 4: Detect main binary and architecture ──────────────────────────────
echo "==> Detecting main binary and architecture..."

# The Huly AppImage extracts with binary named "desktop" (Electron app)
# Try known names in priority order
MAIN_BIN=""
for candidate in desktop huly Huly huly-desktop; do
  if [ -f "$EXTRACT_DIR/$candidate" ] && [ -x "$EXTRACT_DIR/$candidate" ]; then
    MAIN_BIN="$EXTRACT_DIR/$candidate"
    break
  fi
done
if [ -z "$MAIN_BIN" ] && [ -f "$EXTRACT_DIR/AppRun" ]; then
  MAIN_BIN="$EXTRACT_DIR/AppRun"
fi
if [ -z "$MAIN_BIN" ]; then
  # Fallback: find first ELF executable (skip .so files)
  MAIN_BIN=$(find "$EXTRACT_DIR" -maxdepth 1 -type f -executable \
    ! -name "*.so" ! -name "*.so.*" \
    -exec sh -c 'file "$1" | grep -q "ELF" && echo "$1"' _ {} \; | head -1)
fi

if file "$MAIN_BIN" | grep -q "x86-64"; then
  DEB_ARCH="amd64"
elif file "$MAIN_BIN" | grep -q "aarch64"; then
  DEB_ARCH="arm64"
elif file "$MAIN_BIN" | grep -q "ARM"; then
  DEB_ARCH="armhf"
else
  DEB_ARCH="amd64"
  echo "WARNING: Could not detect architecture, defaulting to amd64"
fi
echo "==> Architecture: $DEB_ARCH"

# ── Step 5: Build .deb structure ──────────────────────────────────────────────
DEB_NAME="${PKG_NAME}_${VERSION}_${DEB_ARCH}.deb"
DEB_ROOT="${WORK_DIR}/deb-build"
INSTALL_DIR="${DEB_ROOT}/opt/huly"
BIN_DIR="${DEB_ROOT}/usr/bin"
DESKTOP_DIR="${DEB_ROOT}/usr/share/applications"
ICON_DIR="${DEB_ROOT}/usr/share/icons/hicolor"

echo "==> Building .deb package structure..."
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DESKTOP_DIR" "${DEB_ROOT}/DEBIAN"

# Copy application files
cp -a "${EXTRACT_DIR}/." "$INSTALL_DIR/"

# Find the actual executable name (must match the binary we detected earlier)
EXEC_NAME=""
for candidate in desktop huly Huly huly-desktop; do
  if [ -f "${INSTALL_DIR}/${candidate}" ] && [ -x "${INSTALL_DIR}/${candidate}" ]; then
    EXEC_NAME="$candidate"
    break
  fi
done
# Fallback: find any top-level ELF binary (skip .so files)
if [ -z "$EXEC_NAME" ]; then
  EXEC_NAME=$(find "$INSTALL_DIR" -maxdepth 1 -type f -executable \
    ! -name "*.so" ! -name "*.so.*" \
    -exec sh -c 'file "$1" | grep -q ELF && basename "$1"' _ {} \; | head -1)
fi

if [ -z "$EXEC_NAME" ]; then
  echo "ERROR: Could not find main executable in extracted AppImage"
  echo "Contents of install dir:"
  ls -la "$INSTALL_DIR"
  exit 1
fi
echo "==> Main executable: $EXEC_NAME"

# Create launcher script
cat > "${BIN_DIR}/huly" << EOF
#!/bin/bash
# Huly Desktop Launcher
exec /opt/huly/${EXEC_NAME} --no-sandbox "\$@"
EOF
chmod 755 "${BIN_DIR}/huly"

# ── Step 6: Icons ─────────────────────────────────────────────────────────────
echo "==> Installing icons..."
for size in 16 32 48 64 128 256 512 1024; do
  ICON_SRC=""
  for ext in png svg; do
    for pattern in \
      "${EXTRACT_DIR}/usr/share/icons/hicolor/${size}x${size}/apps/"*.${ext} \
      "${EXTRACT_DIR}/${size}x${size}."${ext} \
      "${EXTRACT_DIR}/icons/${size}x${size}."${ext}; do
      found=$(ls $pattern 2>/dev/null | head -1 || true)
      if [ -n "$found" ]; then
        ICON_SRC="$found"
        break 2
      fi
    done
  done
  if [ -n "$ICON_SRC" ]; then
    ICON_EXT="${ICON_SRC##*.}"
    mkdir -p "${ICON_DIR}/${size}x${size}/apps"
    cp "$ICON_SRC" "${ICON_DIR}/${size}x${size}/apps/huly.${ICON_EXT}"
    echo "    ${size}x${size}: installed"
  fi
done

# Grab top-level icon as fallback
if [ -f "${EXTRACT_DIR}/huly.png" ]; then
  mkdir -p "${ICON_DIR}/256x256/apps"
  cp "${EXTRACT_DIR}/huly.png" "${ICON_DIR}/256x256/apps/huly.png"
elif [ -f "${EXTRACT_DIR}/.DirIcon" ]; then
  mkdir -p "${ICON_DIR}/256x256/apps"
  cp "${EXTRACT_DIR}/.DirIcon" "${ICON_DIR}/256x256/apps/huly.png"
fi

# ── Step 7: Desktop entry ────────────────────────────────────────────────────
echo "==> Creating desktop entry..."
DESKTOP_SRC=$(ls "${EXTRACT_DIR}"/*.desktop 2>/dev/null | head -1 || true)
if [ -n "$DESKTOP_SRC" ]; then
  cp "$DESKTOP_SRC" "${DESKTOP_DIR}/huly.desktop"
  sed -i "s|Exec=.*|Exec=/usr/bin/huly %U|g" "${DESKTOP_DIR}/huly.desktop"
  sed -i "s|Icon=.*|Icon=huly|g" "${DESKTOP_DIR}/huly.desktop"
else
  cat > "${DESKTOP_DIR}/huly.desktop" << EOF
[Desktop Entry]
Name=Huly
Comment=${DEB_DESCRIPTION}
Exec=/usr/bin/huly %U
Icon=huly
Type=Application
Categories=Office;ProjectManagement;
StartupWMClass=Huly
MimeType=x-scheme-handler/huly;
EOF
fi

# ── Step 8: DEBIAN control files ─────────────────────────────────────────────
echo "==> Creating DEBIAN control files..."
INSTALLED_SIZE=$(du -sk "$INSTALL_DIR" | cut -f1)

cat > "${DEB_ROOT}/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Installed-Size: ${INSTALLED_SIZE}
Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0, libuuid1, libsecret-1-0
Maintainer: ${DEB_MAINTAINER}
Homepage: ${DEB_HOMEPAGE}
Description: ${DEB_DESCRIPTION}
 Huly is an open-source all-in-one project management platform.
 It provides issue tracking, team planning, knowledge management,
 and collaboration tools. This package is an unofficial repackaging
 of the official Huly AppImage into .deb format.
EOF

cat > "${DEB_ROOT}/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
if command -v update-desktop-database > /dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache > /dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
if [ -f /opt/huly/chrome-sandbox ]; then
  chmod 4755 /opt/huly/chrome-sandbox
fi
EOF
chmod 755 "${DEB_ROOT}/DEBIAN/postinst"

cat > "${DEB_ROOT}/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  if command -v update-desktop-database > /dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
fi
EOF
chmod 755 "${DEB_ROOT}/DEBIAN/postrm"

# Fix permissions
find "${DEB_ROOT}" -type d -exec chmod 755 {} \;
find "${DEB_ROOT}/DEBIAN" -type f -exec chmod 644 {} \;
chmod 755 "${DEB_ROOT}/DEBIAN/postinst" "${DEB_ROOT}/DEBIAN/postrm"
chmod 755 "${INSTALL_DIR}/${EXEC_NAME}"

# ── Step 9: Build .deb ───────────────────────────────────────────────────────
echo "==> Building .deb..."
OUTPUT_DIR="$(pwd)"
dpkg-deb --build --root-owner-group "$DEB_ROOT" "${OUTPUT_DIR}/${DEB_NAME}"

if [ ! -f "${OUTPUT_DIR}/${DEB_NAME}" ]; then
  echo "ERROR: Failed to build .deb package"
  exit 1
fi

# ── Step 10: Verify ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  SUCCESS: ${DEB_NAME}"
echo "  Size: $(du -h "${OUTPUT_DIR}/${DEB_NAME}" | cut -f1)"
echo "============================================"
echo ""
echo "=== Package Info ==="
dpkg-deb --info "${OUTPUT_DIR}/${DEB_NAME}"
echo ""
echo "=== Install with ==="
echo "  sudo dpkg -i ${DEB_NAME}"
echo "  sudo apt-get install -f    # fix missing deps"
echo ""
echo "=== Uninstall with ==="
echo "  sudo apt remove huly"
