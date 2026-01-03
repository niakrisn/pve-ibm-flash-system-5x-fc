#!/bin/bash
set -e

# Read version from VERSION file
VERSION=$(cat VERSION 2>/dev/null || echo "1.0.0")
PACKAGE="pve-ibm-fs5x-fc-plugin"
ARCH="all"
OUTPUT_DIR="output"

echo "Building ${PACKAGE}_${VERSION}_${ARCH}.deb..."

# Clean and create output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# -----------------------------------------------------------------------------
# 1. Main Plugin Package
# -----------------------------------------------------------------------------
PKG_DIR="$OUTPUT_DIR/${PACKAGE}_${VERSION}_${ARCH}"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/share/${PACKAGE}/patches"
mkdir -p "$PKG_DIR/usr/share/${PACKAGE}/scripts"
mkdir -p "$PKG_DIR/etc/apt/apt.conf.d"
mkdir -p "$PKG_DIR/usr/share/perl5/PVE/Storage/Custom"

# Extract control section for main package (first Package: block, stop at empty line or next Package:)
sed -n '/^Package: pve-ibm-fs5x-fc-plugin$/,/^$/p' debian/control | head -n -1 | sed "s/@VERSION@/$VERSION/" > "$PKG_DIR/DEBIAN/control"
sed "s/@VERSION@/$VERSION/" debian/changelog > "$PKG_DIR/DEBIAN/changelog"

# Copy maintainer scripts
cat debian/postinst > "$PKG_DIR/DEBIAN/postinst"
cat debian/prerm > "$PKG_DIR/DEBIAN/prerm"
cat debian/postrm > "$PKG_DIR/DEBIAN/postrm"
chmod 755 "$PKG_DIR/DEBIAN/postinst" "$PKG_DIR/DEBIAN/prerm" "$PKG_DIR/DEBIAN/postrm"

# Copy patches
cp debian/patches/*.patch "$PKG_DIR/usr/share/${PACKAGE}/patches/"

# Copy patch manager script
cp scripts/patch-manager.sh "$PKG_DIR/usr/share/${PACKAGE}/scripts/"
chmod 755 "$PKG_DIR/usr/share/${PACKAGE}/scripts/patch-manager.sh"

# Copy APT hook
cp configs/90-pve-ibm-fs5x-fc-plugin-hook "$PKG_DIR/etc/apt/apt.conf.d/"

# Copy multipath configuration
mkdir -p "$PKG_DIR/etc/multipath/conf.d"
if [ -f "configs/99-pve-ibm-flashsystem.conf" ]; then
    cp configs/99-pve-ibm-flashsystem.conf "$PKG_DIR/etc/multipath/conf.d/"
    echo "Copied multipath configuration"
fi

# Copy GUI integration file
if [ -f "configs/ibmflash-gui.js" ]; then
    cp configs/ibmflash-gui.js "$PKG_DIR/usr/share/${PACKAGE}/"
    echo "Copied GUI integration"
fi

# Copy storage plugin and sub-modules
cp PVE/Storage/Custom/IBMFlashSystem.pm "$PKG_DIR/usr/share/perl5/PVE/Storage/Custom/"
cp -r PVE/Storage/Custom/IBMFlashSystem "$PKG_DIR/usr/share/perl5/PVE/Storage/Custom/"

# Calculate installed size
INSTALLED_SIZE=$(du -sk "$PKG_DIR" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >> "$PKG_DIR/DEBIAN/control"

# Build main package
dpkg-deb --build "$PKG_DIR"

# -----------------------------------------------------------------------------
# 2. Tests Package
# -----------------------------------------------------------------------------
TEST_PACKAGE="${PACKAGE}-tests"
TEST_PKG_DIR="$OUTPUT_DIR/${TEST_PACKAGE}_${VERSION}_${ARCH}"
TEST_DATA_DIR="usr/share/${TEST_PACKAGE}"

echo "Building ${TEST_PACKAGE}_${VERSION}_${ARCH}.deb..."

mkdir -p "$TEST_PKG_DIR/DEBIAN"
mkdir -p "$TEST_PKG_DIR/usr/bin"
mkdir -p "$TEST_PKG_DIR/${TEST_DATA_DIR}/scenarios"
mkdir -p "$TEST_PKG_DIR/${TEST_DATA_DIR}/lib"

# Extract control section for tests package (second Package: block)
sed -n '/^Package: pve-ibm-fs5x-fc-plugin-tests$/,/^$/p' debian/control | head -n -1 | sed "s/@VERSION@/$VERSION/" > "$TEST_PKG_DIR/DEBIAN/control"

# Copy test runner script
cp scripts/pve-ibm-fs5x-test-runner "$TEST_PKG_DIR/usr/bin/"
chmod 755 "$TEST_PKG_DIR/usr/bin/pve-ibm-fs5x-test-runner"

# Copy integration tests and scenarios
cp t/integration/scenarios/*.t "$TEST_PKG_DIR/${TEST_DATA_DIR}/scenarios/"
cp t/integration/lib/*.pm "$TEST_PKG_DIR/${TEST_DATA_DIR}/lib/"

# Calculate installed size for tests
TEST_INSTALLED_SIZE=$(du -sk "$TEST_PKG_DIR" | cut -f1)
echo "Installed-Size: $TEST_INSTALLED_SIZE" >> "$TEST_PKG_DIR/DEBIAN/control"

# Build tests package
dpkg-deb --build "$TEST_PKG_DIR"

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------

# Fix ownership
chown -R $(id -u):$(id -g) "$OUTPUT_DIR" 2>/dev/null || true

echo ""
echo "✓ Built: ${OUTPUT_DIR}/${PACKAGE}_${VERSION}_${ARCH}.deb"
echo "✓ Built: ${OUTPUT_DIR}/${TEST_PACKAGE}_${VERSION}_${ARCH}.deb"
ls -la "$OUTPUT_DIR"/*.deb
