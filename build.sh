#!/usr/bin/env bash
set -euo pipefail

[[ -z "${KERNEL_BRANCH:-}" ]] && {
	echo "error: KERNEL_BRANCH is required"
	exit 1
}

if [ -n "$GITHUB_SHA" ]; then
	SHORT_SHA=$(echo "$GITHUB_SHA" | cut -c1-8)
else
	SHORT_SHA=$(git rev-parse --short=8 HEAD 2>/dev/null || echo "local")
fi

LOCALVERSION="-808kernel-susfs/$SHORT_SHA"
CONFIG_NAME="${CONFIG_NAME:-}"
KERNELSU="${KERNELSU:-}"
KERNELSU_BRANCH="${KERNELSU_BRANCH:-}"
SUSFS="${SUSFS:-}"

OLDDIR="$(pwd)"
DEFCONFIG="arch/arm64/configs/gki_defconfig"

sudo apt-get update -qq
sudo apt-get install -y git repo bc build-essential flex bison libssl-dev libelf-dev ccache dos2unix python3 curl jq zip

mkdir -p android-kernel
cd android-kernel

echo "info: syncing kernel sources... ($KERNEL_BRANCH)"
repo init --depth=1 -u https://android.googlesource.com/kernel/manifest -b "$KERNEL_BRANCH"
repo sync -c -j"$(nproc)" --force-sync --no-tags --no-clone-bundle --current-branch --optimized-fetch
cd common

VERSION=$(awk '/^VERSION/ {print $3}' Makefile)
PATCHLEVEL=$(awk '/^PATCHLEVEL/ {print $3}' Makefile)
SUBLEVEL=$(awk '/^SUBLEVEL/ {print $3}' Makefile)

CLANG_DIR="$OLDDIR/android-kernel/clang-stable"

if [[ ! -d "$CLANG_DIR" ]]; then
	echo "info: cloning clang-stable..."
	git clone --depth=1 \
		"https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86" \
		--filter=blob:none \
		--sparse \
		"$OLDDIR/android-kernel/clang-repo"
	cd "$OLDDIR/android-kernel/clang-repo"
	git sparse-checkout set clang-stable
	mv clang-stable "$CLANG_DIR"
	cd "$OLDDIR/android-kernel/common"
fi

export PATH="$CLANG_DIR/bin:$PATH"
echo "info: using $(clang --version | head -1)"

echo "info: applying patches..."
for i in "$OLDDIR"/patch/*; do
    patch -p1 < "$i"
done

if [[ -n "$CONFIG_NAME" ]]; then
	echo "info: applying config..."
	cat "$OLDDIR/config/$CONFIG_NAME" >>"$DEFCONFIG"
fi

if [[ -n "$LOCALVERSION" ]]; then
	echo "info: applying localversion..."
	sed -i '/^CONFIG_LOCALVERSION=/d' "$DEFCONFIG"
	echo "CONFIG_LOCALVERSION=\"$LOCALVERSION\"" >>"$DEFCONFIG"
	echo "CONFIG_LOCALVERSION_AUTO=n" >>"$DEFCONFIG"
fi

if [[ -n "$KERNELSU" ]]; then
	echo "info: applying kernelsu..."
	GITHUB_REPO=$(sed 's|https\?://github\.com/||g; s|\.git||g' <<<"$KERNELSU")
	SETUP_URL="https://raw.githubusercontent.com/$GITHUB_REPO/refs/heads/main/kernel/setup.sh"
	curl -LSs "$SETUP_URL" | bash ${KERNELSU_BRANCH:+-s "$KERNELSU_BRANCH"}
fi

if [[ -n "$SUSFS" ]]; then
	echo "info: applying susfs..."
	SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu"
	SUSFS_BRANCH=$(echo "$KERNEL_BRANCH" | sed 's/common/gki/; s/-lts//')
	SUSFS_BRANCH=$(git ls-remote --heads "$SUSFS_REPO" | awk -F'refs/heads/' '{print $2}' | grep "$SUSFS_BRANCH" | grep -v '\-dev' | tail -1 || true)

	if [[ -z "$SUSFS_BRANCH" ]]; then
		echo "warning: no valid susfs branch found for your kernel, skipping..."
	else
		git clone --depth=1 "$SUSFS_REPO" -b "$SUSFS_BRANCH" .susfs
		KERNEL_PATCHES=".susfs/kernel_patches"
		cp -r "$KERNEL_PATCHES/fs/." ./fs/
		cp -r "$KERNEL_PATCHES/include/." ./include/
		for i in "$KERNEL_PATCHES"/*.patch; do
			[[ -f "$i" ]] || continue
			patch -p1 <"$i"
		done
	fi
fi

sed -i 's/check_defconfig//' build.config.gki

cd ..

echo "info: building kernel..."

LTO=thin OUT_DIR="$OLDDIR/android-kernel/out" BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh -j"$(nproc)"

OUT_PATH=$(find "$OLDDIR/android-kernel/out" -name "Image" -type f | head -1)
[[ -z "$OUT_PATH" ]] && {
	echo "error: Image not found in out dir"
	exit 1
}
OUT_DIR="$(dirname "$OUT_PATH")"

change_kernel_string() {
	sed -i "s|kernel.string=.*|kernel.string=$1|" "$2"
}

echo "info: packaging with AnyKernel3..."

AK3_DIR="$OLDDIR/anykernel3"
[[ ! -d "$AK3_DIR" ]] && {
	echo "error: anykernel3 folder not found at $AK3_DIR"
	exit 1
}

cp "$OUT_DIR/Image" "$AK3_DIR/Image"

KERNEL_UNAME="$VERSION.$PATCHLEVEL.$SUBLEVEL${LOCALVERSION:+$LOCALVERSION}"
ARTIFACT_NAME="AK3-$KERNEL_UNAME"

change_kernel_string "$KERNEL_UNAME" "$AK3_DIR/anykernel.sh"

sed -i "/# boot install/i\\
case \\\$(uname -r) in\\
	$VERSION.$PATCHLEVEL.*) ;;\\
	*) echo \"Not supported\"; exit 1 ;;\\
esac


" "$AK3_DIR/anykernel.sh"

ARTIFACT_DIR="$OLDDIR/$ARTIFACT_NAME"
mkdir -p "$ARTIFACT_DIR"

cp -r "$AK3_DIR"/* "$ARTIFACT_DIR/"

ZIP_FILE="$OLDDIR/$ARTIFACT_NAME.zip"
cd "$ARTIFACT_DIR"
zip -r "$ZIP_FILE" . -x "*.git*" > /dev/null
cd "$OLDDIR"

BRANCH_NAME="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')}"
CI_NUMBER="${GITHUB_RUN_NUMBER:-1}"
COMMIT_MSG=$(git log -1 --pretty=%B 2>/dev/null | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
WORKFLOW_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-0}"

curl -F "chat_id=-100$CHAT_ID" \
     -F "document=@$ZIP_FILE" \
     -F "caption=Branch: $BRANCH_NAME%0A#ci_$CI_NUMBER%0A%0A\`\`\`%0A$COMMIT_MSG%0A\`\`\`%0A%0A[Workflow]($WORKFLOW_URL)" \
     -F "parse_mode=Markdown" \
     "https://api.telegram.org/bot$TOKEN/sendDocument"