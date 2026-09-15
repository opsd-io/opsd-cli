#!/bin/sh
set -eu

APP_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
DIST_DIR="${1:-${APP_ROOT}/dist}"
TAG="${CI_COMMIT_TAG:-}"

[ "${CI_COMMIT_REF_PROTECTED:-false}" = "true" ] || {
  echo "Release consistency: release tags must be protected" >&2
  exit 1
}

case "${TAG}" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Release consistency: CI_COMMIT_TAG must be a vX.Y.Z tag, got '${TAG}'" >&2; exit 1 ;;
esac

VERSION="${TAG#v}"
echo "${VERSION}" | ruby --disable-gems -e 'abort unless /\A\d+\.\d+\.\d+\z/.match?(STDIN.read.strip)'
SOURCE_VERSION="$(ruby --disable-gems -I"${APP_ROOT}/lib" -ropsd/version -e 'puts OPSd::VERSION')"
[ "${SOURCE_VERSION}" = "${VERSION}" ] || {
  echo "Release consistency: source version ${SOURCE_VERSION} does not match tag ${VERSION}" >&2
  exit 1
}

grep -Eq "^## ${VERSION}([[:space:]]|-|$)" "${APP_ROOT}/CHANGELOG.md" || {
  echo "Release consistency: CHANGELOG.md has no entry for ${VERSION}" >&2
  exit 1
}

expected_archives="opsd_${VERSION}_linux_amd64.tar.gz opsd_${VERSION}_darwin_arm64.tar.gz"
for archive in ${expected_archives}; do
  archive_path="${DIST_DIR}/${archive}"
  [ -f "${archive_path}" ] || { echo "Release consistency: missing ${archive}" >&2; exit 1; }

  extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/opsd-release-XXXXXX")"
  tar -xzf "${archive_path}" -C "${extract_dir}"
  bundle_root="${extract_dir}/${archive%.tar.gz}"
  [ -f "${bundle_root}/release.json" ] || { echo "Release consistency: ${archive} has no release.json" >&2; exit 1; }

  os_arch="${archive#opsd_${VERSION}_}"
  os="${os_arch%_*}"
  arch="${os_arch#*_}"
  ruby --disable-gems -rjson -e '
    metadata = JSON.parse(File.read(ARGV.fetch(0)))
    expected = { "version" => ARGV.fetch(1), "os" => ARGV.fetch(2), "arch" => ARGV.fetch(3) }
    abort "Release consistency: metadata mismatch" unless expected.all? { |key, value| metadata[key] == value }
  ' "${bundle_root}/release.json" "${VERSION}" "${os}" "${arch}"

  rm -rf "${bundle_root}/runtime"
  bundle_version="$(RUBY_BIN=ruby "${bundle_root}/bin/opsd" version)"
  [ "${bundle_version}" = "${VERSION}" ] || {
    echo "Release consistency: ${archive} reports ${bundle_version}, expected ${VERSION}" >&2
    exit 1
  }
  rm -rf "${extract_dir}"
done

echo "Release consistency passed for ${TAG}."
