#!/bin/sh
set -eu

TARGET_DIR="${1:?target directory is required}"
OUTPUT_FILE="${2:-${TARGET_DIR}/checksums.txt}"

checksum_file() {
  file="${1}"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}"
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}"
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    checksum="$(openssl dgst -sha256 -r "${file}" | awk '{print $1}')"
    printf '%s  %s\n' "${checksum}" "${file}"
    return
  fi

  echo "No SHA-256 tool found. Install sha256sum, shasum, or openssl." >&2
  exit 1
}

cd "${TARGET_DIR}"

{
  for file in *.tar.gz; do
    [ -f "${file}" ] || continue
    checksum_file "${file}"
  done
} > "${OUTPUT_FILE}"

echo "${OUTPUT_FILE}"
