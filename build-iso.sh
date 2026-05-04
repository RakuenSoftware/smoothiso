#!/bin/bash
# smoothiso — Generic Debian-based installer ISO builder.
#
# Consumed by project wrappers that export the required variables and then
# exec this script. Never called directly.
#
# Required env vars (set by the project wrapper):
#   PRODUCT_NAME        Display name, e.g. "SmoothNAS"
#   PRODUCT_ID          Slug (no spaces), e.g. "smoothnas"
#   VERSION             ISO version string
#   HOOKS_DIR           Absolute path to the project's hooks/ directory
#   CACHE_DIR           Directory for cached upstream ISOs
#   WORK_DIR            Scratch directory for ISO assembly
#   ISO_OUTPUT_FILE     Full path to write the output .iso
#
# Optional env vars (have defaults):
#   DEBIAN_SUITE        Debian suite, default "trixie"
#   ARCH                Architecture, default "amd64"
#   DEBIAN_MIRROR       Debian mirror, default "http://deb.debian.org/debian"
#   BOOT_MENU_TITLE     Boot menu label, default "${PRODUCT_NAME} Install"
#   ISO_LABEL           ISO volume label, default upper-cased PRODUCT_ID
#   SMOOTHGUI_FRONTEND_DIR      Installer frontend bundle directory
#   SMOOTHGUI_FRONTEND_REQUIRED  Set to 1 to require SmoothGUI at runtime (default: 1)
#   SMOOTHGUI_FRONTEND_PORT      Frontend bind port (default: 8080)
#   SMOOTHGUI_FRONTEND_BIND      Frontend bind address (default: 0.0.0.0)
#   INSTALLER_BROWSER_DEFERRED  Set to 1 to skip embedding browser packages in
#       the initrd and download them from apt at installer startup instead.
#       Requires internet access at install time; eliminates ~300 MB of
#       browser+X11 packages from the initrd so GRUB can load it cleanly.
#       INSTALLER_BROWSER_PKG and INSTALLER_BROWSER_AUX_PKGS control what is
#       downloaded (same variables used for the embedded path).
#   INSTALLER_KERNEL_PACKAGES   Kernel packages installed by install_packages.
#       Default "linux-image-amd64 linux-headers-amd64". Set to "" if the
#       project ships its own kernel and installs it from packages.sh.
#   INSTALLER_KERNEL_DEB        Optional path to a linux-image .deb whose
#       vmlinuz replaces the Debian netinst installer kernel. The deb's
#       /lib/modules tree is also staged in the initrd so the running kernel
#       can find its own modules (GPU drivers, etc.).
#
# Hook interface (all optional — absence is not an error):
#   $HOOKS_DIR/embed.sh
#       Called after standard files are staged into the initrd temp dir.
#       Env: INITRD_TMP (path to temp dir being merged into initrd),
#            HOOKS_DIR, and all config vars above.
#       Use this to embed product binaries / assets into the initrd.
#
# Prerequisites: xorriso, isolinux, cpio, gzip, file, curl, dpkg-deb, gcc
set -euo pipefail

SMOOTHISO_DIR="$(cd "$(dirname "$0")" && pwd)"

: "${PRODUCT_NAME:?PRODUCT_NAME must be set by the project wrapper}"
: "${PRODUCT_ID:?PRODUCT_ID must be set by the project wrapper}"
: "${VERSION:?VERSION must be set by the project wrapper}"
: "${HOOKS_DIR:?HOOKS_DIR must be set by the project wrapper}"
: "${CACHE_DIR:?CACHE_DIR must be set by the project wrapper}"
: "${WORK_DIR:?WORK_DIR must be set by the project wrapper}"
: "${ISO_OUTPUT_FILE:?ISO_OUTPUT_FILE must be set by the project wrapper}"

DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
ARCH="${ARCH:-amd64}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
BOOT_MENU_TITLE="${BOOT_MENU_TITLE:-${PRODUCT_NAME} Install}"
ISO_LABEL="${ISO_LABEL:-$(echo "$PRODUCT_ID" | tr '[:lower:]' '[:upper:]')}"
INSTALLER_KERNEL_DEB="${INSTALLER_KERNEL_DEB:-}"
_INSTALLER_KERNEL_KVER=""
_INSTALLER_KERNEL_MODULES_STAGE=""

# Per-arch knobs. amd64 boots BIOS+UEFI via isolinux + EFI El Torito;
# arm64 has no BIOS so the source ISO ships no /isolinux tree and the
# repacked ISO carries only the EFI El Torito record. MULTIARCH_TRIPLET
# is the lib path used when staging library files into the initrd.
case "$ARCH" in
    amd64)
        MULTIARCH_TRIPLET="x86_64-linux-gnu"
        BIOS_BOOT=1
        ;;
    arm64)
        MULTIARCH_TRIPLET="aarch64-linux-gnu"
        BIOS_BOOT=0
        ;;
    *)
        echo "ERROR: unsupported ARCH '${ARCH}' (expected amd64 or arm64)" >&2
        exit 1
        ;;
esac

DEBIAN_ISO_URL="https://cdimage.debian.org/debian-cd/current/${ARCH}/iso-cd/"

# --- Preflight ---

check_prereqs() {
    local missing=()
    for cmd in xorriso cpio gzip file curl dpkg-deb gcc; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing tools: ${missing[*]}"
        exit 1
    fi
    if [ "$BIOS_BOOT" = "1" ] && [ ! -f /usr/lib/ISOLINUX/isohdpfx.bin ]; then
        echo "ERROR: /usr/lib/ISOLINUX/isohdpfx.bin not found. Install isolinux."
        exit 1
    fi
}

collect_apt_deps() {
    local root_pkg="$1"
    local out_file="$2"
    local -A seen
    local -a queue
    local pkg
    local dep_expr
    local dep

    : > "$out_file"
    queue=("$root_pkg")

    while [ ${#queue[@]} -gt 0 ]; do
        pkg="${queue[0]}"
        queue=("${queue[@]:1}")

        [ -n "${seen["$pkg"]+x}" ] && continue
        seen["$pkg"]=1
        printf '%s\n' "$pkg" >> "$out_file"

    while IFS= read -r dep_expr; do
            dep="${dep_expr%%|*}"
            dep="$(printf '%s\n' "$dep" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            [ -z "$dep" ] && continue
            case "$dep" in
                "<"*">") continue ;;
            esac
            [ -n "${seen["$dep"]+x}" ] || queue+=("$dep")
        done < <(apt-cache depends "$pkg" 2>/dev/null | \
            awk -F': ' '/^  (Depends|Pre-Depends): / {print $2}')
    done

    sort -u "$out_file" -o "$out_file"
}

install_installer_browser() {
    local initrd_tmp="$1"
    local browser_pkg="${INSTALLER_BROWSER_PKG:-firefox-esr}"
    local aux_pkgs="${INSTALLER_BROWSER_AUX_PKGS:-xvfb xinit x11-utils x11-xserver-utils xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-input-evdev xserver-xorg-video-fbdev xserver-xorg-video-vesa xserver-xorg-video-qxl xserver-xorg-video-all xserver-xorg-input-all xfonts-base xfonts-100dpi xfonts-75dpi libegl1 dbus dbus-x11 firmware-linux-free}"

    if [ "${INSTALLER_BROWSER_DEFERRED:-0}" = "1" ]; then
        echo "  INSTALLER_BROWSER_DEFERRED=1: skipping browser embedding; will download at install time."
        return 0
    fi
    local pkg_cache="${CACHE_DIR}/browser-packages"
    local dep_file="${pkg_cache}/deps.txt"
    local selected_file="${pkg_cache}/selected.txt"
    local root_pkgs="${browser_pkg} ${aux_pkgs}"
    local root_pkg

    command -v apt-cache >/dev/null 2>&1 || return 0
    command -v apt-get >/dev/null 2>&1 || return 0

    mkdir -p "$pkg_cache"
    : > "$dep_file"
    for root_pkg in $root_pkgs; do
        local root_dep_file="${pkg_cache}/deps-${root_pkg}.txt"
        if ! collect_apt_deps "$root_pkg" "$root_dep_file"; then
            echo "  WARNING: failed to resolve browser dependency list for ${browser_pkg}; continuing without browser."
            continue
        fi
        cat "$root_dep_file" >> "$dep_file"
    done
    rm -f "${pkg_cache}/deps-"*.txt 2>/dev/null || true
    sort -u "$dep_file" -o "$dep_file"

    : > "$selected_file"
    local -A selected
    local package
    while IFS= read -r package; do
        local targets="${package} ${aux_pkgs}"
        local target
        for target in $targets; do
            [ -z "$target" ] && continue

            shopt -s nullglob
            local matches=(
                ${pkg_cache}/${target}_*.deb
                ${pkg_cache}/${target}-*.deb
            )
            shopt -u nullglob
            if [ "${#matches[@]}" -eq 0 ]; then
                if (cd "$pkg_cache" && apt-get download --quiet "$target"); then
                    :
                else
                    echo "  WARNING: unable to download ${target}; installer browser may be incomplete."
                fi
            fi
            shopt -s nullglob
            matches=(
                ${pkg_cache}/${target}_*.deb
                ${pkg_cache}/${target}-*.deb
            )
            shopt -u nullglob
            for package_file in "${matches[@]}"; do
                selected["$package_file"]=1
            done
        done
    done < "$dep_file"

    if [ -n "$aux_pkgs" ]; then
        local aux
        for aux in $aux_pkgs; do
            shopt -s nullglob
                local aux_matches=(
                ${pkg_cache}/${aux}_*.deb
                ${pkg_cache}/${aux}-*.deb
            )
            shopt -u nullglob
            if [ "${#aux_matches[@]}" -eq 0 ]; then
                if (cd "$pkg_cache" && apt-get download --quiet "$aux"); then
                    :
                else
                    echo "  WARNING: unable to download ${aux}; installer browser may be incomplete."
                fi
            fi

            shopt -s nullglob
            aux_matches=(
                ${pkg_cache}/${aux}_*.deb
                ${pkg_cache}/${aux}-*.deb
            )
            shopt -u nullglob
            for package_file in "${aux_matches[@]}"; do
                selected["$package_file"]=1
            done
        done
    fi
    : > "$selected_file"
    for package_file in "${!selected[@]}"; do
        echo "$package_file" >> "$selected_file"
    done

    if [ ! -s "$selected_file" ]; then
        echo "  WARNING: installer browser dependency cache is empty; installer GUI may not launch."
        return 0
    fi

    # base-files ships only the usr-merge transitional symlinks (./lib ->
    # usr/lib, ./bin -> usr/bin, etc.) and a handful of /etc placeholders.
    # We do not want any of that in the d-i initramfs: the installer needs
    # /lib to remain a real directory so the kernel-module udebs land
    # alongside d-i's existing /lib/modules tree, and the cpio merge step
    # removes-then-replaces directories that disagree with the staging
    # tree (which would also wipe d-i's /lib/modules content). Any other
    # package emitting a ./lib -> usr/lib symlink would have the same
    # effect; tar refuses to write the symlink over an existing real dir
    # and the build aborts. Skip such packages — they exist solely to
    # mark a usr-merged installation.
    shopt -s nullglob
    while IFS= read -r package_file; do
        case "$(basename "$package_file")" in
            base-files_*) continue ;;
        esac
        dpkg-deb -x "$package_file" "$initrd_tmp"
    done < "$selected_file"
    shopt -u nullglob

    if [ -x "${initrd_tmp}/usr/bin/${browser_pkg}" ] || \
       [ -x "${initrd_tmp}/usr/bin/firefox" ]; then
        echo "  Installed installer browser package(s) from ${browser_pkg}."
    else
        echo "  WARNING: installer browser package ${browser_pkg} not available after embedding; installer GUI may not launch."
    fi

    # Firefox enterprise policy: suppress first-run / telemetry / data
    # collection prompts so the kiosk loads straight to the installer URL
    # without a modal overlay. Firefox-ESR reads /etc/firefox/policies/.
    local policies_dir="${initrd_tmp}/etc/firefox/policies"
    mkdir -p "$policies_dir"
    cat > "${policies_dir}/policies.json" << 'POLICIES'
{
  "policies": {
    "DisableAppUpdate": true,
    "DisableFirefoxStudies": true,
    "DisableTelemetry": true,
    "DisableFeedbackCommands": true,
    "DisableProfileImport": true,
    "DisableFirefoxAccounts": true,
    "DisablePocket": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "PasswordManagerEnabled": false,
    "PromptForDownloadLocation": false,
    "NetworkPrediction": false,
    "OfferToSaveLogins": false,
    "DNSOverHTTPS": { "Enabled": false }
  }
}
POLICIES
}

install_full_busybox() {
    local initrd_tmp="$1"
    local cache_dir="${CACHE_DIR}/busybox-packages"
    local busybox_pkg=""
    local busybox_deb=""

    if ! command -v apt >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p "$cache_dir"

    for busybox_pkg in busybox-static busybox; do
        local extracted busybox_tmp
        local -a candidates=()

        shopt -s nullglob
        candidates=(
            ${cache_dir}/${busybox_pkg}_*${ARCH}.deb
            ${cache_dir}/${busybox_pkg}_*.deb
            ${cache_dir}/${busybox_pkg}-*.deb
        )
        shopt -u nullglob

        if [ "${#candidates[@]}" -eq 0 ]; then
            (cd "$cache_dir" && apt download "$busybox_pkg" >/dev/null 2>&1) || {
                continue
            }
            shopt -s nullglob
            candidates=(
                ${cache_dir}/${busybox_pkg}_*${ARCH}.deb
                ${cache_dir}/${busybox_pkg}_*.deb
                ${cache_dir}/${busybox_pkg}-*.deb
            )
            shopt -u nullglob
            [ "${#candidates[@]}" -eq 0 ] && continue
        fi

        busybox_deb="${candidates[0]}"
        extracted="$(mktemp -d)"
        dpkg-deb -x "$busybox_deb" "$extracted/pkg"
        if [ -x "$extracted/pkg/usr/bin/busybox" ] && \
            "$extracted/pkg/usr/bin/busybox" --list 2>/dev/null | grep -q '^httpd$'; then
            mkdir -p "${initrd_tmp}/usr/bin"
            cp "$extracted/pkg/usr/bin/busybox" "${initrd_tmp}/usr/bin/busybox"
            chmod +x "${initrd_tmp}/usr/bin/busybox"
            rm -rf "$extracted"
            echo "  Installed BusyBox ${busybox_pkg} (httpd enabled)."
            return 0
        fi
        rm -rf "$extracted"
    done

    echo "  WARNING: unable to embed a BusyBox build with httpd support."
    return 0
}

# --- Download ---

download_iso() {
    mkdir -p "$CACHE_DIR"
    local cached="${CACHE_DIR}/debian-netinst.iso"
    if [ -f "$cached" ]; then
        echo "Using cached: $cached" >&2
        echo "$cached"; return
    fi
    echo "Finding latest Debian ${DEBIAN_SUITE} netinst (${ARCH})..." >&2
    local name
    name=$(curl -sL "$DEBIAN_ISO_URL" \
        | grep -oP "href=\"debian-[0-9.]+-${ARCH}-netinst\\.iso\"" \
        | head -1 | tr -d '"' | sed 's/href=//')
    [ -z "$name" ] && { echo "ERROR: Cannot find netinst ISO" >&2; exit 1; }
    echo "Downloading $name..." >&2
    curl -fSL -o "$cached" "${DEBIAN_ISO_URL}${name}"
    echo "$cached"
}

# --- Extract only what we need from the ISO ---

extract_iso() {
    local src="$1"
    echo "Extracting boot files from ISO..."
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"

    local install_dir=""
    local candidate
    local listing
    listing=$(xorriso -indev "$src" -ls / 2>/dev/null | sed "s/^[[:space:]]*'\\([^']*\\)'.*$/\\1/")
    # Debian historically uses a short-name install dir per arch:
    #   amd64 -> /install.amd, arm64 -> /install.a64.
    local arch_short
    case "$ARCH" in
        amd64) arch_short="amd" ;;
        arm64) arch_short="a64" ;;
        *)     arch_short="$ARCH" ;;
    esac
    for candidate in "/install.${ARCH}" "/install.${arch_short}" "/install"; do
        if echo "$listing" | rg -q "^${candidate#/}$"; then
            install_dir="$candidate"
            break
        fi
    done
    if [ -z "$install_dir" ]; then
        echo "ERROR: Cannot find installer directory on source ISO."
        exit 1
    fi

    local tmp_pool
    tmp_pool=$(mktemp -d)

    local -a extract_args=(
        -osirrox on -indev "$src"
        -extract "$install_dir" "$WORK_DIR/install.${ARCH}"
        -extract /boot          "$WORK_DIR/boot"
        -extract /EFI           "$WORK_DIR/EFI"
        -extract /.disk         "$WORK_DIR/.disk"
        -extract /pool          "$tmp_pool/pool"
    )
    # /isolinux only exists on the BIOS-bootable amd64 netinst.
    if [ "$BIOS_BOOT" = "1" ]; then
        extract_args+=(-extract /isolinux "$WORK_DIR/isolinux")
    fi
    xorriso "${extract_args[@]}" 2>&1

    chmod -R u+w "$WORK_DIR"
    chmod -R u+w "$tmp_pool"

    POOL_DIR="$tmp_pool/pool"
}

# --- Optionally replace installer kernel with a project-supplied .deb ---

replace_installer_kernel() {
    [ -z "$INSTALLER_KERNEL_DEB" ] && return 0
    echo "Replacing installer kernel with $(basename "$INSTALLER_KERNEL_DEB")..."
    local kextract
    kextract=$(mktemp -d)
    dpkg-deb -x "$INSTALLER_KERNEL_DEB" "$kextract"

    local vmlinuz
    vmlinuz=$(find "$kextract/boot" -name "vmlinuz-*" -type f | head -1)
    if [ -z "$vmlinuz" ]; then
        echo "ERROR: No vmlinuz found in $(basename "$INSTALLER_KERNEL_DEB")" >&2
        rm -rf "$kextract"
        exit 1
    fi
    _INSTALLER_KERNEL_KVER=$(basename "$vmlinuz" | sed 's/^vmlinuz-//')
    local kmod_src="$kextract/lib/modules/$_INSTALLER_KERNEL_KVER"
    if [ ! -d "$kmod_src" ]; then
        echo "ERROR: No modules directory for $_INSTALLER_KERNEL_KVER in $(basename "$INSTALLER_KERNEL_DEB")" >&2
        rm -rf "$kextract"
        exit 1
    fi

    cp "$vmlinuz" "$WORK_DIR/install.${ARCH}/vmlinuz"
    echo "  Installer vmlinuz: $_INSTALLER_KERNEL_KVER"

    _INSTALLER_KERNEL_MODULES_STAGE=$(mktemp -d)
    cp -a "$kmod_src/." "$_INSTALLER_KERNEL_MODULES_STAGE/"
    rm -rf "$kextract"
    echo "  Staged $(find "$_INSTALLER_KERNEL_MODULES_STAGE" -name '*.ko*' | wc -l) kernel modules."
}

# --- Stage installer files and kernel modules into initrd ---

setup_initrd() {
    echo "Injecting modules + installer + hooks into initrd..."
    local tmp
    tmp=$(mktemp -d)

    # Mirror the d-i initramfs layout: trixie's d-i is usr-merged,
    # so /lib, /bin, /sbin are symlinks to usr/{lib,bin,sbin}. Create
    # the same symlinks in our staging tree before anything else
    # writes to /lib — otherwise mkdir / cp would create /lib as a
    # real directory and the cpio merge step would later try to copy
    # that directory onto the d-i symlink and abort.
    mkdir -p "${tmp}/usr/lib" "${tmp}/usr/bin" "${tmp}/usr/sbin"
    ln -sf usr/lib "${tmp}/lib"
    ln -sf usr/bin "${tmp}/bin"
    ln -sf usr/sbin "${tmp}/sbin"

    # Extract hardware modules from udebs.
    local udeb_patterns=(
        "scsi-core-modules-*-${ARCH}-di_*.udeb"
        "scsi-modules-*-${ARCH}-di_*.udeb"
        "sata-modules-*-${ARCH}-di_*.udeb"
        "nic-modules-*-${ARCH}-di_*.udeb"
        "nic-shared-modules-*-${ARCH}-di_*.udeb"
        "pata-modules-*-${ARCH}-di_*.udeb"
        "md-modules-*-${ARCH}-di_*.udeb"
        "multipath-modules-*-${ARCH}-di_*.udeb"
        "ext4-modules-*-${ARCH}-di_*.udeb"
        "dm-modules-*-${ARCH}-di_*.udeb"
        "usb-storage-modules-*-${ARCH}-di_*.udeb"
    )

    for pattern in "${udeb_patterns[@]}"; do
        local udeb
        udeb=$(find "${POOL_DIR}" -name "$pattern" | head -1)
        if [ -n "$udeb" ]; then
            echo "  Extracting modules from $(basename "$udeb")..."
            local udeb_tmp
            udeb_tmp=$(mktemp -d)
            dpkg-deb -x "$udeb" "$udeb_tmp"

            local kver
            kver=$(find "$udeb_tmp/lib/modules" -maxdepth 1 -mindepth 1 -type d \
                -printf '%f\n' 2>/dev/null | head -1)
            if [ -n "$kver" ]; then
                # Stage at /lib/modules (modprobe's only search path).
                # The browser packages already laid down a usr-merged
                # `lib -> usr/lib` symlink earlier, so we cannot extract
                # the udeb directly with dpkg-deb (tar refuses to write
                # through the directory symlink). cp follows the symlink,
                # so files land at the resolved /usr/lib/modules path
                # while the /lib/modules symlink keeps modprobe happy.
                mkdir -p "${tmp}/lib/modules/${kver}"
                cp -a --no-clobber -r "$udeb_tmp/lib/modules/${kver}/." \
                    "${tmp}/lib/modules/${kver}/" 2>/dev/null || true
            fi

            rm -rf "$udeb_tmp"
        fi
    done

    if [ -n "$_INSTALLER_KERNEL_KVER" ] && [ -d "$_INSTALLER_KERNEL_MODULES_STAGE" ]; then
        echo "  Staging custom installer kernel modules ($_INSTALLER_KERNEL_KVER)..."
        mkdir -p "${tmp}/lib/modules/$_INSTALLER_KERNEL_KVER"
        cp -a "$_INSTALLER_KERNEL_MODULES_STAGE/." "${tmp}/lib/modules/$_INSTALLER_KERNEL_KVER/"
    fi

    # Partitioning and filesystem tools.
    echo "  Extracting partitioning tools from pool..."
    local pkg_tmp
    pkg_tmp=$(mktemp -d)

    # Helper: extract a deb/udeb into pkg_tmp, copy binaries/libs to $tmp.
    extract_bins() {
        local deb="$1"; shift
        dpkg-deb -x "$deb" "$pkg_tmp/pkg"
        for bin in "$@"; do
            local src
            src=$(find "$pkg_tmp/pkg" -name "$bin" -type f | head -1)
            if [ -n "$src" ]; then
                mkdir -p "${tmp}/usr/sbin"
                cp "$src" "${tmp}/usr/sbin/${bin}"
                chmod +x "${tmp}/usr/sbin/${bin}"
            fi
        done
        find "$pkg_tmp/pkg" -name '*.so*' -type f | while read -r lib; do
            mkdir -p "${tmp}/usr/lib/${MULTIARCH_TRIPLET}"
            cp "$lib" "${tmp}/usr/lib/${MULTIARCH_TRIPLET}/"
        done
        if [ -d "$pkg_tmp/pkg/usr/sbin" ]; then
            find "$pkg_tmp/pkg/usr/sbin" -type l | while read -r link; do
                local name target
                name=$(basename "$link")
                target=$(readlink "$link")
                mkdir -p "${tmp}/usr/sbin"
                ln -sf "$target" "${tmp}/usr/sbin/${name}"
            done || true
        fi
        find "$pkg_tmp/pkg" -path '*/lib/*' -type l 2>/dev/null | while read -r link; do
            local name target
            name=$(basename "$link")
            target=$(readlink "$link")
            mkdir -p "${tmp}/usr/lib/${MULTIARCH_TRIPLET}"
            ln -sf "$target" "${tmp}/usr/lib/${MULTIARCH_TRIPLET}/${name}"
        done || true
        rm -rf "$pkg_tmp/pkg"
    }

    local lvm_udeb; lvm_udeb=$(find "${POOL_DIR}" -name 'lvm2-udeb_*.udeb' | head -1)
    [ -n "$lvm_udeb" ] && extract_bins "$lvm_udeb" lvm

    local libaio_udeb; libaio_udeb=$(find "${POOL_DIR}" -name 'libaio1-udeb_*.udeb' | head -1)
    [ -n "$libaio_udeb" ] && extract_bins "$libaio_udeb"

    local dm_udeb; dm_udeb=$(find "${POOL_DIR}" -name 'libdevmapper*-udeb_*.udeb' | head -1)
    [ -n "$dm_udeb" ] && extract_bins "$dm_udeb"

    # dmsetup is required so partition_single can rebuild /dev/mapper/* and
    # /dev/${VG}/${LV} when the d-i initrd ships without LVM udev rules.
    local dmsetup_udeb; dmsetup_udeb=$(find "${POOL_DIR}" -name 'dmsetup-udeb_*.udeb' | head -1)
    [ -n "$dmsetup_udeb" ] && extract_bins "$dmsetup_udeb" dmsetup

    local mdadm_udeb; mdadm_udeb=$(find "${POOL_DIR}" -name 'mdadm-udeb_*.udeb' | head -1)
    [ -n "$mdadm_udeb" ] && extract_bins "$mdadm_udeb" mdadm

    local e2fs_udeb; e2fs_udeb=$(find "${POOL_DIR}" -name 'e2fsprogs-udeb_*.udeb' | head -1)
    [ -n "$e2fs_udeb" ] && extract_bins "$e2fs_udeb" mke2fs

    local libext2_deb; libext2_deb=$(find "${POOL_DIR}" -name 'libext2fs2t64_*.deb' | head -1)
    [ -n "$libext2_deb" ] && extract_bins "$libext2_deb"

    local libcomerr_deb; libcomerr_deb=$(find "${POOL_DIR}" -name 'libcom-err2_*.deb' | head -1)
    [ -n "$libcomerr_deb" ] && extract_bins "$libcomerr_deb"

    local fat_udeb; fat_udeb=$(find "${POOL_DIR}" -name 'dosfstools-udeb_*.udeb' | head -1)
    [ -n "$fat_udeb" ] && extract_bins "$fat_udeb" mkfs.fat
    mkdir -p "${tmp}/usr/sbin"
    ln -sf mkfs.fat "${tmp}/usr/sbin/mkfs.vfat"

    local utillinux_deb; utillinux_deb=$(find "${POOL_DIR}" -name 'util-linux_*.deb' | head -1)
    if [ -n "$utillinux_deb" ]; then
        dpkg-deb -x "$utillinux_deb" "$pkg_tmp/pkg"
        [ -f "$pkg_tmp/pkg/usr/sbin/wipefs" ] && \
            cp "$pkg_tmp/pkg/usr/sbin/wipefs" "${tmp}/usr/sbin/" && \
            chmod +x "${tmp}/usr/sbin/wipefs"
        rm -rf "$pkg_tmp/pkg"
    fi

    local libstdcpp_deb; libstdcpp_deb=$(find "${POOL_DIR}" -name 'libstdc++6_*.deb' | head -1)
    [ -n "$libstdcpp_deb" ] && extract_bins "$libstdcpp_deb"

    local gdisk_deb="${CACHE_DIR}/gdisk.deb"
    if [ ! -f "$gdisk_deb" ]; then
        echo "  Downloading gdisk..."
        local gdisk_url="http://deb.debian.org/debian/pool/main/g/gdisk/"
        local gdisk_name
        gdisk_name=$(curl -sL "$gdisk_url" \
            | grep -oP "href=\"gdisk_[^\"]*_${ARCH}\\.deb\"" \
            | tail -1 | tr -d '"' | sed 's/href=//')
        if [ -n "$gdisk_name" ]; then
            curl -fsSL -o "$gdisk_deb" "${gdisk_url}${gdisk_name}"
        fi
    fi
    [ -f "$gdisk_deb" ] && extract_bins "$gdisk_deb" sgdisk || \
        echo "  WARNING: gdisk not found, sgdisk will not be available"

    local whiptail_deb; whiptail_deb=$(find "${POOL_DIR}" -name 'whiptail_*.deb' | head -1)
    if [ -n "$whiptail_deb" ]; then
        dpkg-deb -x "$whiptail_deb" "$pkg_tmp/pkg"
        mkdir -p "${tmp}/usr/bin"
        cp "$pkg_tmp/pkg/usr/bin/whiptail" "${tmp}/usr/bin/"
        chmod +x "${tmp}/usr/bin/whiptail"
        rm -rf "$pkg_tmp/pkg"
    else
        echo "  WARNING: whiptail not found, falling back to text prompts"
    fi

    local popt_udeb; popt_udeb=$(find "${POOL_DIR}" \
        -name 'libpopt0-udeb_*.udeb' -o -name 'libpopt0_*.deb' | head -1)
    [ -n "$popt_udeb" ] && extract_bins "$popt_udeb"

    install_full_busybox "$tmp"
    install_installer_browser "$tmp"

    rm -rf "$pkg_tmp"

    # Bundle debootstrap.
    local dbs_udeb
    dbs_udeb=$(find "${POOL_DIR}" -name 'debootstrap-udeb_*_all.udeb' | head -1)
    if [ -n "$dbs_udeb" ]; then
        echo "  Bundling debootstrap from $(basename "$dbs_udeb")..."
        dpkg-deb -x "$dbs_udeb" "$tmp"
    fi

    # Compile pkgdetails (required by debootstrap).
    echo "  Building pkgdetails..."
    local pkgdetails_src="/tmp/pkgdetails.c"
    curl -fsSL \
        "https://salsa.debian.org/installer-team/base-installer/-/raw/master/pkgdetails.c" \
        -o "$pkgdetails_src"
    mkdir -p "${tmp}/usr/lib/debootstrap"
    if gcc -static -o "${tmp}/usr/lib/debootstrap/pkgdetails" "$pkgdetails_src"; then
        echo "  pkgdetails compiled successfully"
    else
        echo "  WARNING: pkgdetails compile failed -- debootstrap will need perl"
    fi
    rm -f "$pkgdetails_src"

    # Generic installer and firstboot scripts.
    cp "${SMOOTHISO_DIR}/installer.sh" "${tmp}/smoothiso-installer"
    chmod +x "${tmp}/smoothiso-installer"
    cp "${SMOOTHISO_DIR}/firstboot.sh" "${tmp}/smoothiso-firstboot"
    chmod +x "${tmp}/smoothiso-firstboot"

    # Embed preseed that hands off to the generic installer.
    # Mirror installer output to /dev/ttyS0 so that operators can debug a
    # frozen install via the serial console — /dev/console resolves to
    # /dev/tty0 (last `console=` on the kernel cmdline) which is hidden under
    # Xorg/Firefox once the SmoothGUI kiosk launches, leaving the visible
    # screen useless for diagnostics. Tee handles the case where ttyS0
    # doesn't exist (no serial port) by failing silently to /dev/null.
    cat > "${tmp}/preseed.cfg" << 'PRESEED'
d-i preseed/early_command string sh -c 'exec /smoothiso-installer < /dev/console 2>&1 | tee /dev/ttyS0 > /dev/console'
PRESEED

    # Write the product config file read by the installer at runtime.
    mkdir -p "${tmp}/smoothiso-hooks"
    # Quote INSTALLER_KERNEL_PACKAGES carefully — the project wrapper
    # may set it to the empty string to opt out of Debian's kernel,
    # and we need to preserve that distinction (set-but-empty vs unset)
    # so installer.sh's `${VAR-default}` expansion respects it.
    cat > "${tmp}/smoothiso-hooks/config.sh" << CONF
PRODUCT_NAME="${PRODUCT_NAME}"
PRODUCT_ID="${PRODUCT_ID}"
PRODUCT_HOSTNAME="${PRODUCT_HOSTNAME:-${PRODUCT_ID}}"
VG_NAME="${VG_NAME:-${PRODUCT_ID}-vg}"
ARCH="${ARCH}"
DEBIAN_SUITE="${DEBIAN_SUITE}"
DEBIAN_MIRROR="${DEBIAN_MIRROR}"
DATA_DIR="${DATA_DIR:-/var/lib/${PRODUCT_ID}}"
TLS_DIR="${TLS_DIR:-/etc/${PRODUCT_ID}/tls}"
SMOOTHGUI_FRONTEND_DIR="/smoothiso-ui"
SMOOTHGUI_FRONTEND_REQUIRED="${SMOOTHGUI_FRONTEND_REQUIRED:-1}"
SMOOTHGUI_FRONTEND_PORT="${SMOOTHGUI_FRONTEND_PORT:-8080}"
SMOOTHGUI_FRONTEND_BIND="${SMOOTHGUI_FRONTEND_BIND:-0.0.0.0}"
INSTALLER_KERNEL_PACKAGES="${INSTALLER_KERNEL_PACKAGES-linux-image-${ARCH} linux-headers-${ARCH}}"
INSTALLER_BROWSER_DEFERRED="${INSTALLER_BROWSER_DEFERRED:-0}"
INSTALLER_BROWSER_PKG="${INSTALLER_BROWSER_PKG:-firefox-esr}"
INSTALLER_BROWSER_AUX_PKGS="${INSTALLER_BROWSER_AUX_PKGS:-xvfb xinit x11-utils x11-xserver-utils xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-input-evdev xserver-xorg-video-fbdev xserver-xorg-video-vesa xserver-xorg-video-qxl xserver-xorg-video-all xserver-xorg-input-all xfonts-base xfonts-100dpi xfonts-75dpi libegl1 dbus dbus-x11 firmware-linux-free}"
CONF

    # Copy the project's hooks into the initrd.
    if [ -d "$HOOKS_DIR" ]; then
        for hook in embed.sh packages.sh configure.sh firstboot.sh; do
            if [ -f "${HOOKS_DIR}/${hook}" ]; then
                cp "${HOOKS_DIR}/${hook}" "${tmp}/smoothiso-hooks/${hook}"
                chmod +x "${tmp}/smoothiso-hooks/${hook}"
            fi
        done
    fi

    # Installer frontend assets.
    mkdir -p "${tmp}/smoothiso-ui"
    if [ -n "${SMOOTHGUI_FRONTEND_DIR}" ] && [ -d "${SMOOTHGUI_FRONTEND_DIR}" ]; then
        cp -a "${SMOOTHGUI_FRONTEND_DIR}/." "${tmp}/smoothiso-ui/"
        if [ -f "${tmp}/smoothiso-ui/index.installer.html" ]; then
            cp "${tmp}/smoothiso-ui/index.installer.html" "${tmp}/smoothiso-ui/index.html"
        fi
    elif [ -d "${HOOKS_DIR}/ui" ]; then
        cp -a "${HOOKS_DIR}/ui/." "${tmp}/smoothiso-ui/"
    fi

    # Shared backend bridge scripts.
    cp -a "${SMOOTHISO_DIR}/ui-backend/." "${tmp}/smoothiso-ui-backend/"
    chmod +x "${tmp}/smoothiso-ui-backend/start.sh"
    chmod +x "${tmp}/smoothiso-ui-backend/request" \
             "${tmp}/smoothiso-ui-backend/respond" \
             "${tmp}/smoothiso-ui-backend/status"

    # Call the project embed hook (e.g. to embed product binaries).
    if [ -f "${HOOKS_DIR}/embed.sh" ]; then
        echo "  Running project embed hook..."
        INITRD_TMP="$tmp" bash "${HOOKS_DIR}/embed.sh"
    fi

    # Normalize the usr-merge layout. setup_initrd seeds /lib /bin /sbin
    # as symlinks to the corresponding usr/ directory, but a non-usr-merged
    # .deb extraction (firefox-esr aux deps, partitioning tools, etc.) can
    # clobber the symlink with a real directory, leaving the staging tree
    # in a shape that won't merge into the d-i initrd (which keeps the
    # symlinks). Fold any such directory back into usr/<dir>/ and restore
    # the symlink before the merge.
    for d in lib bin sbin; do
        if [ -d "${tmp}/${d}" ] && [ ! -L "${tmp}/${d}" ]; then
            mkdir -p "${tmp}/usr/${d}"
            cp -a --no-clobber "${tmp}/${d}/." "${tmp}/usr/${d}/" 2>/dev/null || true
            rm -rf "${tmp}/${d}"
            ln -sf "usr/${d}" "${tmp}/${d}"
        fi
    done

    # Merge into stock initrd (extract, overlay, repack).
    local initrd="${WORK_DIR}/install.${ARCH}/initrd.gz"
    local initrd_root
    initrd_root=$(mktemp -d)
    (cd "$initrd_root" && zcat "$initrd" | cpio -id --quiet 2>/dev/null || true)
    cp -a --remove-destination "$tmp"/. "$initrd_root"/
    (cd "$initrd_root" && find . | cpio -o -H newc --quiet 2>/dev/null | gzip) > "$initrd"
    rm -rf "$initrd_root"
    rm -rf "$tmp"

    rm -rf "$(dirname "$POOL_DIR")"
}

# --- Rewrite boot menu ---

setup_boot() {
    echo "Configuring boot menu..."

    if [ "$BIOS_BOOT" = "1" ]; then
        cat > "${WORK_DIR}/isolinux/isolinux.cfg" << EOF
DEFAULT ${PRODUCT_ID}
TIMEOUT 50
PROMPT 1
MENU TITLE ${PRODUCT_NAME} Installer

LABEL ${PRODUCT_ID}
    MENU LABEL ${BOOT_MENU_TITLE}
    MENU DEFAULT
    kernel /install.${ARCH}/vmlinuz
    append auto=true priority=critical file=/preseed.cfg DEBCONF_DEBUG=5 console=ttyS0,115200n8 console=tty0 initrd=/install.${ARCH}/initrd.gz ---

LABEL bootlocal
    MENU LABEL Boot from first hard disk
    localboot 0x80
EOF
    fi

    cat > "${WORK_DIR}/boot/grub/grub.cfg" << EOF
set default=0
set timeout=5
set timeout_style=menu

menuentry "${BOOT_MENU_TITLE}" {
    linux /install.${ARCH}/vmlinuz auto=true priority=critical file=/preseed.cfg DEBCONF_DEBUG=5 console=ttyS0,115200n8 console=tty0 ---
    initrd /install.${ARCH}/initrd.gz
}

menuentry "Boot from first hard disk" {
    set root=(hd0)
    chainloader +1
}
EOF
}

# --- Repack ISO ---

repack_iso() {
    echo "Repacking ISO..."
    mkdir -p "$(dirname "$ISO_OUTPUT_FILE")"

    (cd "$WORK_DIR" && find . -type f ! -name md5sum.txt ! -path './isolinux/*' \
        -exec md5sum {} \; 2>/dev/null) > "${WORK_DIR}/md5sum.txt"

    # ISO 9660 caps the volume label at 32 chars; xorriso aborts with
    # `-volid: Text too long` rather than silently truncating. Build the
    # label here and trim if necessary so any version string is accepted.
    local volid="${ISO_LABEL} ${VERSION}"
    if [ "${#volid}" -gt 32 ]; then
        volid="${volid:0:32}"
    fi

    local -a xorriso_args=(
        -as mkisofs
        -o "$ISO_OUTPUT_FILE"
    )
    if [ "$BIOS_BOOT" = "1" ]; then
        # amd64: hybrid ISO with isolinux BIOS El Torito + EFI El Torito.
        xorriso_args+=(
            -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin
            -c isolinux/boot.cat
            -b isolinux/isolinux.bin
            -no-emul-boot
            -boot-load-size 4
            -boot-info-table
            -eltorito-alt-boot
            -e boot/grub/efi.img
            -no-emul-boot
            -isohybrid-gpt-basdat
        )
    else
        # arm64: no BIOS — EFI-only El Torito record.
        xorriso_args+=(
            -e boot/grub/efi.img
            -no-emul-boot
            -isohybrid-gpt-basdat
        )
    fi
    xorriso_args+=(
        -V "$volid"
        "$WORK_DIR"
    )
    xorriso "${xorriso_args[@]}"

    echo ""
    echo "  ISO: ${ISO_OUTPUT_FILE}"
    echo "  Size: $(du -h "$ISO_OUTPUT_FILE" | cut -f1)"
}

# --- Main ---

main() {
    echo "=== ${PRODUCT_NAME} ISO Builder v${VERSION} ==="
    check_prereqs

    local src
    src=$(download_iso)

    extract_iso "$src"
    replace_installer_kernel
    setup_initrd
    setup_boot
    repack_iso

    [ -n "$_INSTALLER_KERNEL_MODULES_STAGE" ] && rm -rf "$_INSTALLER_KERNEL_MODULES_STAGE"
    rm -rf "$WORK_DIR"
    echo "Done."
}

main
