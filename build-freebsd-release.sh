#!/bin/sh

set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
[ -r "${BUILDER_CONFIG}" ] || {
	echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
	exit 1
}
. "${BUILDER_CONFIG}"

die()
{
	echo "${0##*/}: $*" >&2
	exit 1
}

case "${NO_CLEAN}" in
YES) no_clean_make_arg=WITHOUT_CLEAN=yes ;;
NO) no_clean_make_arg= ;;
*) die "NO_CLEAN must be YES or NO" ;;
esac

[ -f "${FREEBSD_SRC_DIR}/Makefile" ] ||
	die "missing FreeBSD source: ${FREEBSD_SRC_DIR}"
[ -f "${FREEBSD_SRC_DIR}/sys/arm64/conf/${FREEBSD_KERNCONF}" ] ||
	die "missing kernel configuration: ${FREEBSD_KERNCONF}"
[ -z "$(git -C "${FREEBSD_SRC_DIR}" status --porcelain)" ] ||
	die "FreeBSD source has uncommitted changes"
[ "${FREEBSD_SRC_COMMIT}" != unknown ] ||
	die "cannot determine FreeBSD source commit"

for cmd in cp git make sha256; do
	command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
done

mkdir -p "${FREEBSD_OBJ_ROOT}" "${TXZ_ROOT}"

freebsd_make()
{
	env SB="${BUILDER_ROOT}" SB_OBJROOT="${FREEBSD_OBJ_ROOT}/" \
	    make -C "${FREEBSD_SRC_DIR}" \
	    TARGET=arm64 TARGET_ARCH=aarch64 \
	    KERNCONF="${FREEBSD_KERNCONF}" \
	    SRCCONF=/dev/null __MAKE_CONF=/dev/null \
	    WITHOUT_DEBUG_FILES=yes WITHOUT_KERNEL_SYMBOLS=yes \
	    ${no_clean_make_arg} "$@"
}

release_make()
{
	env SB="${BUILDER_ROOT}" SB_OBJROOT="${FREEBSD_OBJ_ROOT}/" \
	    make -C "${FREEBSD_SRC_DIR}/release" \
	    TARGET=arm64 TARGET_ARCH=aarch64 \
	    KERNCONF="${FREEBSD_KERNCONF}" \
	    SRCCONF=/dev/null __MAKE_CONF=/dev/null \
	    WITHOUT_DEBUG_FILES=yes WITHOUT_KERNEL_SYMBOLS=yes \
	    NOPORTS=yes NOSRC=yes NOPKG=yes ${no_clean_make_arg} "$@"
}

commit=${FREEBSD_SRC_COMMIT}
echo "== Building FreeBSD ${commit} with ${FREEBSD_KERNCONF} =="
echo "== NO_CLEAN=${NO_CLEAN} =="
freebsd_make -j"${JOBS}" buildworld buildkernel

echo "== Packaging versioned base and kernel archives =="
release_make clean
release_make obj
release_make -j"${JOBS}" base.txz kernel.txz
release_obj=$(release_make -V .OBJDIR)

[ -f "${release_obj}/base.txz" ] ||
	die "release did not produce ${release_obj}/base.txz"
[ -f "${release_obj}/kernel.txz" ] ||
	die "release did not produce ${release_obj}/kernel.txz"
cp -p "${release_obj}/base.txz" "${BASE_TXZ}"
cp -p "${release_obj}/kernel.txz" "${KERNEL_TXZ}"

sha256 "${BASE_TXZ}" "${KERNEL_TXZ}"
echo "FreeBSD objects: ${FREEBSD_OBJ}"
echo "Release packages: ${TXZ_ROOT}"
