#!/bin/sh

set -eu

GIT_URL=git@git.lo:yuri

FREEBSD_BRANCH=yuri/14.3-p16_rk3588-overlay
FREEBSD_COMMIT=

UBOOT_BRANCH=yuri/nanopc-t6_lts
UBOOT_COMMIT=

IF_RGE_BRANCH=yuri/14.3
IF_RGE_COMMIT=

RKBIN_BRANCH=master
RKBIN_COMMIT=

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

	if [ ! -e "$dir" ]; then
		git clone "$url" "$dir"
	fi

	if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
		git -C "$dir" remote set-url origin "$url"
	else
		git -C "$dir" remote add origin "$url"
	fi
	git -C "$dir" fetch --prune origin

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
	git -C "$dir" pull --ff-only
}

mkdir -p dtb dts menu txz output src

# Check every existing repository before changing any of them.
check_repo src/freebsd-src
check_repo src/u-boot-2017
check_repo src/rkbin
check_repo src/if_rge_freebsd

sync_repo src/freebsd-src "$GIT_URL/freebsd-src.git" \
	"$FREEBSD_BRANCH" "$FREEBSD_COMMIT"
sync_repo src/u-boot-2017 "$GIT_URL/u-boot-rk3588.git" \
	"$UBOOT_BRANCH" "$UBOOT_COMMIT"
sync_repo src/rkbin "$GIT_URL/rkbin.git" \
	"$RKBIN_BRANCH" "$RKBIN_COMMIT"
sync_repo src/if_rge_freebsd "$GIT_URL/if_rge_freebsd.git" \
	"$IF_RGE_BRANCH" "$IF_RGE_COMMIT"
