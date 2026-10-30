#!/usr/bin/env bash
# Build the public RuyiSDK XuanTie 6.6.36 kernel without CubeSandbox's 7.2 patches.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KERNEL_COMMIT="92c3f5343b3cdfb5b85a9638310b36537acb0c5e"
KERNEL_SHA256="d274f71344c41bd52e17d4ebf20b65cfa5c40dbd46ed17288f0c5bb4ad3522b3"
KERNEL_SRC_URL="https://codeload.github.com/ruyisdk/linux-xuantie-kernel/tar.gz/${KERNEL_COMMIT}"

KERNEL_BUILD_JOBS="${KERNEL_BUILD_JOBS:-$(nproc)}"
WORKLOADS_DIR="${WORKLOADS_DIR:-$PWD}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${WORKLOADS_DIR}/Image}"
KERNEL_CONFIG="${REPO_ROOT}/configs/kernel-oc9.riscv64.config"
BUILD_KERNEL_SH="${REPO_ROOT}/scripts/build-kernel.sh"
CROSS_COMPILE="${KERNEL_CROSS_COMPILE:-riscv64-linux-gnu-}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
PATCHES=(
  "${REPO_ROOT}/configs/patches/riscv64-6.6-kvm-vstimecmp-next-cycles.patch"
  "${REPO_ROOT}/configs/patches/riscv64-6.6-kvm-timer-state-restore.patch"
)

[ -f "${KERNEL_CONFIG}" ] || die "kernel config not found: ${KERNEL_CONFIG}"
[ -f "${BUILD_KERNEL_SH}" ] || die "build-kernel.sh not found: ${BUILD_KERNEL_SH}"
for patch_file in "${PATCHES[@]}"; do
  [ -f "${patch_file}" ] || die "kernel patch not found: ${patch_file}"
done

mkdir -p "${WORK_DIR}"
archive="${WORK_DIR}/linux-xuantie-${KERNEL_COMMIT}.tar.gz"
KERNEL_SRC_DIR="${WORK_DIR}/kernel-source"
BUILD_OUT="${WORK_DIR}/build"

echo "[kernel] download ${KERNEL_SRC_URL}"
curl -fL --retry 3 "${KERNEL_SRC_URL}" -o "${archive}"
printf '%s  %s\n' "${KERNEL_SHA256}" "${archive}" | sha256sum -c -

rm -rf "${KERNEL_SRC_DIR}"
mkdir -p "${KERNEL_SRC_DIR}"
tar -xzf "${archive}" -C "${KERNEL_SRC_DIR}" --strip-components=1
[ -f "${KERNEL_SRC_DIR}/Makefile" ] || die "extracted tree has no Makefile"

# The shared 7.2 config enables Andes AX45MP errata, which generic QEMU does
# not need and whose 6.6.36 implementation has a stale BUILD_BUG_ON.
BUILD_CONFIG="${WORK_DIR}/kernel.config"
cp "${KERNEL_CONFIG}" "${BUILD_CONFIG}"
"${KERNEL_SRC_DIR}/scripts/config" --file "${BUILD_CONFIG}" --disable ERRATA_ANDES

for patch_file in "${PATCHES[@]}"; do
  echo "[kernel] === apply $(basename "${patch_file}") ==="
  patch -p1 -d "${KERNEL_SRC_DIR}" --forward --no-backup-if-mismatch < "${patch_file}"
done

KERNEL_SRC_DIR="${KERNEL_SRC_DIR}" \
KERNEL_TARGET_ARCH=riscv64 \
KERNEL_CROSS_COMPILE="${CROSS_COMPILE}" \
KERNEL_CONFIG="${BUILD_CONFIG}" \
KERNEL_OUTPUT_DIR="${BUILD_OUT}" \
KERNEL_BUILD_JOBS="${KERNEL_BUILD_JOBS}" \
  bash "${BUILD_KERNEL_SH}"

[ -f "${BUILD_OUT}/vmlinux" ] || die "build did not produce ${BUILD_OUT}/vmlinux"

mkdir -p "$(dirname "${OUTPUT_IMAGE}")"
install -D -m 0644 "${BUILD_OUT}/vmlinux" "${OUTPUT_IMAGE}"
magic="$(head -c2 "${OUTPUT_IMAGE}" | tr -d '\0')"
[ "${magic}" = "MZ" ] || die "${OUTPUT_IMAGE} is not a PE Image (magic='${magic}')"
echo "[kernel] OK: ${OUTPUT_IMAGE} (PE magic MZ, $(stat -c%s "${OUTPUT_IMAGE}") bytes)"
