#!/bin/sh

set -eu

BUILDER_ROOT=${BUILDER_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
BUILDER_CONFIG=${BUILDER_CONFIG:-${BUILDER_ROOT}/builder.conf}
[ -r "${BUILDER_CONFIG}" ] || {
	echo "${0##*/}: missing config: ${BUILDER_CONFIG}" >&2
	exit 1
}
. "${BUILDER_CONFIG}"

check_repo()
{
	dir=$1
	[ -e "$dir" ] || return 0

	if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		echo "error: $dir exists but is not a Git repository" >&2
		exit 1
	fi

	if [ -n "$(git -C "$dir" status --porcelain)" ]; then
		echo "error: $dir has uncommitted changes" >&2
		git -C "$dir" status --short >&2
		exit 1
	fi
}

sync_repo()
{
	dir=$1
	url=$2
	branch=$3
	commit=$4
	depth=${5:-}

	if [ ! -e "$dir" ]; then
		if [ -n "$depth" ]; then
			git clone --depth "$depth" --branch "$branch" "$url" "$dir"
		else
			git clone "$url" "$dir"
		fi
	fi

	if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
		git -C "$dir" remote set-url origin "$url"
	else
		git -C "$dir" remote add origin "$url"
	fi
	if [ -n "$depth" ]; then
		git -C "$dir" fetch --depth "$depth" --prune origin \
			"${commit:-$branch}"
	else
		git -C "$dir" fetch --prune origin
	fi

	if [ -n "$commit" ]; then
		git -C "$dir" reset --hard "$commit"
		return
	fi

	if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
		git -C "$dir" checkout "$branch"
	else
		git -C "$dir" checkout -b "$branch" --track "origin/$branch"
	fi
	git -C "$dir" branch --set-upstream-to="origin/$branch" "$branch"
	if [ -n "$depth" ]; then
		git -C "$dir" merge --ff-only "origin/$branch"
	else
		git -C "$dir" pull --ff-only
	fi
}

mkdir -p "${WORK_ROOT}" "${OUTPUT_ROOT}" "${SRC_ROOT}"

# Check every existing repository before changing any of them.
check_repo "${FREEBSD_SRC_DIR}"
check_repo "${UBOOT_SRC_DIR}"
check_repo "${RKBIN_SRC_DIR}"
check_repo "${IF_RGE_SRC_DIR}"
check_repo "${DEVICETREE_REBASING_SRC_DIR}"

sync_repo "${FREEBSD_SRC_DIR}" "$GIT_URL/freebsd-src.git" \
	"$FREEBSD_BRANCH" "$FREEBSD_COMMIT"
sync_repo "${UBOOT_SRC_DIR}" "${UBOOT_URL}" \
	"$UBOOT_BRANCH" "$UBOOT_COMMIT"
sync_repo "${RKBIN_SRC_DIR}" "$GIT_URL/rkbin.git" \
	"$RKBIN_BRANCH" "$RKBIN_COMMIT"
sync_repo "${IF_RGE_SRC_DIR}" "$GIT_URL/if_rge_freebsd.git" \
	"$IF_RGE_BRANCH" "$IF_RGE_COMMIT"
sync_repo "${DEVICETREE_REBASING_SRC_DIR}" "$DEVICETREE_REBASING_URL" \
	"$DEVICETREE_REBASING_BRANCH" "$DEVICETREE_REBASING_COMMIT" \
	"$DEVICETREE_REBASING_DEPTH"
