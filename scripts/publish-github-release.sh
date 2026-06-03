#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION_VALUE="${VERSION:-}"
REPO=""
TITLE=""
NOTES=""
ASSETS=""

if [ -z "$VERSION_VALUE" ]; then
    if [ -f "$ROOT_DIR/VERSION" ]; then
        VERSION_VALUE="$(sed -n '1p' "$ROOT_DIR/VERSION" | tr -d '[:space:]')"
    else
        VERSION_VALUE="0.1.0"
    fi
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --version\n' >&2; exit 64; }
            VERSION_VALUE="$1"
            ;;
        --repo)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --repo\n' >&2; exit 64; }
            REPO="$1"
            ;;
        --title)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --title\n' >&2; exit 64; }
            TITLE="$1"
            ;;
        --notes)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --notes\n' >&2; exit 64; }
            NOTES="$1"
            ;;
        --asset)
            shift
            [ "$#" -gt 0 ] || { printf 'Missing value for --asset\n' >&2; exit 64; }
            ASSETS="${ASSETS}${ASSETS:+
}$1"
            ;;
        --help|-h)
            printf 'Usage: %s [--version VERSION] [--repo OWNER/REPO] [--title TITLE] [--notes TEXT] --asset PATH [...]\n' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 64
            ;;
    esac
    shift
done

[ -n "$VERSION_VALUE" ] || { printf 'Version must not be empty.\n' >&2; exit 64; }

TAG="v$VERSION_VALUE"
if [ -z "$TITLE" ]; then
    TITLE="Heartecho $VERSION_VALUE"
fi
if [ -z "$NOTES" ]; then
    NOTES="Automated Heartecho package build for $TAG."
fi
if [ -z "$ASSETS" ]; then
    ASSETS="$ROOT_DIR/build/pkg/Heartecho-Distribution-$VERSION_VALUE.pkg
$ROOT_DIR/build/pkg/Heartecho-$VERSION_VALUE.pkg
$ROOT_DIR/build/pkg/Heartecho-Uninstaller-$VERSION_VALUE.pkg
$ROOT_DIR/build/release-manifest.json"
fi

GH_ARGS=""
if [ -n "$REPO" ]; then
    GH_ARGS="--repo $REPO"
fi

printf 'Heartecho GitHub Release publish\n'
printf '%s\n' "- tag: $TAG"
printf '%s\n' "- mode: create when missing, update assets when existing"

printf '%s\n' "$ASSETS" | while IFS= read -r asset; do
    [ -n "$asset" ] || continue
    [ -f "$asset" ] || { printf 'Missing release asset: %s\n' "$asset" >&2; exit 1; }
done

# shellcheck disable=SC2086
if gh release view "$TAG" $GH_ARGS >/dev/null 2>&1; then
    printf '%s\n' "- release exists: yes"
    printf '%s\n' "$ASSETS" | while IFS= read -r asset; do
        [ -n "$asset" ] || continue
        # shellcheck disable=SC2086
        gh release upload "$TAG" "$asset" --clobber $GH_ARGS
    done
else
    printf '%s\n' "- release exists: no"
    set -- "$TAG"
    printf '%s\n' "$ASSETS" | while IFS= read -r asset; do
        [ -n "$asset" ] || continue
        # shellcheck disable=SC2086
        gh release create "$TAG" "$asset" --title "$TITLE" --notes "$NOTES" $GH_ARGS
        break
    done
    FIRST_ASSET="$(printf '%s\n' "$ASSETS" | sed -n '1p')"
    printf '%s\n' "$ASSETS" | while IFS= read -r asset; do
        [ -n "$asset" ] || continue
        [ "$asset" != "$FIRST_ASSET" ] || continue
        # shellcheck disable=SC2086
        gh release upload "$TAG" "$asset" --clobber $GH_ARGS
    done
fi

printf 'Published %s\n' "$TAG"
