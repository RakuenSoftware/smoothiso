#!/bin/sh
# smoothiso Generic Installer
# Runs as early_command from the Debian installer initrd.
#
# Reads product config from /smoothiso-hooks/config.sh (written by build-iso.sh).
# Project-specific behaviour is injected via hooks in /smoothiso-hooks/:
#   packages.sh  — sourced after base packages; installs product packages
#   configure.sh — sourced after generic system config; installs product services
#
# Flow:
#   1. Environment (mount /proc /sys /dev, load modules)
#   2. Network (DHCP with manual fallback)
#   3. Clock sync (NTP, HTTP Date fallback)
#   4. Disk selection (whiptail checklist)
#   5. Password prompt
#   6. Partition + format (single-disk LVM or RAID-1 + LVM)
#   7. Install base system (debootstrap)
#   8. Install packages
#   9. Configure system
#  10. Install GRUB
#  11. Prompt to remove media, reboot
set -e

# Load product config injected by build-iso.sh.
if [ -f /smoothiso-hooks/config.sh ]; then
    . /smoothiso-hooks/config.sh
fi

TARGET="/mnt/target"
PRODUCT_NAME="${PRODUCT_NAME:-Linux}"
PRODUCT_ID="${PRODUCT_ID:-linux}"
HOSTNAME="${PRODUCT_HOSTNAME:-${PRODUCT_ID}}"
VG_NAME="${VG_NAME:-${PRODUCT_ID}-vg}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DATA_DIR="${DATA_DIR:-/var/lib/${PRODUCT_ID}}"
TLS_DIR="${TLS_DIR:-/etc/${PRODUCT_ID}/tls}"

# ============================================================
# Utility
# ============================================================

msg() {
    echo ""
    echo "=== $1 ==="
    echo ""
}

die() {
    echo ""
    echo "FATAL: $1" >&2
    echo "Dropping to shell for debugging. Type 'reboot' to restart."
    exec /bin/sh
}

# Capture whiptail result to a temp file to avoid fd-swap contamination.
run_whiptail() {
    local _wt_tmp="/tmp/.wt-result"
    whiptail "$@" 2>"$_wt_tmp" </dev/console >/dev/console || true
    cat "$_wt_tmp" 2>/dev/null
    rm -f "$_wt_tmp"
}

# Ensure device mapper is loaded and LVM device nodes exist.
activate_lvm() {
    if ! grep -q device-mapper /proc/devices 2>/dev/null; then
        echo "  Loading device mapper..."
        modprobe dm_mod 2>/dev/null || true
    fi
    if ! grep -q device-mapper /proc/devices 2>/dev/null; then
        local kver
        kver=$(uname -r)
        for path in \
            "/usr/lib/modules/${kver}/kernel/drivers/md/dm-mod.ko.xz" \
            "/lib/modules/${kver}/kernel/drivers/md/dm-mod.ko.xz" \
            "/usr/lib/modules/${kver}/kernel/drivers/md/dm-mod.ko"; do
            if [ -f "$path" ]; then
                insmod "$path" 2>/dev/null || true
                break
            fi
        done
    fi
    if ! grep -q device-mapper /proc/devices 2>/dev/null; then
        die "Cannot load dm_mod. LVM requires device mapper."
    fi
    echo "  Device mapper: loaded"

    mkdir -p /dev/mapper
    if [ ! -e /dev/mapper/control ]; then
        mknod /dev/mapper/control c 10 236 2>/dev/null || true
    fi

    vgchange -ay "${VG_NAME}"
    vgscan --mknodes 2>/dev/null || true
    vgmknodes "${VG_NAME}" 2>/dev/null || true
    sleep 1

    if [ ! -e "/dev/${VG_NAME}/root" ]; then
        echo "  Symlinks missing, creating device nodes from lvs..."
        mkdir -p "/dev/${VG_NAME}"
        local lv_info
        lv_info=$(lvs --noheadings --nosuffix \
            -o lv_name,lv_kernel_major,lv_kernel_minor "${VG_NAME}" 2>/dev/null)
        echo "$lv_info" | while read -r name maj min rest; do
            if [ -n "$name" ] && [ -n "$maj" ] && [ -n "$min" ]; then
                if [ ! -e "/dev/${VG_NAME}/$name" ]; then
                    mknod "/dev/${VG_NAME}/$name" b "$maj" "$min"
                fi
            fi
        done
    fi

    if [ ! -e "/dev/${VG_NAME}/root" ]; then
        die "/dev/${VG_NAME}/root does not exist after all activation attempts"
    fi
    echo "  LVM devices: ready"
}

# ============================================================
# 1. Environment
# ============================================================

setup_env() {
    msg "Setting up environment"

    export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

    echo "  Loading modules..."
    for mod in virtio_pci virtio_scsi virtio_blk sd_mod ahci nvme scsi_mod \
               dm_mod dm_linear dm_striped dm_snapshot; do
        modprobe "$mod" 2>/dev/null || true
    done
    for mod in vfat fat nls_cp437 nls_ascii nls_utf8; do
        modprobe "$mod" 2>/dev/null || true
    done

    local kver
    kver=$(uname -r)
    local mbase="/usr/lib/modules/${kver}/kernel"

    insmod "${mbase}/drivers/md/dm-mod.ko.xz" 2>/dev/null || true

    if ! grep -q ext4 /proc/filesystems 2>/dev/null; then
        modprobe ext4 2>/dev/null || true
    fi
    if ! grep -q ext4 /proc/filesystems 2>/dev/null; then
        modprobe crc16 2>/dev/null || true
        modprobe crc32c_generic 2>/dev/null || true
        modprobe mbcache 2>/dev/null || true
        insmod "${mbase}/fs/jbd2/jbd2.ko.xz" 2>/dev/null || true
        insmod "${mbase}/fs/ext4/ext4.ko.xz" 2>/dev/null || true
    fi
    if ! grep -q ext4 /proc/filesystems 2>/dev/null; then
        for ko in $(find /usr/lib/modules -name 'ext4.ko*' 2>/dev/null); do
            for dep in $(find /usr/lib/modules -name 'jbd2.ko*' 2>/dev/null); do
                insmod "$dep" 2>/dev/null || true
            done
            insmod "$ko" 2>/dev/null || true
        done
    fi

    insmod "${mbase}/net/core/failover.ko.xz" 2>/dev/null || true
    insmod "${mbase}/drivers/net/virtio_net.ko.xz" 2>/dev/null || true
    for dir in \
        "${mbase}/net/core" \
        "${mbase}/drivers/net" \
        "${mbase}/drivers/ata" \
        "${mbase}/drivers/md" \
        "${mbase}/drivers/scsi"; do
        for ko in $(find "$dir" -name '*.ko.xz' 2>/dev/null | sort); do
            insmod "$ko" 2>/dev/null || true
        done
    done

    udevadm trigger 2>/dev/null || true
    udevadm settle --timeout=10 2>/dev/null || sleep 3
}

# ============================================================
# 2. Networking
# ============================================================

setup_network() {
    msg "Configuring network"

    local ifaces=""
    local iface_count=0
    for dev in /sys/class/net/*; do
        local name=$(basename "$dev")
        [ "$name" = "lo" ] && continue
        ifaces="$ifaces $name"
        iface_count=$((iface_count + 1))
    done
    ifaces=$(echo "$ifaces" | sed 's/^ //')

    [ -z "$ifaces" ] && die "No network interface found"

    echo "  Found $iface_count interface(s): $ifaces"
    for iface in $ifaces; do ip link set "$iface" up & done
    wait; sleep 1

    echo "  Trying DHCP on all interfaces..."
    local dhcp_tmpdir=$(mktemp -d)
    for iface in $ifaces; do
        (
            if command -v dhclient >/dev/null 2>&1; then
                dhclient -v "$iface" -timeout 15 2>/dev/null && \
                    touch "$dhcp_tmpdir/$iface"
            elif command -v udhcpc >/dev/null 2>&1; then
                udhcpc -i "$iface" -t 5 -n -q 2>/dev/null && \
                    touch "$dhcp_tmpdir/$iface"
            fi
        ) &
    done
    wait

    local got_ip=0
    for iface in $ifaces; do
        if [ -f "$dhcp_tmpdir/$iface" ]; then
            local ip_addr
            ip_addr=$(ip -4 addr show "$iface" scope global \
                | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
            echo "  DHCP succeeded on $iface: $ip_addr"
            got_ip=1
        fi
    done
    rm -rf "$dhcp_tmpdir"
    [ "$got_ip" = "1" ] && return

    echo "  DHCPv4 failed. Checking IPv6 SLAAC..."
    sleep 3
    for iface in $ifaces; do
        local ip6_addr
        ip6_addr=$(ip -6 addr show "$iface" scope global \
            | sed -n 's/.*inet6 \([0-9a-f:]*\).*/\1/p' | head -1)
        [ -n "$ip6_addr" ] && { echo "  IPv6 on $iface: $ip6_addr"; return; }
    done

    local manual_iface=$(echo "$ifaces" | awk '{print $1}')
    ip link set "$manual_iface" up

    echo ""
    echo "  DHCP failed on all interfaces. Manual network configuration required."
    echo ""

    if command -v whiptail >/dev/null 2>&1; then
        local manual_ip
        manual_ip=$(run_whiptail --title "Network Configuration" \
            --inputbox "DHCP failed.\n\nConfiguring ${manual_iface} manually.\n\nEnter IP address (CIDR, e.g. 192.168.1.100/24):" \
            12 60 "")
        [ -z "$manual_ip" ] && die "No IP address provided."

        local gateway
        gateway=$(run_whiptail --title "Network Configuration" \
            --inputbox "Enter gateway IP:" 10 60 "")

        local dns
        dns=$(run_whiptail --title "Network Configuration" \
            --inputbox "Enter DNS server IP:" 10 60 "8.8.8.8")

        ip addr add "$manual_ip" dev "$manual_iface"
        [ -n "$gateway" ] && ip route add default via "$gateway"
        [ -n "$dns" ] && echo "nameserver $dns" > /etc/resolv.conf
    else
        echo -n "  Enter IP address (CIDR, e.g. 192.168.1.100/24): "
        read manual_ip
        echo -n "  Enter gateway: "; read gateway
        echo -n "  Enter DNS [8.8.8.8]: "; read dns; dns=${dns:-8.8.8.8}
        ip addr add "$manual_ip" dev "$manual_iface"
        [ -n "$gateway" ] && ip route add default via "$gateway"
        echo "nameserver $dns" > /etc/resolv.conf
    fi

    echo "  Network configured on $manual_iface."
}

# ============================================================
# 2b. Sync clock
# ============================================================

sync_clock() {
    msg "Syncing system clock"

    if command -v ntpd >/dev/null 2>&1; then
        echo "  Trying NTP sync..."
        if ntpd -dnqp pool.ntp.org 2>/dev/null; then
            echo "  Clock set via NTP: $(date -u)"
            return
        fi
        echo "  NTP failed, falling back to HTTP date..."
    fi

    local http_date=""
    http_date=$(wget -qS --spider "$DEBIAN_MIRROR/dists/$DEBIAN_SUITE/Release" 2>&1 \
        | sed -n 's/^ *Date: *//p' | head -1) || true

    if [ -z "$http_date" ]; then
        echo "  WARNING: Could not fetch date from mirror"
        return
    fi

    local trimmed day month_name year time month
    trimmed=$(echo "$http_date" | sed 's/^[A-Za-z]*,[ ]*//')
    day=$(echo "$trimmed" | awk '{print $1}')
    month_name=$(echo "$trimmed" | awk '{print $2}')
    year=$(echo "$trimmed" | awk '{print $3}')
    time=$(echo "$trimmed" | awk '{print $4}')

    case "$month_name" in
        Jan) month="01" ;; Feb) month="02" ;; Mar) month="03" ;;
        Apr) month="04" ;; May) month="05" ;; Jun) month="06" ;;
        Jul) month="07" ;; Aug) month="08" ;; Sep) month="09" ;;
        Oct) month="10" ;; Nov) month="11" ;; Dec) month="12" ;;
        *) echo "  WARNING: Unrecognised month '$month_name'"; return ;;
    esac
    [ ${#day} -eq 1 ] && day="0$day"

    local iso_date="${year}-${month}-${day} ${time}"
    echo "  Setting clock to: $iso_date"
    date -u -s "$iso_date" >/dev/null 2>&1 || \
        echo "  WARNING: 'date -s' failed"
    echo "  Clock: $(date -u)"
}

# ============================================================
# 3. Disk selection
# ============================================================

select_disks() {
    msg "Disk selection"

    DISK_LIST=""
    DISK_COUNT=0
    local unsorted=""

    for dev in /sys/block/*; do
        local name=$(basename "$dev")
        case "$name" in loop*|ram*|sr*|dm-*|md*|nbd*|zram*) continue ;; esac

        local sz=$(cat "$dev/size" 2>/dev/null || echo 0)
        [ "$sz" -le 0 ] 2>/dev/null && continue
        local gb=$((sz * 512 / 1073741824))
        [ "$gb" -lt 1 ] && continue

        local removable=$(cat "$dev/removable" 2>/dev/null || echo 0)
        [ "$removable" = "1" ] && continue
        local devpath=$(readlink -f "$dev" 2>/dev/null || echo "")
        case "$devpath" in */usb*) continue ;; esac

        local mounted=0
        for part in /dev/${name}*; do
            grep -q "^$part " /proc/mounts 2>/dev/null && mounted=1
        done
        [ "$mounted" = "1" ] && continue

        local model=$(cat "$dev/device/model" 2>/dev/null \
            | sed 's/[[:space:]]*$//' | tr ' ' '_' || echo "Disk")
        [ -z "$model" ] && model="Disk"

        unsorted="$unsorted
$sz /dev/$name ${gb}GB_${model} off"
    done

    local sorted=$(echo "$unsorted" | sort -n)
    local IFS_OLD="$IFS"; IFS='
'
    for line in $sorted; do
        [ -z "$line" ] && continue
        local entry=$(echo "$line" | sed 's/^[0-9]* //')
        DISK_LIST="$DISK_LIST $entry"
        DISK_COUNT=$((DISK_COUNT + 1))
    done
    IFS="$IFS_OLD"

    [ "$DISK_COUNT" -eq 0 ] && die "No available disks found"

    local disk_devs="" disk_descs="" disk_sel=""
    local _field=0
    for token in $DISK_LIST; do
        case "$_field" in
            0) disk_devs="$disk_devs $token"; _field=1 ;;
            1) disk_descs="$disk_descs $token"; _field=2 ;;
            2) disk_sel="$disk_sel 0"; _field=0 ;;
        esac
    done

    if command -v whiptail >/dev/null 2>&1; then
        SELECTED_DISKS=$(eval whiptail \
            --title '"'"${PRODUCT_NAME}"' - Select OS Disk(s)"' \
            --checklist '"Select one or more disks for the OS.\n\nOne disk: standard LVM.\nTwo or more: RAID-1 mirror + LVM."' \
            20 70 "$DISK_COUNT" \
            $DISK_LIST \
            3>&1 1>&2 2>&3) || true
        SELECTED_DISKS=$(echo "$SELECTED_DISKS" | tr -d '"')
    else
        echo ""
        echo "  Select disk(s) for the OS install."
        echo "  One disk = LVM. Two or more = RAID-1 + LVM."
        echo ""

        while true; do
            echo "  Available disks:"
            local idx=1
            for dev in $disk_devs; do
                local desc=$(echo "$disk_descs" | awk "{print \$$idx}")
                local sel=$(echo "$disk_sel" | awk "{print \$$idx}")
                if [ "$sel" = "1" ]; then
                    echo "    $idx) [*] $dev  ($desc)"
                else
                    echo "    $idx) [ ] $dev  ($desc)"
                fi
                idx=$((idx + 1))
            done
            echo ""
            echo -n "  Enter a number to toggle, or 'done' to continue: "
            read choice

            if [ "$choice" = "done" ] || [ "$choice" = "d" ]; then
                break
            fi

            if echo "$choice" | grep -q '^[0-9]*$' && \
               [ "$choice" -ge 1 ] 2>/dev/null && \
               [ "$choice" -le "$DISK_COUNT" ] 2>/dev/null; then
                local new_sel="" t=1
                for s in $disk_sel; do
                    if [ "$t" = "$choice" ]; then
                        [ "$s" = "1" ] && new_sel="$new_sel 0" || new_sel="$new_sel 1"
                    else
                        new_sel="$new_sel $s"
                    fi
                    t=$((t + 1))
                done
                disk_sel="$new_sel"
            else
                echo "  Invalid choice."
            fi
        done

        SELECTED_DISKS=""
        local idx=1
        for dev in $disk_devs; do
            local sel=$(echo "$disk_sel" | awk "{print \$$idx}")
            [ "$sel" = "1" ] && SELECTED_DISKS="$SELECTED_DISKS $dev"
            idx=$((idx + 1))
        done
        SELECTED_DISKS=$(echo "$SELECTED_DISKS" | sed 's/^ *//')
    fi

    [ -z "$SELECTED_DISKS" ] && die "No disks selected"

    SELECTED_COUNT=$(echo "$SELECTED_DISKS" | wc -w)
    echo "  Selected $SELECTED_COUNT disk(s): $SELECTED_DISKS"

    if [ "$SELECTED_COUNT" -gt 1 ]; then
        USE_RAID=1
        echo "  Mode: RAID-1 + LVM"
    else
        USE_RAID=0
        echo "  Mode: Single disk + LVM"
    fi
}

# ============================================================
# 3b. Password
# ============================================================

prompt_password() {
    msg "Set admin password"

    ADMIN_PASSWORD=""

    if command -v whiptail >/dev/null 2>&1; then
        while true; do
            local pass1
            pass1=$(run_whiptail \
                --title "${PRODUCT_NAME} - Admin Password" \
                --passwordbox "Enter password for the 'admin' account (min 6 characters):" \
                10 60 "")
            [ -z "$pass1" ] && die "Password is required"
            if [ ${#pass1} -lt 6 ]; then
                whiptail --title "Error" \
                    --msgbox "Password must be at least 6 characters." 8 50
                continue
            fi
            local pass2
            pass2=$(run_whiptail \
                --title "${PRODUCT_NAME} - Confirm Password" \
                --passwordbox "Confirm password:" 10 60 "")
            if [ "$pass1" != "$pass2" ]; then
                whiptail --title "Error" --msgbox "Passwords do not match." 8 50
                continue
            fi
            ADMIN_PASSWORD="$pass1"
            break
        done
    else
        while true; do
            echo -n "  Enter admin password (min 6 chars): "
            stty -echo; read pass1; stty echo; echo ""
            if [ ${#pass1} -lt 6 ]; then
                echo "  Password must be at least 6 characters."
                continue
            fi
            echo -n "  Confirm password: "
            stty -echo; read pass2; stty echo; echo ""
            if [ "$pass1" != "$pass2" ]; then
                echo "  Passwords do not match."; continue
            fi
            ADMIN_PASSWORD="$pass1"
            break
        done
    fi
    echo "  Password set."
}

# ============================================================
# 4. Partitioning
# ============================================================

wipe_disk() {
    local disk="$1"
    echo "  Wiping $disk..."

    for md in /dev/md*; do
        [ -b "$md" ] || continue
        mdadm --stop "$md" 2>/dev/null || true
    done

    for pv in $(pvs --noheadings -o pv_name 2>/dev/null | grep "$disk" || true); do
        local vg=$(pvs --noheadings -o vg_name "$pv" 2>/dev/null | tr -d ' ')
        [ -n "$vg" ] && vgchange -an "$vg" 2>/dev/null || true
        [ -n "$vg" ] && vgremove -ff "$vg" 2>/dev/null || true
        pvremove -ff "$pv" 2>/dev/null || true
    done

    for part in "${disk}"[0-9]* "${disk}p"[0-9]*; do
        [ -b "$part" ] || continue
        wipefs -a "$part" 2>/dev/null || true
        mdadm --zero-superblock "$part" 2>/dev/null || true
    done

    wipefs -a "$disk" 2>/dev/null || true
    mdadm --zero-superblock "$disk" 2>/dev/null || true
    dd if=/dev/zero of="$disk" bs=1M count=10 2>/dev/null || true
    local disk_size=$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)
    if [ "$disk_size" -gt 10485760 ]; then
        dd if=/dev/zero of="$disk" bs=1M count=10 \
            seek=$(( (disk_size / 1048576) - 10 )) 2>/dev/null || true
    fi

    sgdisk --zap-all "$disk" 2>/dev/null || true
    partprobe "$disk" 2>/dev/null || true
    sleep 1
}

do_partitioning() {
    msg "Partitioning"

    mkdir -p "$TARGET"

    echo "  Stopping all active RAID arrays and LVM..."
    vgchange -an 2>/dev/null || true
    for md in /dev/md*; do
        [ -b "$md" ] || continue
        mdadm --stop "$md" 2>/dev/null || true
    done
    for dev in /dev/sd*[0-9] /dev/nvme*p[0-9]*; do
        [ -b "$dev" ] || continue
        mdadm --zero-superblock "$dev" 2>/dev/null || true
    done

    for disk in $SELECTED_DISKS; do
        wipe_disk "$disk"
    done

    if [ "$USE_RAID" = "1" ]; then
        partition_raid
    else
        partition_single
    fi
}

partition_single() {
    local disk=$(echo "$SELECTED_DISKS" | awk '{print $1}')
    echo "  Partitioning $disk (single disk + LVM)..."

    sgdisk -n 1:0:+1M   -t 1:ef02 -c 1:"bios-boot" "$disk"
    sgdisk -n 2:0:+512M -t 2:ef00 -c 2:"EFI"        "$disk"
    sgdisk -n 3:0:+1G   -t 3:8300 -c 3:"boot"       "$disk"
    sgdisk -n 4:0:0     -t 4:8e00 -c 4:"lvm"        "$disk"

    sleep 1
    blockdev --rereadpt "$disk" 2>/dev/null || true
    sleep 1

    local p1 p2 p3 p4
    if echo "$disk" | grep -q "nvme"; then
        p1="${disk}p1"; p2="${disk}p2"; p3="${disk}p3"; p4="${disk}p4"
    else
        p1="${disk}1"; p2="${disk}2"; p3="${disk}3"; p4="${disk}4"
    fi

    mkfs.vfat -F 32 "$p2"
    mkfs.ext4 -F "$p3"

    vgremove -ff "${VG_NAME}" 2>/dev/null || true
    pvremove -ff "$p4" 2>/dev/null || true
    pvcreate -ff -y "$p4"
    vgcreate "${VG_NAME}" "$p4"
    lvcreate -Wy -y -L 4G -n swap "${VG_NAME}"
    lvcreate -Wy -y -l 100%FREE -n root "${VG_NAME}"

    vgscan --mknodes 2>/dev/null || true
    vgchange -ay "${VG_NAME}" 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || sleep 2

    mkswap "/dev/${VG_NAME}/swap"
    mkfs.ext4 -F "/dev/${VG_NAME}/root"

    mount -t ext4 "/dev/${VG_NAME}/root" "$TARGET" || \
        die "Failed to mount /dev/${VG_NAME}/root on $TARGET"
    mkdir -p "$TARGET/boot"
    mount "$p3" "$TARGET/boot"
    mkdir -p "$TARGET/boot/efi"
    mount -t vfat "$p2" "$TARGET/boot/efi"

    GRUB_DISK="$disk"
}

partition_raid() {
    echo "  Partitioning for RAID-1 + LVM..."

    local disk_num=0 boot_parts="" raid_parts=""

    for disk in $SELECTED_DISKS; do
        echo "    Partitioning $disk..."
        sgdisk -n 1:0:+1M   -t 1:ef02 -c 1:"bios-boot"  "$disk"
        sgdisk -n 2:0:+512M -t 2:ef00 -c 2:"EFI"         "$disk"
        sgdisk -n 3:0:+1G   -t 3:fd00 -c 3:"boot-raid"   "$disk"
        sgdisk -n 4:0:0     -t 4:fd00 -c 4:"lvm-raid"    "$disk"

        sleep 1
        blockdev --rereadpt "$disk" 2>/dev/null || true
        sleep 1

        local p3 p4
        if echo "$disk" | grep -q "nvme"; then
            p3="${disk}p3"; p4="${disk}p4"
        else
            p3="${disk}3"; p4="${disk}4"
        fi

        boot_parts="$boot_parts $p3"
        raid_parts="$raid_parts $p4"
        disk_num=$((disk_num + 1))
    done

    echo "    Creating RAID-1 arrays..."
    mdadm --create /dev/md0 --level=1 --raid-devices=$disk_num \
        --metadata=1.2 --run $boot_parts << EOF
yes
EOF
    mdadm --create /dev/md1 --level=1 --raid-devices=$disk_num \
        --metadata=1.2 --run $raid_parts << EOF
yes
EOF

    sleep 2

    mkfs.ext4 -F /dev/md0

    vgremove -ff "${VG_NAME}" 2>/dev/null || true
    pvremove -ff /dev/md1 2>/dev/null || true
    pvcreate -ff -y /dev/md1
    vgcreate "${VG_NAME}" /dev/md1
    lvcreate -Wy -y -L 4G -n swap "${VG_NAME}"
    lvcreate -Wy -y -l 100%FREE -n root "${VG_NAME}"

    vgscan --mknodes 2>/dev/null || true
    vgchange -ay "${VG_NAME}" 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || sleep 2

    mkswap "/dev/${VG_NAME}/swap"
    mkfs.ext4 -F "/dev/${VG_NAME}/root"

    local first_disk=$(echo "$SELECTED_DISKS" | awk '{print $1}')
    local efi_part
    if echo "$first_disk" | grep -q "nvme"; then
        efi_part="${first_disk}p2"
    else
        efi_part="${first_disk}2"
    fi
    mkfs.vfat -F 32 "$efi_part"

    mount -t ext4 "/dev/${VG_NAME}/root" "$TARGET" || \
        die "Failed to mount /dev/${VG_NAME}/root on $TARGET"
    mkdir -p "$TARGET/boot"
    mount /dev/md0 "$TARGET/boot"
    mkdir -p "$TARGET/boot/efi"
    mount -t vfat "$efi_part" "$TARGET/boot/efi"

    GRUB_DISK="$first_disk"
}

# ============================================================
# 5. Base system
# ============================================================

install_base() {
    msg "Installing base system (this may take several minutes)"

    command -v debootstrap >/dev/null 2>&1 || \
        die "debootstrap not found in initrd -- rebuild ISO"

    echo "  Running debootstrap for ${DEBIAN_SUITE}..."
    debootstrap --foreign --arch=amd64 \
        "$DEBIAN_SUITE" "$TARGET" "$DEBIAN_MIRROR" || \
        die "debootstrap first stage failed"

    # Stub postinsts that source debconf confmodule -- they hang in the
    # minimal initrd environment because the Perl frontend blocks on stdin.
    mkdir -p "$TARGET/etc/dpkg/dpkg.cfg.d"
    cat > "$TARGET/etc/dpkg/dpkg.cfg.d/smoothiso-bootstrap" << 'DPKGCFG'
pre-invoke=/debootstrap/stub-debconf-postinsts
DPKGCFG
    cat > "$TARGET/debootstrap/stub-debconf-postinsts" << 'HOOK'
#!/bin/sh
for f in /var/lib/dpkg/info/*.postinst; do
    [ -f "$f" ] || continue
    grep -q SMOOTHISO_STUB "$f" 2>/dev/null && continue
    grep -q '/usr/share/debconf/confmodule' "$f" 2>/dev/null || continue
    cp "$f" "${f}.real"
    printf '#!/bin/sh\n# SMOOTHISO_STUB\nexit 0\n' > "$f"
    chmod +x "$f"
done
HOOK
    chmod +x "$TARGET/debootstrap/stub-debconf-postinsts"

    echo "  Running debootstrap second stage..."
    DEBIAN_FRONTEND=noninteractive chroot "$TARGET" \
        /debootstrap/debootstrap --second-stage || \
        die "debootstrap second stage failed"

    rm -f "$TARGET/etc/dpkg/dpkg.cfg.d/smoothiso-bootstrap"
    rm -f "$TARGET/debootstrap/stub-debconf-postinsts"

    # Restore and reconfigure stubbed packages.
    local stubbed_pkgs=""
    for real in "$TARGET"/var/lib/dpkg/info/*.postinst.real; do
        [ -f "$real" ] || continue
        local base="${real%.real}"
        mv "$real" "$base"
        stubbed_pkgs="$stubbed_pkgs $(basename "$base" .postinst)"
    done

    if [ -n "$stubbed_pkgs" ]; then
        echo "  Reconfiguring:$stubbed_pkgs"
        mount --bind /dev "$TARGET/dev" 2>/dev/null || true
        mount --bind /dev/pts "$TARGET/dev/pts" 2>/dev/null || true
        mount -t proc proc "$TARGET/proc" 2>/dev/null || true
        mount -t sysfs sysfs "$TARGET/sys" 2>/dev/null || true
        for pkg in $stubbed_pkgs; do
            echo "    Configuring $pkg..."
            DEBIAN_FRONTEND=noninteractive chroot "$TARGET" \
                dpkg --configure "$pkg" 2>&1 || \
                echo "    WARNING: $pkg configure returned non-zero"
        done
        umount "$TARGET/sys" "$TARGET/proc" "$TARGET/dev/pts" "$TARGET/dev" \
            2>/dev/null || true
    fi

    echo "  Base system installed."
}

# ============================================================
# 6. Packages
# ============================================================

install_packages() {
    msg "Installing packages"

    mount --bind /dev "$TARGET/dev"
    mount --bind /dev/pts "$TARGET/dev/pts"
    mount -t proc proc "$TARGET/proc"
    mount -t sysfs sysfs "$TARGET/sys"

    cat > "$TARGET/etc/apt/sources.list" << SOURCES
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free-firmware
deb $DEBIAN_MIRROR ${DEBIAN_SUITE}-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free-firmware
SOURCES

    cat > "$TARGET/usr/sbin/policy-rc.d" << 'POLICY'
#!/bin/sh
exit 101
POLICY
    chmod +x "$TARGET/usr/sbin/policy-rc.d"

    echo "debconf debconf/frontend select Noninteractive" | \
        chroot "$TARGET" debconf-set-selections 2>/dev/null || true
    if [ -f "$TARGET/usr/sbin/dpkg-preconfigure" ]; then
        mv "$TARGET/usr/sbin/dpkg-preconfigure" \
           "$TARGET/usr/sbin/dpkg-preconfigure.real"
        printf '#!/bin/sh\nexit 0\n' > "$TARGET/usr/sbin/dpkg-preconfigure"
        chmod +x "$TARGET/usr/sbin/dpkg-preconfigure"
    fi
    mkdir -p "$TARGET/etc/dpkg/dpkg.cfg.d"
    cat > "$TARGET/etc/dpkg/dpkg.cfg.d/smoothiso-install" << 'DPKGCFG'
pre-invoke=/tmp/smoothiso-stub-debconf
DPKGCFG
    cat > "$TARGET/tmp/smoothiso-stub-debconf" << 'HOOK'
#!/bin/sh
for f in /var/lib/dpkg/info/*.postinst; do
    [ -f "$f" ] || continue
    grep -q SMOOTHISO_STUB "$f" 2>/dev/null && continue
    grep -q '/usr/share/debconf/confmodule' "$f" 2>/dev/null || continue
    cp "$f" "${f}.real"
    printf '#!/bin/sh\n# SMOOTHISO_STUB\nexit 0\n' > "$f"
    chmod +x "$f"
done
HOOK
    chmod +x "$TARGET/tmp/smoothiso-stub-debconf"
    if [ -f "$TARGET/usr/sbin/pam-auth-update" ]; then
        mv "$TARGET/usr/sbin/pam-auth-update" \
           "$TARGET/usr/sbin/pam-auth-update.real"
        printf '#!/bin/sh\nexit 0\n' > "$TARGET/usr/sbin/pam-auth-update"
        chmod +x "$TARGET/usr/sbin/pam-auth-update"
    fi

    chroot "$TARGET" apt-get update -qq

    echo "  Installing bootloader packages..."
    DEBIAN_FRONTEND=noninteractive chroot "$TARGET" apt-get install -y \
        grub-efi-amd64 grub-pc-bin efibootmgr \
        2>&1 || die "Failed to install GRUB packages"

    echo "  Installing kernel and core packages..."
    DEBIAN_FRONTEND=noninteractive chroot "$TARGET" apt-get install -y -qq \
        linux-image-amd64 linux-headers-amd64 \
        lvm2 mdadm \
        openssh-server \
        sudo curl wget ca-certificates \
        systemd-timesyncd systemd-resolved \
        2>/dev/null || true

    # Product-specific packages.
    if [ -f /smoothiso-hooks/packages.sh ]; then
        echo "  Running project packages hook..."
        . /smoothiso-hooks/packages.sh
    fi

    # Cleanup hooks and stubs.
    rm -f "$TARGET/etc/dpkg/dpkg.cfg.d/smoothiso-install"
    rm -f "$TARGET/tmp/smoothiso-stub-debconf"
    if [ -f "$TARGET/usr/sbin/dpkg-preconfigure.real" ]; then
        mv "$TARGET/usr/sbin/dpkg-preconfigure.real" \
           "$TARGET/usr/sbin/dpkg-preconfigure"
    fi
    if [ -f "$TARGET/usr/sbin/pam-auth-update.real" ]; then
        mv "$TARGET/usr/sbin/pam-auth-update.real" \
           "$TARGET/usr/sbin/pam-auth-update"
    fi

    for real in "$TARGET"/var/lib/dpkg/info/*.postinst.real; do
        [ -f "$real" ] || continue
        mv "$real" "${real%.real}"
    done

    chroot "$TARGET" sh -c '
        find /usr/share/ca-certificates -name "*.crt" -printf "%P\n" | sort \
            > /etc/ca-certificates.conf
        update-ca-certificates --fresh
    ' 2>/dev/null || true

    # Generate PAM config directly (pam-auth-update uses debconf and hangs).
    echo "  Generating PAM configuration..."
    cat > "$TARGET/etc/pam.d/common-auth" << 'PAM'
auth    [success=1 default=ignore]  pam_unix.so nullok
auth    requisite                   pam_deny.so
auth    required                    pam_permit.so
PAM
    cat > "$TARGET/etc/pam.d/common-account" << 'PAM'
account [success=1 new_authtok_reqd=done default=ignore]  pam_unix.so
account requisite                   pam_deny.so
account required                    pam_permit.so
PAM
    cat > "$TARGET/etc/pam.d/common-session" << 'PAM'
session [default=1]                 pam_permit.so
session requisite                   pam_deny.so
session required                    pam_permit.so
session required    pam_unix.so
PAM
    cat > "$TARGET/etc/pam.d/common-session-noninteractive" << 'PAM'
session [default=1]                 pam_permit.so
session requisite                   pam_deny.so
session required                    pam_permit.so
session required    pam_unix.so
PAM
    cat > "$TARGET/etc/pam.d/common-password" << 'PAM'
password [success=1 default=ignore]  pam_unix.so obscure yescrypt
password requisite                   pam_deny.so
password required                    pam_permit.so
PAM

    echo "  Package reconfiguration deferred to first boot."
    rm -f "$TARGET/usr/sbin/policy-rc.d"
    chroot "$TARGET" apt-get clean -qq
    echo "  All packages installed."
}

# ============================================================
# 7. System configuration
# ============================================================

configure_system() {
    msg "Configuring system"

    # Login banner.
    cat > "$TARGET/etc/issue" << ISSUE

  ${PRODUCT_NAME}  -  \\n
  IP: \\4

ISSUE

    # Hostname.
    echo "$HOSTNAME" > "$TARGET/etc/hostname"
    cat > "$TARGET/etc/hosts" << HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME

::1 localhost ip6-localhost ip6-loopback
HOSTS

    chroot "$TARGET" ln -sf /usr/share/zoneinfo/UTC /etc/localtime

    # fstab.
    local boot_dev boot_uuid efi_dev efi_uuid
    if [ "$USE_RAID" = "1" ]; then
        boot_dev="/dev/md0"
    else
        local disk=$(echo "$SELECTED_DISKS" | awk '{print $1}')
        if echo "$disk" | grep -q "nvme"; then
            boot_dev="${disk}p3"
        else
            boot_dev="${disk}3"
        fi
    fi
    local first_disk=$(echo "$SELECTED_DISKS" | awk '{print $1}')
    if echo "$first_disk" | grep -q "nvme"; then
        efi_dev="${first_disk}p2"
    else
        efi_dev="${first_disk}2"
    fi

    boot_uuid=$(blkid -s UUID -o value "$boot_dev" 2>/dev/null || true)
    efi_uuid=$(blkid -s UUID -o value "$efi_dev" 2>/dev/null || true)

    cat > "$TARGET/etc/fstab" << FSTAB
# <file system>             <mount point> <type> <options>         <dump> <pass>
/dev/${VG_NAME}/root        /             ext4   errors=remount-ro 0      1
/dev/${VG_NAME}/swap        none          swap   sw                0      0
FSTAB

    if [ -n "$boot_uuid" ]; then
        echo "UUID=${boot_uuid}   /boot   ext4  defaults  0  2" \
            >> "$TARGET/etc/fstab"
    else
        echo "${boot_dev}         /boot   ext4  defaults  0  2" \
            >> "$TARGET/etc/fstab"
    fi
    if [ -n "$efi_uuid" ]; then
        echo "UUID=${efi_uuid}    /boot/efi  vfat  umask=0077,nofail  0  1" \
            >> "$TARGET/etc/fstab"
    else
        echo "${efi_dev}          /boot/efi  vfat  umask=0077,nofail  0  1" \
            >> "$TARGET/etc/fstab"
    fi

    # Admin user.
    chroot "$TARGET" groupadd --system sudo 2>/dev/null || true
    if ! chroot "$TARGET" useradd --create-home --groups sudo \
         --shell /bin/bash admin; then
        chroot "$TARGET" usermod --groups sudo --shell /bin/bash admin || \
            die "Failed to create or configure admin user"
    fi
    echo "admin:${ADMIN_PASSWORD}" | chroot "$TARGET" chpasswd
    echo "root:${ADMIN_PASSWORD}" | chroot "$TARGET" chpasswd

    # Networking.
    chroot "$TARGET" systemctl disable networking.service 2>/dev/null || true
    chroot "$TARGET" systemctl mask networking.service 2>/dev/null || true
    chroot "$TARGET" systemctl enable systemd-networkd 2>/dev/null || true
    chroot "$TARGET" systemctl enable systemd-resolved 2>/dev/null || true
    ln -sf /run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"

    mkdir -p "$TARGET/etc/systemd/system/systemd-networkd-wait-online.service.d"
    cat > "$TARGET/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf" << 'WAITCFG'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=10
WAITCFG

    # Persistent NIC naming.
    mkdir -p "$TARGET/etc/systemd/network"
    local idx=0
    for dev in /sys/class/net/*; do
        local name=$(basename "$dev")
        [ "$name" = "lo" ] && continue
        local mac=$(cat "$dev/address" 2>/dev/null)
        [ -z "$mac" ] && continue
        cat > "$TARGET/etc/systemd/network/00-net${idx}.link" << LINK
[Match]
MACAddress=$mac

[Link]
Name=net${idx}
LINK
        echo "  Pinned $name ($mac) -> net${idx}"
        idx=$((idx + 1))
    done

    cat > "$TARGET/etc/systemd/network/10-dhcp.network" << 'NETCFG'
[Match]
Type=ether

[Network]
DHCP=yes
IPv6AcceptRA=yes
NETCFG

    # RAID config.
    if [ "$USE_RAID" = "1" ]; then
        mkdir -p "$TARGET/etc/mdadm"
        echo "DEVICE partitions" > "$TARGET/etc/mdadm/mdadm.conf"
        mdadm --detail --scan >> "$TARGET/etc/mdadm/mdadm.conf" 2>/dev/null || true

        mkdir -p "$TARGET/etc/initramfs-tools/conf.d"
        echo "BOOT_DEGRADED=true" \
            > "$TARGET/etc/initramfs-tools/conf.d/mdadm"

        mkdir -p "$TARGET/etc/lvm/lvmlocal.conf.d"
        cat > "$TARGET/etc/lvm/lvmlocal.conf.d/${PRODUCT_ID}-raid.conf" << 'LVMCFG'
devices {
    global_filter = [ "a|/dev/md.*|", "r|/dev/sd.*|", "r|/dev/nvme.*|" ]
}
LVMCFG
    fi

    # GRUB config.
    cat >> "$TARGET/etc/default/grub" << 'GRUBCFG'

# smoothiso: preload modules for mdraid + LVM root
GRUB_PRELOAD_MODULES="part_gpt part_msdos mdraid1x lvm ext2"
GRUB_DISABLE_OS_PROBER=true
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 console=tty0"
GRUBCFG

    # Rebuild initramfs.
    echo "  Rebuilding initramfs..."
    chroot "$TARGET" update-initramfs -u 2>&1 || true

    # Base firewall: allow SSH + established. Project hook can add more.
    cat > "$TARGET/etc/nftables.conf" << 'NFT'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        meta l4proto icmp accept
        meta l4proto icmpv6 accept
        tcp dport 22 accept comment "SSH"
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFT
    chroot "$TARGET" systemctl enable nftables 2>/dev/null || true

    # Install firstboot script and systemd unit.
    if [ -f /smoothiso-firstboot ]; then
        install -m 755 /smoothiso-firstboot \
            "$TARGET/usr/local/bin/${PRODUCT_ID}-firstboot"

        # Copy firstboot extension hook for use by the firstboot script.
        if [ -f /smoothiso-hooks/firstboot.sh ]; then
            mkdir -p "$TARGET/usr/local/lib/smoothiso"
            install -m 755 /smoothiso-hooks/firstboot.sh \
                "$TARGET/usr/local/lib/smoothiso/firstboot-ext.sh"
        fi

        cat > "$TARGET/etc/systemd/system/${PRODUCT_ID}-firstboot.service" << UNIT
[Unit]
Description=${PRODUCT_NAME} First Boot Setup
After=network-online.target
ConditionPathExists=!${DATA_DIR}/.firstboot-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/${PRODUCT_ID}-firstboot
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
UNIT
        chroot "$TARGET" systemctl enable "${PRODUCT_ID}-firstboot.service" \
            2>/dev/null || true
    fi

    # Product-specific configuration.
    if [ -f /smoothiso-hooks/configure.sh ]; then
        echo "  Running project configure hook..."
        . /smoothiso-hooks/configure.sh
    fi

    echo "  System configured."
}

# ============================================================
# 8. GRUB
# ============================================================

install_grub() {
    msg "Installing GRUB bootloader"

    local uefi_ok=0 bios_ok=0

    if [ -d /sys/firmware/efi ]; then
        if chroot "$TARGET" dpkg -l grub-efi-amd64 2>/dev/null | grep -q '^ii'; then
            echo "  Installing GRUB (UEFI)..."
            chroot "$TARGET" grub-install --target=x86_64-efi \
                --efi-directory=/boot/efi \
                --bootloader-id="${PRODUCT_ID}" \
                --recheck --no-nvram 2>&1 && uefi_ok=1 || \
                echo "  WARNING: UEFI GRUB install failed"
            echo "  Installing GRUB (UEFI removable)..."
            chroot "$TARGET" grub-install --target=x86_64-efi \
                --efi-directory=/boot/efi \
                --recheck --no-nvram --removable 2>&1 || \
                echo "  WARNING: UEFI removable install failed"
        fi
    fi

    if chroot "$TARGET" dpkg -l grub-pc-bin 2>/dev/null | grep -q '^ii'; then
        for disk in $SELECTED_DISKS; do
            echo "  Installing GRUB (BIOS) to $disk..."
            chroot "$TARGET" grub-install --target=i386-pc "$disk" 2>&1 \
                && bios_ok=1 || \
                echo "  WARNING: BIOS GRUB install to $disk failed"
        done
    fi

    [ "$uefi_ok" = "0" ] && [ "$bios_ok" = "0" ] && \
        echo "  ERROR: No bootloader installed successfully!"

    chroot "$TARGET" update-grub 2>&1 || echo "  WARNING: update-grub failed"
    echo "  GRUB installed."
}

# ============================================================
# 9. Finish
# ============================================================

finish() {
    msg "Installation complete"

    umount "$TARGET/dev/pts" 2>/dev/null || true
    umount "$TARGET/dev"     2>/dev/null || true
    umount "$TARGET/proc"    2>/dev/null || true
    umount "$TARGET/sys"     2>/dev/null || true
    umount "$TARGET/boot/efi" 2>/dev/null || true
    umount "$TARGET/boot"    2>/dev/null || true
    umount "$TARGET"         2>/dev/null || true

    local ip_addr
    ip_addr=$(ip -4 addr show scope global \
        | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)

    echo ""
    echo "  ========================================="
    echo "   ${PRODUCT_NAME} Installation Complete"
    echo "  ========================================="
    echo ""
    echo "   Access: https://${ip_addr:-<your-ip>}"
    echo "   Username: admin"
    echo ""
    echo "   Remove the installation media and"
    echo "   press Enter to reboot."
    echo ""
    read dummy < /dev/console

    echo "Rebooting..."
    sync; sleep 1
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    echo b > /proc/sysrq-trigger 2>/dev/null || true
    reboot -f 2>/dev/null || true
    sleep 2
    kill -INT 1 2>/dev/null || true
}

# ============================================================
# Main
# ============================================================

echo ""
echo "  ${PRODUCT_NAME} Installer"
echo ""

setup_env
setup_network
sync_clock
select_disks
prompt_password
do_partitioning
install_base
install_packages
configure_system
install_grub
finish
