#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PACKAGE_PATH="${1:-$ROOT_DIR/build/pkg/Heartecho-Distribution-0.1.0.pkg}"
EXPANDED_DIR="$ROOT_DIR/build/pkg/expanded-product-verify"

[ -f "$PACKAGE_PATH" ] || { printf 'Missing product package: %s\n' "$PACKAGE_PATH" >&2; exit 1; }

rm -rf "$EXPANDED_DIR"
pkgutil --expand "$PACKAGE_PATH" "$EXPANDED_DIR" >/dev/null

DISTRIBUTION_XML="$EXPANDED_DIR/Distribution"
[ -f "$DISTRIBUTION_XML" ] || { printf 'Product package is missing Distribution XML.\n' >&2; exit 1; }
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$DISTRIBUTION_XML"
else
    ruby -rrexml/document -e 'REXML::Document.new(File.read(ARGV.fetch(0)))' "$DISTRIBUTION_XML"
fi

grep -q '<product id="com.heartecho.Heartecho.distribution"' "$DISTRIBUTION_XML" || {
    printf 'Unexpected or missing product identifier in Distribution XML.\n' >&2
    exit 1
}

grep -q '<pkg-ref id="com.heartecho.Heartecho.pkg"' "$DISTRIBUTION_XML" || {
    printf 'Distribution XML is missing installer component reference.\n' >&2
    exit 1
}

grep -q '<pkg-ref id="com.heartecho.Heartecho.uninstaller.pkg"' "$DISTRIBUTION_XML" || {
    printf 'Distribution XML is missing uninstaller component reference.\n' >&2
    exit 1
}

INSTALLER_COMPONENT="$(find "$EXPANDED_DIR" -maxdepth 2 -type d -name 'Heartecho-*.pkg' ! -name '*Uninstaller*' ! -name '*Distribution*' | head -1)"
UNINSTALLER_COMPONENT="$(find "$EXPANDED_DIR" -maxdepth 2 -type d -name 'Heartecho-Uninstaller-*.pkg' | head -1)"

[ -n "$INSTALLER_COMPONENT" ] || { printf 'Product package is missing expanded installer component.\n' >&2; exit 1; }
[ -n "$UNINSTALLER_COMPONENT" ] || { printf 'Product package is missing expanded uninstaller component.\n' >&2; exit 1; }

[ -f "$INSTALLER_COMPONENT/PackageInfo" ] || { printf 'Installer component is missing PackageInfo.\n' >&2; exit 1; }
[ -f "$UNINSTALLER_COMPONENT/PackageInfo" ] || { printf 'Uninstaller component is missing PackageInfo.\n' >&2; exit 1; }

grep -q 'identifier="com.heartecho.Heartecho.pkg"' "$INSTALLER_COMPONENT/PackageInfo" || {
    printf 'Installer component has an unexpected package identifier.\n' >&2
    exit 1
}

grep -q 'identifier="com.heartecho.Heartecho.uninstaller.pkg"' "$UNINSTALLER_COMPONENT/PackageInfo" || {
    printf 'Uninstaller component has an unexpected package identifier.\n' >&2
    exit 1
}

pkgutil --check-signature "$PACKAGE_PATH" >/dev/null 2>&1 || true
printf 'Verified %s\n' "$PACKAGE_PATH"
