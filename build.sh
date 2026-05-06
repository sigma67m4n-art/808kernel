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
sudo apt-get install -y git bc build-essential flex bison libssl-dev libelf-dev ccache dos2unix python3 curl jq zip

mkdir -p android-kernel
cd android-kernel

echo "info: cloning latest repo..."
REPO_DIR="$OLDDIR/android-kernel/repo"
git clone https://android.googlesource.com/tools/repo.git repo
export PATH="$REPO_DIR:$PATH"

echo "info: syncing kernel sources... ($KERNEL_BRANCH)"
repo init --depth=1 -u https://android.googlesource.com/kernel/manifest -b "$KERNEL_BRANCH"
repo sync -c -j"$(nproc)" --force-sync --no-tags --no-clone-bundle --current-branch --optimized-fetch
cd common

VERSION=$(awk '/^VERSION/ {print $3}' Makefile)
PATCHLEVEL=$(awk '/^PATCHLEVEL/ {print $3}' Makefile)
SUBLEVEL=$(awk '/^SUBLEVEL/ {print $3}' Makefile)

CLANG_VERSION="r547379" # 20.0.0
CLANG_DIR="$OLDDIR/android-kernel/clang-$CLANG_VERSION"

if [[ ! -d "$CLANG_DIR" ]]; then
	echo "info: downloading aosp clang $CLANG_VERSION..."
	wget --progress=bar:force "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-$CLANG_VERSION.tar.gz" -O "$OLDDIR/android-kernel/clang-$CLANG_VERSION.tar.gz"
	mkdir -p "$CLANG_DIR"
	tar -xzf "$OLDDIR/android-kernel/clang-$CLANG_VERSION.tar.gz" -C "$CLANG_DIR"
	rm "$OLDDIR/android-kernel/clang-$CLANG_VERSION.tar.gz"
fi

export PATH="$CLANG_DIR/bin:$PATH"
echo "info: using $(clang --version | head -1)"

echo "info: applying patches..."
for i in "$OLDDIR"/patch/*; do
    patch -p1 < "$i" || true
done

if [[ -n "$CONFIG_NAME" ]]; then
	echo "info: applying config with override..."
	while IFS= read -r line; do
		[[ -z "$line" || "$line" =~ ^# && ! "$line" =~ is\ not\ set ]] && continue
		if [[ "$line" =~ ^([A-Za-z0-9_]+)= ]]; then
			key="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^#\ ([A-Za-z0-9_]+)\ is\ not\ set ]]; then
			key="${BASH_REMATCH[1]}"
		else
			continue
		fi
		sed -i "/^[#[:space:]]*$key[=[:space:]]/d" "$DEFCONFIG"
		echo "$line" >> "$DEFCONFIG"
	done < "$OLDDIR/config/$CONFIG_NAME"
	echo "info: config applied"
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

KBUILD_BUILD_USER=""
KBUILD_BUILD_HOST=""
export KBUILD_BUILD_USER KBUILD_BUILD_HOST

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

echo "artifact_name=AK3-${KERNEL_UNAME}" >> $GITHUB_OUTPUT
echo "zip_file=${ZIP_FILE}" >> "$GITHUB_OUTPUT"