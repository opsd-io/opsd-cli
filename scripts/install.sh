#!/bin/sh
# Install a portable bundle without changing shell startup files or requiring host Ruby.
set -eu

fail() { printf 'opsd install: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage: sh install.sh [--version VERSION] [--prefix DIRECTORY]
       sh install.sh --local [--prefix DIRECTORY]
       sh install.sh --archive FILE [--prefix DIRECTORY]

Default: download the latest release for this OS/architecture into ~/opsd.
--local prompts for an already downloaded archive; --archive selects it directly.
--prefix chooses the installation directory. Existing installations are preserved.
OPSD_RELEASE_BASE_URL can select a release mirror with GitHub-style URLs.
HELP
}

INSTALL_PREFIX="${HOME:?HOME is required}/opsd"
RELEASE_BASE="${OPSD_RELEASE_BASE_URL:-https://github.com/opsd-io/opsd-cli/releases}"
INSTALL_VERSION=""
LOCAL_ARCHIVE=""
PROMPT_LOCAL=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--prefix|--archive)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
      case "$1" in
        --version) INSTALL_VERSION="$2" ;;
        --prefix) INSTALL_PREFIX="$2" ;;
        --archive) LOCAL_ARCHIVE="$2" ;;
      esac
      shift 2 ;;
    --local) PROMPT_LOCAL=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1 (use --help)" ;;
  esac
done
[ -n "$INSTALL_PREFIX" ] || fail 'Installation directory cannot be empty'
if [ "$PROMPT_LOCAL" = yes ]; then
  [ -z "$LOCAL_ARCHIVE" ] || fail 'Use either --local or --archive'
  printf 'Path to the downloaded OPSd .tar.gz archive: '
  IFS= read -r LOCAL_ARCHIVE || fail 'No archive path provided'
  [ -n "$LOCAL_ARCHIVE" ] || fail 'No archive path provided'
fi
[ -z "$LOCAL_ARCHIVE" ] || [ -z "$INSTALL_VERSION" ] || fail 'Use either a local archive or --version'

case "$(uname -s)" in
  Darwin) PLATFORM_OS=darwin ;;
  Linux) PLATFORM_OS=linux ;;
  *) fail 'Supported operating systems: macOS and Linux' ;;
esac
case "$(uname -m)" in
  arm64|aarch64) PLATFORM_ARCH=arm64 ;;
  x86_64|amd64) PLATFORM_ARCH=amd64 ;;
  *) fail 'Supported architectures: arm64 and amd64' ;;
esac

command -v tar >/dev/null 2>&1 || fail 'tar is required'
if [ -n "$LOCAL_ARCHIVE" ]; then
  [ -f "$LOCAL_ARCHIVE" ] || fail "Archive not found: $LOCAL_ARCHIVE"
  ASSET_NAME="$(basename "$LOCAL_ARCHIVE")"
  ASSET_SUFFIX="_${PLATFORM_OS}_${PLATFORM_ARCH}.tar.gz"
  case "$ASSET_NAME" in
    opsd_*"$ASSET_SUFFIX") ;;
    *) fail "Expected an OPSd archive for ${PLATFORM_OS}/${PLATFORM_ARCH}" ;;
  esac
  INSTALL_VERSION="${ASSET_NAME#opsd_}"
  INSTALL_VERSION="${INSTALL_VERSION%"$ASSET_SUFFIX"}"
else
  command -v curl >/dev/null 2>&1 || fail 'curl is required to download releases'
  if [ -z "$INSTALL_VERSION" ]; then
    RELEASE_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$RELEASE_BASE/latest")" || fail 'Cannot resolve the latest release'
    INSTALL_VERSION="${RELEASE_URL##*/}"
  fi
  INSTALL_VERSION="${INSTALL_VERSION#v}"
fi
case "$INSTALL_VERSION" in
  ''|*[!A-Za-z0-9.+-]*) fail 'Invalid release version' ;;
esac
ASSET_NAME="opsd_${INSTALL_VERSION}_${PLATFORM_OS}_${PLATFORM_ARCH}.tar.gz"
BUNDLE_NAME="${ASSET_NAME%.tar.gz}"

# Stage and verify the complete installation before touching the destination.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opsd-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -n "$LOCAL_ARCHIVE" ]; then
  cp "$LOCAL_ARCHIVE" "$STAGING_DIR/$ASSET_NAME"
else
  ASSET_URL="$RELEASE_BASE/download/v$INSTALL_VERSION/$ASSET_NAME"
  printf 'Downloading OPSd %s for %s/%s...\n' "$INSTALL_VERSION" "$PLATFORM_OS" "$PLATFORM_ARCH"
  curl -fsSL "$ASSET_URL" -o "$STAGING_DIR/$ASSET_NAME" || fail "Release asset unavailable: $ASSET_URL"
  curl -fsSL "$ASSET_URL.sha256" -o "$STAGING_DIR/checksum" || fail 'Release checksum unavailable'
  EXPECTED_SHA="$(awk 'NR == 1 { print $1 }' "$STAGING_DIR/checksum")"
  [ "${#EXPECTED_SHA}" -eq 64 ] || fail 'Invalid release checksum'
  case "$EXPECTED_SHA" in *[!0-9a-fA-F]*) fail 'Invalid release checksum' ;; esac
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA="$(sha256sum "$STAGING_DIR/$ASSET_NAME" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    ACTUAL_SHA="$(shasum -a 256 "$STAGING_DIR/$ASSET_NAME" | awk '{print $1}')"
  elif command -v openssl >/dev/null 2>&1; then
    ACTUAL_SHA="$(openssl dgst -sha256 -r "$STAGING_DIR/$ASSET_NAME" | awk '{print $1}')"
  else
    fail 'SHA-256 verification requires sha256sum, shasum, or openssl'
  fi
  [ "$(printf '%s' "$EXPECTED_SHA" | tr 'A-F' 'a-f')" = "$ACTUAL_SHA" ] || fail 'Release checksum mismatch'
fi

# Official archives have one named root. Refuse unexpected paths before extraction.
tar -tzf "$STAGING_DIR/$ASSET_NAME" > "$STAGING_DIR/entries" || fail 'Cannot read the archive'
[ -s "$STAGING_DIR/entries" ] || fail 'The archive is empty'
while IFS= read -r ENTRY; do
  case "$ENTRY" in "$BUNDLE_NAME"|"$BUNDLE_NAME/"*) ;; *) fail "Unexpected archive path: $ENTRY" ;; esac
  case "/$ENTRY/" in */../*) fail "Unexpected archive path: $ENTRY" ;; esac
done < "$STAGING_DIR/entries"
tar -xzf "$STAGING_DIR/$ASSET_NAME" -C "$STAGING_DIR"
BUNDLE_ROOT="$STAGING_DIR/$BUNDLE_NAME"
for REQUIRED_FILE in bin/opsd bin/opsd-mcp runtime/bin/ruby; do
  [ -x "$BUNDLE_ROOT/$REQUIRED_FILE" ] || fail "Incomplete bundle: $REQUIRED_FILE is missing"
done
# The real launcher verifies that the embedded runtime can start on this host.
"$BUNDLE_ROOT/bin/opsd" version >/dev/null || fail 'The bundled runtime could not start'

mkdir -p "$INSTALL_PREFIX"
INSTALL_PREFIX="$(CDPATH= cd -- "$INSTALL_PREFIX" && pwd -P)"
# A unique destination preserves installed versions and avoids partial replacement.
INSTALL_DIR="$(mktemp -d "$INSTALL_PREFIX/install.XXXXXX")"
if ! mv "$BUNDLE_ROOT" "$INSTALL_DIR/$BUNDLE_NAME"; then
  rmdir "$INSTALL_DIR"
  fail 'Cannot install the bundle'
fi
INSTALLED_ROOT="$INSTALL_DIR/$BUNDLE_NAME"
printf 'Installed OPSd %s in %s\n' "$INSTALL_VERSION" "$INSTALLED_ROOT"
printf 'Run this in your terminal, then continue the setup guide:\n'
# Single-quote the path so printed commands also work with shell metacharacters.
QUOTED_ROOT="$(printf '%s' "$INSTALLED_ROOT" | sed "s/'/'\\\\''/g")"
printf "export OPSD_APP_ROOT='%s'\n" "$QUOTED_ROOT"
printf '"$OPSD_APP_ROOT/bin/opsd" version\n'
