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

# Create package directory structure
PKG_DIR="$OUTPUT_DIR/${PACKAGE}_${VERSION}_${ARCH}"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/share/${PACKAGE}/patches"
mkdir -p "$PKG_DIR/usr/share/${PACKAGE}/scripts"
mkdir -p "$PKG_DIR/etc/apt/apt.conf.d"
mkdir -p "$PKG_DIR/usr/share/perl5/PVE/Storage/Custom"

# Copy control files with version substitution
sed "s/@VERSION@/$VERSION/" debian/control > "$PKG_DIR/DEBIAN/control"
sed "s/@VERSION@/$VERSION/" debian/changelog > "$PKG_DIR/DEBIAN/changelog"

# Copy maintainer scripts (make them executable)
cat debian/postinst > "$PKG_DIR/DEBIAN/postinst"
cat debian/prerm > "$PKG_DIR/DEBIAN/prerm"
cat debian/postrm > "$PKG_DIR/DEBIAN/postrm"
chmod 755 "$PKG_DIR/DEBIAN/postinst" "$PKG_DIR/DEBIAN/prerm" "$PKG_DIR/DEBIAN/postrm"

# Copy patches
cp debian/patches/*.patch "$PKG_DIR/usr/share/${PACKAGE}/patches/"

# Copy patch manager script (make executable)
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
else
    echo "WARNING: GUI file not found, skipping..."
fi

# Copy storage plugin
if [ -f "PVE/Storage/Custom/IBMFlashSystem.pm" ]; then
    cp PVE/Storage/Custom/IBMFlashSystem.pm "$PKG_DIR/usr/share/perl5/PVE/Storage/Custom/"
    echo "Copied storage plugin"
else
    echo "WARNING: Storage plugin not found, skipping..."
fi

# Calculate installed size
INSTALLED_SIZE=$(du -sk "$PKG_DIR" | cut -f1)

echo "Installed-Size: $INSTALLED_SIZE" >> "$PKG_DIR/DEBIAN/control"

# Build deb package
cd "$OUTPUT_DIR"
dpkg-deb --build "${PACKAGE}_${VERSION}_${ARCH}"

# Fix ownership
chown -R $(id -u):$(id -g) "$OUTPUT_DIR" 2>/dev/null || true

echo ""
echo "✓ Built: ${OUTPUT_DIR}/${PACKAGE}_${VERSION}_${ARCH}.deb"
ls -la "${OUTPUT_DIR}/${PACKAGE}_${VERSION}_${ARCH}.deb"
