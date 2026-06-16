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

# Parse unattended-install answers from the kernel command line. This lets the
# whole install run without operator input: the values are exported into the
# same SELECTED_DISKS / ADMIN_PASSWORD variables the interactive prompts already
# honor as a pre-set bypass (see select_disks / prompt_password).
#
# Recognised kernel cmdline keys (all optional):
#   smoothiso.disks=/dev/sda            one or more block devices (comma or
#                                       plus separated for RAID-1, e.g.
#                                       smoothiso.disks=/dev/sda+/dev/sdb)
#   smoothiso.password=hunter2          admin/root password (>= 6 chars)
#   smoothiso.auto                      marker only; install is unattended
#                                       whenever disks+password are supplied,
#                                       this just documents intent on the menu
#
# Interactive install is unaffected: with none of these present, the prompts
# run exactly as before.
parse_cmdline_automation() {
    [ -r /proc/cmdline ] || return 0
    local tok key val
    for tok in $(cat /proc/cmdline); do
        case "$tok" in
            smoothiso.disks=*)
                val="${tok#smoothiso.disks=}"
                # Accept comma or plus as separators; installer wants spaces.
                val=$(printf '%s' "$val" | tr ',+' '  ')
                [ -n "$val" ] && SELECTED_DISKS="$val"
                ;;
            smoothiso.password=*)
                ADMIN_PASSWORD="${tok#smoothiso.password=}"
                ;;
        esac
    done
    [ -n "${SELECTED_DISKS:-}" ] && export SELECTED_DISKS
    [ -n "${ADMIN_PASSWORD:-}" ] && export ADMIN_PASSWORD
}
parse_cmdline_automation

TARGET="/mnt/target"
PRODUCT_NAME="${PRODUCT_NAME:-Linux}"
PRODUCT_ID="${PRODUCT_ID:-linux}"
HOSTNAME="${PRODUCT_HOSTNAME:-${PRODUCT_ID}}"
VG_NAME="${VG_NAME:-${PRODUCT_ID}-vg}"
ARCH="${ARCH:-amd64}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DATA_DIR="${DATA_DIR:-/var/lib/${PRODUCT_ID}}"
TLS_DIR="${TLS_DIR:-/etc/${PRODUCT_ID}/tls}"
UI_STATE_DIR="${UI_STATE_DIR:-/run/smoothiso-ui}"
UI_REQUEST_DIR="${UI_REQUEST_DIR:-${UI_STATE_DIR}/requests}"
UI_RESPONSE_DIR="${UI_RESPONSE_DIR:-${UI_STATE_DIR}/responses}"
UI_FRONTEND_DIR="${SMOOTHGUI_FRONTEND_DIR:-/smoothiso-ui}"
SMOOTHGUI_FRONTEND_BIND="${SMOOTHGUI_FRONTEND_BIND:-127.0.0.1}"
SMOOTHGUI_FRONTEND_PORT="${SMOOTHGUI_FRONTEND_PORT:-8080}"
UI_FRONTEND_BACKEND="${UI_FRONTEND_BACKEND:-/smoothiso-ui-backend/start.sh}"
# Blocking interactive prompts (disk-select, password, completion). The
# operator needs time to read the screen and pick options, so we give a
# generous 30-minute window before declaring the kiosk dead. Status
# polling uses UI_REQUEST_TIMEOUT separately.
UI_FRONTEND_TIMEOUT="${UI_FRONTEND_TIMEOUT:-1800}"
UI_FRONTEND_ENABLED=0
UI_FRONTEND_REQUIRED="${SMOOTHGUI_FRONTEND_REQUIRED:-1}"
UI_FRONTEND_SERVER_PID=""
UI_FRONTEND_VIEWER_PID=""
UI_FRONTEND_XVFB_PID=""
UI_FRONTEND_XORG_PID=""
UI_FRONTEND_DBUS_PID=""
UI_FRONTEND_VIEWER_LAUNCHED=0
SMOOTHGUI_FIREFOX_HOME="/run/smoothiso-ui/firefox-home"
SMOOTHGUI_FIREFOX_RUNTIME="/run/smoothiso-ui/firefox-runtime"
SMOOTHGUI_DISPLAY="${SMOOTHGUI_DISPLAY:-:0}"
SMOOTHGUI_XORG_STARTUP_TIMEOUT="${SMOOTHGUI_XORG_STARTUP_TIMEOUT:-12}"
SMOOTHGUI_REQUIRE_VISIBLE_DISPLAY="${SMOOTHGUI_REQUIRE_VISIBLE_DISPLAY:-1}"
SMOOTHGUI_BROWSER_USER="${SMOOTHGUI_BROWSER_USER:-smoothinstaller}"
SMOOTHGUI_BROWSER_UID="${SMOOTHGUI_BROWSER_UID:-1000}"
SMOOTHGUI_BROWSER_GID="${SMOOTHGUI_BROWSER_GID:-1000}"
SMOOTHGUI_FRONTEND_READY_TIMEOUT="${SMOOTHGUI_FRONTEND_READY_TIMEOUT:-25}"
INSTALLER_GPU_KERNEL_MODULES="${INSTALLER_GPU_KERNEL_MODULES:-}"
# Space-separated list of "code:Display_Label" pairs offered to the operator
# as a language choice before installation begins. When empty or a single
# entry the picker is skipped and INSTALLER_LANG stays at its default.
INSTALLER_LANGUAGES="${INSTALLER_LANGUAGES:-}"
# Language selected by the operator (or the default). Hooks can read this
# to write product-specific locale files into the target filesystem.
INSTALLER_LANG="${INSTALLER_LANG:-en}"

# Optional timeout for front-end UI requests (seconds).
UI_REQUEST_TIMEOUT="${UI_REQUEST_TIMEOUT:-60}"

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
    # Surface the failure in the SmoothGUI kiosk before the shell takes
    # over, so the operator can see what happened without scraping serial.
    if [ -n "${UI_STATE_DIR:-}" ]; then
        mkdir -p "$UI_STATE_DIR" 2>/dev/null || true
        local escaped
        escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r/\\r/g; s/	/\\t/g')
        printf '{"title":"Install failed","message":"%s","detail":"Check the serial console for diagnostics."}\n' \
            "$escaped" > "${UI_STATE_DIR}/status.json" 2>/dev/null || true
    fi
    exec /bin/sh
}

# Capture whiptail result to a temp file to avoid fd-swap contamination.
run_whiptail() {
    local _wt_tmp="/tmp/.wt-result"
    whiptail "$@" 2>"$_wt_tmp" </dev/console >/dev/console || true
    cat "$_wt_tmp" 2>/dev/null
    rm -f "$_wt_tmp"
}

# Escape a value for a simple JSON payload.
ui_escape_json() {
    printf '%s' "$1" \
        | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r/\\r/g; s/\n/\\n/g; s/\t/\\t/g'
}

ui_init_frontend() {
    mkdir -p /run || die "Unable to create /run for SmoothGUI state."

    # Bring up the loopback interface before the bridge tries to bind 127.0.0.1.
    # d-i's early_command runs before any networking step, so lo is created but
    # still DOWN — bind() then fails with EADDRNOTAVAIL and every backend looks
    # broken. Doing this here is cheap and idempotent.
    if command -v ip >/dev/null 2>&1; then
        ip link set lo up 2>/dev/null || true
        ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig lo 127.0.0.1 up 2>/dev/null || true
    fi

    if [ -d "$UI_FRONTEND_DIR" ] || [ "$SMOOTHGUI_ENABLE_FRONTEND" = "1" ] \
        || [ -n "${SMOOTHGUI_FRONTEND_DIR:-}" ]; then
        UI_FRONTEND_ENABLED=1
        mkdir -p "$UI_REQUEST_DIR" "$UI_RESPONSE_DIR" 2>/dev/null || true
    fi

    if [ "$UI_FRONTEND_ENABLED" = "1" ] && [ "$UI_FRONTEND_REQUIRED" = "1" ]; then
        if [ ! -d "$UI_FRONTEND_DIR" ] && [ -z "${SMOOTHGUI_FRONTEND_DIR:-}" ]; then
            die "SmoothGUI frontend required but no UI assets were discovered"
        fi
        if [ ! -f "${UI_FRONTEND_DIR}/index.html" ] && [ ! -f "${UI_FRONTEND_DIR}/index.installer.html" ]; then
            die "SmoothGUI frontend required but no index file was found in $UI_FRONTEND_DIR"
        fi
        if [ ! -d "$UI_REQUEST_DIR" ] || [ ! -d "$UI_RESPONSE_DIR" ]; then
            die "SmoothGUI frontend required but request directories are unavailable"
        fi
    fi

    if [ "$UI_FRONTEND_ENABLED" = "1" ]; then
        if [ ! -x "$UI_FRONTEND_BACKEND" ]; then
            if [ "$UI_FRONTEND_REQUIRED" = "1" ]; then
                die "SmoothGUI frontend bridge missing or not executable: $UI_FRONTEND_BACKEND"
            fi
            UI_FRONTEND_ENABLED=0
        else
            ui_start_frontend_server || {
                if [ "$UI_FRONTEND_REQUIRED" = "1" ]; then
                    die "SmoothGUI frontend bridge failed to start"
                fi
                UI_FRONTEND_ENABLED=0
            }
            ui_launch_frontend_viewer
        fi
    fi
}

ui_backend_log() {
    echo "${UI_STATE_DIR}/smoothiso-frontend.log"
}

ui_dump_frontend_log() {
    local log_file="$1"
    [ -s "$log_file" ] || return 0
    echo "SmoothGUI frontend log:"
    tail -n 40 "$log_file" >&2
}

ui_frontend_url() {
    if [ -f "${UI_FRONTEND_DIR}/index.installer.html" ]; then
        printf "http://127.0.0.1:%s/index.installer.html" "$SMOOTHGUI_FRONTEND_PORT"
        return
    fi
    printf "http://127.0.0.1:%s/index.html" "$SMOOTHGUI_FRONTEND_PORT"
}

ui_wait_frontend_http() {
    local url="$1"
    local timeout="$2"
    local wait_count=0

    [ -n "$url" ] || return 1
    if ! command -v wget >/dev/null 2>&1; then
        return 0
    fi

    while [ "$wait_count" -lt "$timeout" ]; do
        if wget -q -T 1 -O /tmp/smoothiso-frontcheck.html "$url" >/dev/null 2>&1; then
            rm -f /tmp/smoothiso-frontcheck.html
            return 0
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done
    return 1
}

ui_launch_frontend_viewer_command() {
    local template="$1"
    local url="$2"
    local rendered
    local binary
    local launcher_cmd
    local run_cmd
    local browser_user
    local firefox_env
    local escaped_rendered

    rendered=$(printf "$template" "$url")
    binary=$(printf '%s' "$rendered" | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i !~ /=/) {
                print $i
                exit
            }
        }
    }')
    [ -n "$binary" ] || return 1
    command -v "$binary" >/dev/null 2>&1 || return 1
    [ -x "$(command -v "$binary")" ] || return 1

    launcher_cmd="$rendered"
    if [ "$binary" = "firefox" ] || [ "$binary" = "firefox-esr" ]; then
        [ -n "${DISPLAY:-}" ] || return 1
        browser_user="${SMOOTHGUI_BROWSER_USER:-}"
        ui_ensure_browser_user || return 1
        mkdir -p "$SMOOTHGUI_FIREFOX_HOME" "$SMOOTHGUI_FIREFOX_RUNTIME"
        firefox_env="DISPLAY=$DISPLAY HOME=$SMOOTHGUI_FIREFOX_HOME XDG_RUNTIME_DIR=$SMOOTHGUI_FIREFOX_RUNTIME"
        firefox_env="$firefox_env MOZ_DISABLE_SAFE_MODE_KEY=1 MOZ_DBUS_SESSION_BUS_ADDRESS=\"$DBUS_SESSION_BUS_ADDRESS\""
        firefox_env="$firefox_env MOZ_X11_EGL=0 MOZ_WEBRENDER=0 MOZ_USE_XINPUT2=0 LIBGL_ALWAYS_SOFTWARE=1 MOZ_DISABLE_WAYLAND=1"
        # Note: NO `exec` here. `env A=B exec firefox-esr ...` makes env try to
        # execve("exec", ...) — exec is a shell builtin, not a binary. Drop it
        # and let `sh -c` exec the resulting command directly.
        launcher_cmd="env $firefox_env $rendered"
        escaped_rendered=$(printf '%s' "$launcher_cmd" | sed "s/'/'\\\\''/g")
        if [ -n "$browser_user" ] && command -v runuser >/dev/null 2>&1; then
            launcher_cmd="runuser -u ${browser_user} -- sh -c '$escaped_rendered'"
        elif [ -n "$browser_user" ] && command -v su >/dev/null 2>&1; then
            launcher_cmd="su -s /bin/sh ${browser_user} -c '$escaped_rendered'"
        fi
    fi

    run_cmd=$launcher_cmd
    sh -c "$run_cmd" </dev/console >"/tmp/smoothiso-browser.log" 2>&1 &
    UI_FRONTEND_VIEWER_PID=$!
    if [ -z "$UI_FRONTEND_VIEWER_PID" ]; then
        return 1
    fi
    sleep 1
    if ! kill -0 "$UI_FRONTEND_VIEWER_PID" 2>/dev/null; then
        sed -n '1,40p' /tmp/smoothiso-browser.log >&2 || true
        UI_FRONTEND_VIEWER_PID=""
        return 1
    fi
    sleep 2
    if [ "$binary" = "firefox" ] || [ "$binary" = "firefox-esr" ]; then
        if ! kill -0 "$UI_FRONTEND_VIEWER_PID" 2>/dev/null; then
            sed -n '1,80p' /tmp/smoothiso-browser.log >&2 || true
            UI_FRONTEND_VIEWER_PID=""
            return 1
        fi
    fi
    return 0
}

ui_start_frontend_server() {
    [ "$UI_FRONTEND_ENABLED" = "1" ] || return 1
    [ -x "$UI_FRONTEND_BACKEND" ] || return 1

    mkdir -p "${UI_STATE_DIR}"
    local backend_log
    backend_log="$(ui_backend_log)"
    rm -f "$backend_log"
    export UI_STATE_DIR UI_REQUEST_DIR UI_RESPONSE_DIR UI_FRONTEND_DIR \
        SMOOTHGUI_FRONTEND_BIND SMOOTHGUI_FRONTEND_PORT
    "$UI_FRONTEND_BACKEND" >"$backend_log" 2>&1 &
    UI_FRONTEND_SERVER_PID="$!"

    local wait_count=0
    while ! kill -0 "$UI_FRONTEND_SERVER_PID" 2>/dev/null; do
        wait_count=$((wait_count + 1))
        if [ "$wait_count" -ge 5 ]; then
            ui_dump_frontend_log "$backend_log"
            return 1
        fi
        sleep 1
    done
    return 0
}

ui_stop_frontend() {
    if [ -n "$UI_FRONTEND_SERVER_PID" ]; then
        kill "$UI_FRONTEND_SERVER_PID" 2>/dev/null || true
        UI_FRONTEND_SERVER_PID=""
    fi
    if [ -n "$UI_FRONTEND_VIEWER_PID" ]; then
        kill "$UI_FRONTEND_VIEWER_PID" 2>/dev/null || true
        UI_FRONTEND_VIEWER_PID=""
    fi
    if [ -n "$UI_FRONTEND_XVFB_PID" ]; then
        kill "$UI_FRONTEND_XVFB_PID" 2>/dev/null || true
        UI_FRONTEND_XVFB_PID=""
    fi
    if [ -n "$UI_FRONTEND_XORG_PID" ]; then
        kill "$UI_FRONTEND_XORG_PID" 2>/dev/null || true
        UI_FRONTEND_XORG_PID=""
    fi
    if [ -n "$UI_FRONTEND_DBUS_PID" ]; then
        kill "$UI_FRONTEND_DBUS_PID" 2>/dev/null || true
        UI_FRONTEND_DBUS_PID=""
    fi
}

ui_ensure_display() {
    if [ -n "${DISPLAY:-}" ]; then
        if command -v xdpyinfo >/dev/null 2>&1; then
            if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
                return 0
            fi
        fi
        unset DISPLAY
    fi

    if [ -d /etc/X11 ]; then
        printf 'allowed_users=anybody\nneeds_root_rights=no\n' > /etc/X11/Xwrapper.config 2>/dev/null || true
    else
        mkdir -p /etc/X11 2>/dev/null || true
        printf 'allowed_users=anybody\nneeds_root_rights=no\n' > /etc/X11/Xwrapper.config 2>/dev/null || true
    fi
    mkdir -p /tmp/.X11-unix 2>/dev/null || true
    chmod 1777 /tmp/.X11-unix 2>/dev/null || true

    local staged_gpu_modules_loaded=0
    if [ -r /smoothiso-gpu-modules.list ] && command -v insmod >/dev/null 2>&1; then
        local staged_module_rel
        local staged_module_path
        local staged_module_log
        local running_kernel
        running_kernel=$(uname -r)
        while IFS= read -r staged_module_rel; do
            [ -z "$staged_module_rel" ] && continue
            staged_module_path="/lib/modules/${running_kernel}/${staged_module_rel}"
            staged_module_log="/tmp/smoothiso-insmod-$(basename "$staged_module_rel").log"
            if [ -f "$staged_module_path" ] && \
                ! insmod "$staged_module_path" >"$staged_module_log" 2>&1; then
                if ! grep -Eiq 'file exists|already in kernel|module already loaded' "$staged_module_log" 2>/dev/null; then
                    echo "  WARNING: insmod ${staged_module_rel} failed:" >&2
                    sed -n '1,80p' "$staged_module_log" >&2 || true
                fi
            fi
        done < /smoothiso-gpu-modules.list
        staged_gpu_modules_loaded=1
    fi

    if [ "$staged_gpu_modules_loaded" != "1" ] && \
        [ -n "$INSTALLER_GPU_KERNEL_MODULES" ] && command -v modprobe >/dev/null 2>&1; then
        local display_module
        local modprobe_log
        for display_module in $INSTALLER_GPU_KERNEL_MODULES; do
            modprobe_log="/tmp/smoothiso-modprobe-${display_module}.log"
            if ! modprobe "$display_module" >"$modprobe_log" 2>&1; then
                echo "  WARNING: modprobe ${display_module} failed:" >&2
                sed -n '1,80p' "$modprobe_log" >&2 || true
            fi
        done
        if command -v udevadm >/dev/null 2>&1; then
            udevadm settle --timeout=5 >/dev/null 2>&1 || true
        fi
    fi

    if [ -n "$INSTALLER_GPU_KERNEL_MODULES" ] || [ -r /smoothiso-gpu-modules.list ]; then
        if command -v udevadm >/dev/null 2>&1; then
            udevadm settle --timeout=5 >/dev/null 2>&1 || true
        fi
        if [ ! -e /dev/dri/card0 ]; then
            echo "  WARNING: no /dev/dri/card0 after installer GPU module load." >&2
            if command -v dmesg >/dev/null 2>&1; then
                dmesg 2>/dev/null | grep -Ei 'amdgpu|radeon|drm|firmware' | tail -80 >&2 || true
            fi
        fi
    fi

    if command -v Xorg >/dev/null 2>&1; then
        mkdir -p /tmp/smoothiso-ui
        local xorg_attempt
        local xorg_driver
        local wait_count
        local xorg_base_args
        local xorg_driver_conf

        # Xorg rejects Xvfb-style geometry args (`-screen 0 WxH -depth N` etc.) —
        # passing them makes Xorg print its help text and exit. Resolution is
        # configured via the per-driver xorg.conf snippet below instead.
        xorg_base_args="-noreset -ac -nolisten tcp -br -novtswitch"

        for xorg_attempt in vt7 vt1 ""; do
            for xorg_driver in auto vesa modesetting fbdev; do
                if [ "$xorg_driver" = "auto" ]; then
                    xorg_driver_conf=""
                else
                    xorg_driver_conf="/tmp/smoothiso-xorg-${xorg_driver}.conf"
                    cat > "$xorg_driver_conf" <<EOF
Section "Device"
    Identifier "SmoothGUI"
    Driver "${xorg_driver}"
EndSection

Section "Monitor"
    Identifier "SmoothGUI-Monitor"
    HorizSync 28.0-80.0
    VertRefresh 48.0-75.0
EndSection

Section "Screen"
    Identifier "SmoothGUI-Screen"
    Device "SmoothGUI"
    Monitor "SmoothGUI-Monitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1280x720" "1024x768" "800x600"
    EndSubSection
EndSection
EOF
                fi

                if [ -n "$xorg_attempt" ]; then
                    Xorg "$SMOOTHGUI_DISPLAY" "$xorg_attempt" $xorg_base_args ${xorg_driver_conf:+-config "$xorg_driver_conf"} >/tmp/smoothiso-xorg.log 2>&1 &
                else
                    Xorg "$SMOOTHGUI_DISPLAY" $xorg_base_args ${xorg_driver_conf:+-config "$xorg_driver_conf"} >/tmp/smoothiso-xorg.log 2>&1 &
                fi
                UI_FRONTEND_XORG_PID=$!

                wait_count=0
                while [ "$wait_count" -lt "$SMOOTHGUI_XORG_STARTUP_TIMEOUT" ]; do
                    sleep 1
                    wait_count=$((wait_count + 1))
                    if ! kill -0 "$UI_FRONTEND_XORG_PID" 2>/dev/null; then
                        break
                    fi
                    if command -v xdpyinfo >/dev/null 2>&1; then
                        if xdpyinfo -display "$SMOOTHGUI_DISPLAY" >/dev/null 2>&1; then
                            export DISPLAY="$SMOOTHGUI_DISPLAY"
                            if command -v xhost >/dev/null 2>&1 && [ -n "${SMOOTHGUI_BROWSER_USER:-}" ]; then
                                xhost +SI:localuser:"$SMOOTHGUI_BROWSER_USER" >/tmp/smoothiso-xhost.log 2>&1 || true
                            fi
                            return 0
                        fi
                    else
                        export DISPLAY="$SMOOTHGUI_DISPLAY"
                        if command -v xhost >/dev/null 2>&1 && [ -n "${SMOOTHGUI_BROWSER_USER:-}" ]; then
                            xhost +SI:localuser:"$SMOOTHGUI_BROWSER_USER" >/tmp/smoothiso-xhost.log 2>&1 || true
                        fi
                        return 0
                    fi
                done

                kill "$UI_FRONTEND_XORG_PID" 2>/dev/null || true
                wait "$UI_FRONTEND_XORG_PID" 2>/dev/null || true
                UI_FRONTEND_XORG_PID=""
                sed -n '1,120p' /tmp/smoothiso-xorg.log >&2 || true
            done
        done
        [ "$SMOOTHGUI_REQUIRE_VISIBLE_DISPLAY" = "1" ] && return 1
    fi

    if [ "${SMOOTHGUI_ALLOW_XVFB:-0}" != "1" ]; then
        return 1
    fi

    if ! command -v Xvfb >/dev/null 2>&1; then
        return 1
    fi
    mkdir -p /tmp/smoothiso-ui
    Xvfb "$SMOOTHGUI_DISPLAY" -screen 0 1280x720 -depth 24 >/tmp/smoothiso-xvfb.log 2>&1 &
    UI_FRONTEND_XVFB_PID=$!
    sleep 1
    if ! kill -0 "$UI_FRONTEND_XVFB_PID" 2>/dev/null; then
        UI_FRONTEND_XVFB_PID=""
        return 1
    fi

    export DISPLAY="$SMOOTHGUI_DISPLAY"
    if command -v xdpyinfo >/dev/null 2>&1; then
        if ! xdpyinfo -display "$SMOOTHGUI_DISPLAY" >/dev/null 2>&1; then
            kill "$UI_FRONTEND_XVFB_PID" 2>/dev/null || true
            UI_FRONTEND_XVFB_PID=""
            return 1
        fi
    fi
    if command -v xhost >/dev/null 2>&1 && [ -n "${SMOOTHGUI_BROWSER_USER:-}" ]; then
        xhost +SI:localuser:"$SMOOTHGUI_BROWSER_USER" >/tmp/smoothiso-xhost.log 2>&1 || true
    fi
    return 0
}

ui_ensure_browser_user() {
    local user="${SMOOTHGUI_BROWSER_USER:-}"
    local uid="${SMOOTHGUI_BROWSER_UID:-1000}"
    local gid="${SMOOTHGUI_BROWSER_GID:-1000}"

    [ -z "$user" ] && return 0
    [ -d "$SMOOTHGUI_FIREFOX_HOME" ] || mkdir -p "$SMOOTHGUI_FIREFOX_HOME"
    [ -d "$SMOOTHGUI_FIREFOX_RUNTIME" ] || mkdir -p "$SMOOTHGUI_FIREFOX_RUNTIME"

    if id "$user" >/dev/null 2>&1; then
        chown -R "${uid}:${gid}" "$SMOOTHGUI_FIREFOX_HOME" "$SMOOTHGUI_FIREFOX_RUNTIME" 2>/dev/null || true
        return 0
    fi

    if command -v useradd >/dev/null 2>&1; then
        useradd -M -N -u "$uid" -g "$gid" -s /bin/sh -d "$SMOOTHGUI_FIREFOX_HOME" "$user" 2>/dev/null || \
            useradd -M -u "$uid" -g "$gid" -s /bin/sh "$user" 2>/dev/null || \
            useradd -M "$user" 2>/dev/null || return 1
        chown -R "${uid}:${gid}" "$SMOOTHGUI_FIREFOX_HOME" "$SMOOTHGUI_FIREFOX_RUNTIME" 2>/dev/null || true
        return 0
    fi

    grep -q "^${gid}:" /etc/group 2>/dev/null || printf "%s:x:%s:\n" "$user" "$gid" >> /etc/group
    grep -q "^${user}:x:${uid}:" /etc/passwd 2>/dev/null || \
        printf "%s:x:%s:%s:SmoothISO Browser User:%s:/bin/sh\n" "$user" "$uid" "$gid" "$SMOOTHGUI_FIREFOX_HOME" >> /etc/passwd
    chown -R "${uid}:${gid}" "$SMOOTHGUI_FIREFOX_HOME" "$SMOOTHGUI_FIREFOX_RUNTIME" 2>/dev/null || true
}

ui_ensure_dbus() {
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        return 0
    fi

    if ! command -v dbus-daemon >/dev/null 2>&1; then
        return 1
    fi

    local dbus_info
    local dbus_addr
    local dbus_pid

    # --print-address=1 and --print-pid=1 write to fd 1 (stdout); using the
    # =FD form avoids newer dbus-daemon consuming the next flag as the fd arg.
    dbus_info="$(dbus-daemon --session --fork --print-address=1 --print-pid=1 2>/tmp/smoothiso-dbus.err || true)"
    dbus_addr="$(printf '%s\n' "$dbus_info" | sed -n '1p')"
    dbus_pid="$(printf '%s\n' "$dbus_info" | sed -n '2p')"
    [ -n "$dbus_addr" ] || return 1

    DBUS_SESSION_BUS_ADDRESS="$dbus_addr"
    export DBUS_SESSION_BUS_ADDRESS
    UI_FRONTEND_DBUS_PID="$dbus_pid"
    return 0
}

ui_require_frontend() {
    [ "$UI_FRONTEND_ENABLED" = "1" ] || die "SmoothGUI frontend required but was not initialized."
}

ui_handle_timeout() {
    local label="$1"
    if [ "$UI_FRONTEND_REQUIRED" = "1" ]; then
        die "Timed out waiting for SmoothGUI installer response while ${label}."
    fi
    return 1
}

ui_ensure_frontend_alive() {
    [ "$UI_FRONTEND_ENABLED" = "1" ] || return 1
    [ -n "$UI_FRONTEND_SERVER_PID" ] || return 1
    kill -0 "$UI_FRONTEND_SERVER_PID" 2>/dev/null || return 1
    return 0
}

ui_launch_frontend_viewer() {
    [ "$UI_FRONTEND_ENABLED" = "1" ] || return 0
    if [ "$UI_FRONTEND_VIEWER_LAUNCHED" = "1" ]; then
        return 0
    fi

    if ! ui_ensure_display; then
        ui_dump_frontend_log "$(ui_backend_log)"
        if [ "$UI_FRONTEND_REQUIRED" = "1" ]; then
            die "SmoothGUI frontend failed to initialize display."
        fi
        return 0
    fi
    if ! ui_ensure_dbus; then
        ui_dump_frontend_log "$(ui_backend_log)"
        if [ "$UI_FRONTEND_REQUIRED" = "1" ]; then
            die "SmoothGUI frontend failed to start D-Bus session."
        fi
        return 0
    fi

    if ! ui_ensure_frontend_alive; then
        ui_start_frontend_server || true
    fi
    if ! ui_ensure_frontend_alive; then
        ui_dump_frontend_log "$(ui_backend_log)"
        die "SmoothGUI frontend backend unavailable while starting installer UI."
    fi

    local frontend_url
    local launched
    local custom_viewer_cmd
    launched=0
    frontend_url="$(ui_frontend_url)"
    custom_viewer_cmd="${SMOOTHGUI_VIEWER_COMMAND:-}"

    if ! ui_wait_frontend_http "$frontend_url" "$SMOOTHGUI_FRONTEND_READY_TIMEOUT"; then
        if [ "$UI_FRONTEND_REQUIRED" = "1" ]; then
            ui_dump_frontend_log "$(ui_backend_log)"
            die "SmoothGUI frontend failed to start HTTP service on ${frontend_url}."
        fi
        return 0
    fi

    if [ -n "$custom_viewer_cmd" ]; then
        if ui_launch_frontend_viewer_command "$custom_viewer_cmd" "$frontend_url"; then
            launched=1
        fi
    fi

    if [ "$launched" -ne 1 ]; then
        # `--app=URL` was the SSB / Single-Site-Browser flag; Firefox 78
        # removed support without printing an error, so the browser silently
        # falls back to its default homepage. Modern builds (Firefox ESR 12x)
        # need `--kiosk URL` instead.
        for candidate in \
            "firefox-esr --kiosk --no-remote %s" \
            "firefox --kiosk --no-remote %s"; do
            if ui_launch_frontend_viewer_command "$candidate" "$frontend_url"; then
                launched=1
                break
            fi
        done
    fi

    if [ "$launched" -ne 1 ] || [ -z "$UI_FRONTEND_VIEWER_PID" ]; then
        if [ "$UI_FRONTEND_REQUIRED" = "1" ]; then
            ui_dump_frontend_log "$(ui_backend_log)"
            die "SmoothGUI frontend viewer unavailable in installer environment."
        fi
        return 0
    fi

    echo "SmoothGUI browser launched for installer UI." >/dev/console
    UI_FRONTEND_VIEWER_LAUNCHED=1
}

ui_request_id() {
    date +%s.%N 2>/dev/null | tr -cd '0-9' | head -c 32
}

ui_read_json_string_from_stdin() {
    local key="$1"
    sed -n "s/.*\\\"${key}\\\"[[:space:]]*:[[:space:]]*\\\"\\([^\"]*\\)\\\".*/\\1/p" | head -n 1
}

ui_read_json_array_from_stdin() {
    local key="$1"
    local raw
    raw=$(sed -n "s/.*\\\"${key}\\\"[[:space:]]*:[[:space:]]*\\[\\(.*\\)\\].*/\\1/p" | head -n 1)
    raw=$(printf '%s' "$raw" | tr -d '[]"' | tr ',' ' ')
    printf '%s' "$raw"
}

ui_cleanup_frontend_entry() {
    local req_id="$1"
    [ -z "$req_id" ] && return
    rm -f "${UI_REQUEST_DIR}/${req_id}.json" \
          "${UI_RESPONSE_DIR}/${req_id}.json" 2>/dev/null || true
}

ui_write_request() {
    local kind="$1"
    local title="$2"
    local message="$3"
    local payload="$4"
    local req_id

    req_id="$(ui_request_id)"
    mkdir -p "$UI_REQUEST_DIR" "$UI_RESPONSE_DIR" 2>/dev/null || true
    cat > "${UI_REQUEST_DIR}/${req_id}.json" <<EOF
{
  "id": "${req_id}",
  "kind": "${kind}",
  "title": "$(ui_escape_json "$title")",
  "message": "$(ui_escape_json "$message")",
  "payload": ${payload}
}
EOF
    echo "$req_id"
}

ui_wait_response() {
    local req_id="$1"
    local max_wait="${2:-$UI_REQUEST_TIMEOUT}"
    local label="${3:-installer response}"
    local start now elapsed
    start=$(date +%s)

    while :; do
        if ! ui_ensure_frontend_alive; then
            ui_dump_frontend_log "$(ui_backend_log)"
            if [ "$UI_FRONTEND_REQUIRED" = "1" ]; then
                die "SmoothGUI frontend backend stopped while ${label}."
            fi
            return 1
        fi

        if [ -f "${UI_RESPONSE_DIR}/${req_id}.json" ]; then
            cat "${UI_RESPONSE_DIR}/${req_id}.json"
            return 0
        fi

        now=$(date +%s)
        elapsed=$((now - start))
        [ "$elapsed" -ge "$max_wait" ] && return 1
        sleep 1
    done
}

ui_read_json_string() {
    local key="$1"
    local file="$2"
    cat "$file" | ui_read_json_string_from_stdin "$key"
}

ui_read_json_array() {
    local key="$1"
    local file="$2"
    cat "$file" | ui_read_json_array_from_stdin "$key"
}

ui_prompt_text() {
    [ "$UI_FRONTEND_ENABLED" = "1" ] || return 1

    local title="$1"
    local message="$2"
    local default_value="$3"
    local req_id
    local answer_file
    local response
    local value

    ui_launch_frontend_viewer
    req_id=$(ui_write_request "text" "$title" "$message" \
        "{\"default\": \"$(ui_escape_json "$default_value")\"}")
    response=$(ui_wait_response "$req_id" "$UI_FRONTEND_TIMEOUT" "$title") \
        || ui_handle_timeout "collecting text input"
    value=$(printf '%s' "$response" | ui_read_json_string_from_stdin "value" | tr -d '\r')
    if [ -z "$value" ]; then
        value=$(printf '%s' "$response" | ui_read_json_string_from_stdin "answer" | tr -d '\r')
    fi

    ui_cleanup_frontend_entry "$req_id"
    printf '%s' "$value"
}

ui_prompt_password() {
    [ "$UI_FRONTEND_ENABLED" = "1" ] || return 1

    local title="$1"
    local message="$2"
    local req_id
    local response
    local value

    ui_launch_frontend_viewer
    req_id=$(ui_write_request "password" "$title" "$message" "{}")
    response=$(ui_wait_response "$req_id" "$UI_FRONTEND_TIMEOUT" "$title") \
        || ui_handle_timeout "collecting password"
    value=$(printf '%s' "$response" | ui_read_json_string_from_stdin "value" | tr -d '\r')
    if [ -z "$value" ]; then
        value=$(printf '%s' "$response" | ui_read_json_string_from_stdin "answer" | tr -d '\r')
    fi

    ui_cleanup_frontend_entry "$req_id"
    printf '%s' "$value"
}

ui_prompt_checklist() {
    [ "$UI_FRONTEND_ENABLED" = "1" ] || return 1

    local title="$1"
    local message="$2"
    local options="$3"
    local req_id
    local response
    local values

    ui_launch_frontend_viewer
    req_id=$(ui_write_request "checklist" "$title" "$message" \
        "{\"multiple\":true,\"options\": ${options}}")
    response=$(ui_wait_response "$req_id" "$UI_FRONTEND_TIMEOUT" "$title") \
        || ui_handle_timeout "collecting checklist"
    values=$(printf '%s' "$response" | ui_read_json_array_from_stdin "selected")
    if [ -z "$values" ]; then
        values=$(printf '%s' "$response" | ui_read_json_array_from_stdin "value")
    fi

    ui_cleanup_frontend_entry "$req_id"
    printf '%s' "$values"
}

ui_notify() {
    [ "$UI_FRONTEND_ENABLED" = "1" ] || return 0

    local title="$1"
    local message="$2"
    ui_write_request "notice" "$title" "$message" "{}" >/dev/null
}

# ui_status TITLE [MESSAGE [CURRENT TOTAL [DETAIL]]]
# Writes a non-blocking status payload that the SmoothGUI client polls via
# /cgi-bin/status. Use this between blocking ui_prompt_* calls to surface
# progress during long automated steps (debootstrap, package install,
# configure, GRUB).
ui_status() {
    local title="${1:-}"
    local message="${2:-}"
    local current="${3:-}"
    local total="${4:-}"
    local detail="${5:-}"
    local fields=""

    [ -n "$title" ] && fields="${fields}\"title\":\"$(ui_escape_json "$title")\","
    [ -n "$message" ] && fields="${fields}\"message\":\"$(ui_escape_json "$message")\","
    if [ -n "$current" ] && [ -n "$total" ]; then
        fields="${fields}\"current\":${current},\"total\":${total},"
    fi
    [ -n "$detail" ] && fields="${fields}\"detail\":\"$(ui_escape_json "$detail")\","

    fields="${fields%,}"
    mkdir -p "$UI_STATE_DIR" 2>/dev/null || true
    printf '{%s}\n' "$fields" > "${UI_STATE_DIR}/status.json"
}

ui_clear_status() {
    rm -f "${UI_STATE_DIR}/status.json" 2>/dev/null || true
}

ui_wait() {
    [ "$UI_FRONTEND_ENABLED" = "1" ] || return 1

    local title="$1"
    local message="$2"
    local req_id
    local response

    ui_launch_frontend_viewer
    req_id=$(ui_write_request "confirm" "$title" "$message" "{}")
    response=$(ui_wait_response "$req_id" "$UI_FRONTEND_TIMEOUT" "$title") \
        || ui_handle_timeout "waiting for installer confirmation"
    ui_cleanup_frontend_entry "$req_id"
    return 0
}

# Ensure the volume group's logical volumes have working /dev/${VG}/${LV}
# device entries. The d-i installer ships without the LVM udev rules that
# normally create /dev/dm-N + /dev/mapper/* + /dev/${VG}/${LV} when LVs are
# activated, so we have to (re)build the chain by hand. mkfs may have
# succeeded earlier through one of the symlink layers, but mount is
# stricter and fails with ENODEV when the /dev/dm-N target is missing.
ensure_lvm_nodes() {
    local vg="$1"
    local mapper_name target mapper

    echo "  ensure_lvm_nodes($vg): start"

    mkdir -p /dev/mapper "/dev/${vg}"
    if [ ! -e /dev/mapper/control ]; then
        echo "  ensure_lvm_nodes: creating /dev/mapper/control"
        mknod /dev/mapper/control c 10 236 2>/dev/null || true
    fi

    echo "  ensure_lvm_nodes: vgchange -ay"
    vgchange -ay "$vg" 2>&1 | sed 's/^/    /' || true
    echo "  ensure_lvm_nodes: vgscan --mknodes"
    vgscan --mknodes 2>&1 | sed 's/^/    /' || true
    echo "  ensure_lvm_nodes: vgmknodes"
    vgmknodes "$vg" 2>&1 | sed 's/^/    /' || true
    if command -v dmsetup >/dev/null 2>&1; then
        echo "  ensure_lvm_nodes: dmsetup mknodes"
        dmsetup mknodes 2>&1 | sed 's/^/    /' || true
    else
        echo "  ensure_lvm_nodes: dmsetup not present; skipping"
    fi
    echo "  ensure_lvm_nodes: udevadm settle"
    udevadm settle --timeout=5 2>&1 | sed 's/^/    /' || sleep 1

    echo "  ensure_lvm_nodes: lvs snapshot"
    lvs --noheadings --nosuffix \
        -o lv_name,lv_kernel_major,lv_kernel_minor "$vg" 2>&1 | sed 's/^/    /' || true

    # Fallback: synthesize the device files directly from lvs's
    # kernel major:minor when the symlink layers are still broken.
    # Use a here-string into a plain while-read so we stay in the
    # outer shell (the subshell `lvs ... | while` swallows variable
    # writes, which is mostly cosmetic but matters for diagnostics).
    local lv_dump
    lv_dump=$(lvs --noheadings --nosuffix \
        -o lv_name,lv_kernel_major,lv_kernel_minor "$vg" 2>/dev/null || true)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # shellcheck disable=SC2086
        set -- $line
        local lv="${1:-}" maj="${2:-}" min="${3:-}"
        [ -n "$lv" ] && [ -n "$maj" ] && [ -n "$min" ] || continue
        target="/dev/${vg}/${lv}"
        mapper_name=$(printf '%s' "${vg}" | sed 's/-/--/g')-$(printf '%s' "${lv}" | sed 's/-/--/g')
        mapper="/dev/mapper/${mapper_name}"
        if [ -b "$target" ]; then
            echo "  ensure_lvm_nodes: ${target} already a block device"
            continue
        fi
        echo "  ensure_lvm_nodes: synthesizing ${mapper} -> b ${maj}:${min}"
        rm -f "$target" 2>/dev/null || true
        rm -f "$mapper" 2>/dev/null || true
        mknod "$mapper" b "$maj" "$min" 2>/dev/null || true
        ln -sf "$mapper" "$target" 2>/dev/null || true
    done <<EOF
$lv_dump
EOF

    echo "  ensure_lvm_nodes: final ls /dev/${vg}"
    ls -la "/dev/${vg}" 2>&1 | sed 's/^/    /' || true
    echo "  ensure_lvm_nodes: /dev/mapper listing"
    ls -la /dev/mapper 2>&1 | sed 's/^/    /' || true
    echo "  ensure_lvm_nodes: dm-* nodes"
    ls -la /dev/dm-* 2>&1 | sed 's/^/    /' || true

    [ -e "/dev/${vg}" ] || return 1
    return 0
}

# Make sure the named filesystem driver is registered with the kernel,
# loading it via modprobe / insmod fallbacks if it is not. Required
# before mount() — mkfs is a userspace operation that does not need a
# kernel filesystem driver, so it can succeed on a system where mount()
# would later return ENODEV ("No such device").
ensure_filesystem_module() {
    local fs="$1"

    if grep -qE "[[:space:]]${fs}\$" /proc/filesystems 2>/dev/null; then
        return 0
    fi

    echo "  ensure_filesystem_module: loading $fs"
    modprobe "$fs" 2>&1 | sed 's/^/    /' || true

    if grep -qE "[[:space:]]${fs}\$" /proc/filesystems 2>/dev/null; then
        return 0
    fi

    # modprobe in the d-i ramdisk fails when modules.dep is missing or
    # incomplete, so fall back to loading dependency .ko files directly.
    # Search both /lib/modules and /usr/lib/modules — d-i is not
    # usr-merged but the host build can be.
    local deps
    case "$fs" in
        ext4) deps="crc16 crc32c_generic mbcache jbd2" ;;
        ext3|ext2) deps="jbd2 mbcache" ;;
        vfat) deps="fat nls_cp437 nls_ascii nls_utf8" ;;
        *) deps="" ;;
    esac
    for dep in $deps; do
        for ko in $(find /lib/modules /usr/lib/modules -name "${dep}.ko*" 2>/dev/null); do
            insmod "$ko" 2>/dev/null || true
        done
    done
    for ko in $(find /lib/modules /usr/lib/modules -name "${fs}.ko*" 2>/dev/null); do
        insmod "$ko" 2>/dev/null || true
    done

    if grep -qE "[[:space:]]${fs}\$" /proc/filesystems 2>/dev/null; then
        return 0
    fi

    echo "  ensure_filesystem_module: $fs still missing — /proc/filesystems:"
    sed 's/^/    /' /proc/filesystems 2>/dev/null || true
    echo "  ensure_filesystem_module: looked under:"
    find /lib/modules /usr/lib/modules -maxdepth 4 -name "${fs}.ko*" \
        2>/dev/null | sed 's/^/    /' || true
    return 1
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

    local kver
    kver=$(uname -r)
    # The d-i ramdisk does not have a `modules.dep` file for the
    # extracted kernel modules, so plain `modprobe` fails with
    # "can't open 'modules.dep': No such file or directory" and
    # cannot resolve dependencies. Generate it now from whatever
    # modules build-iso.sh stamped into /lib/modules/${kver}.
    # Modern Debian uses a usr-merged layout, but the d-i installer
    # ramdisk does not, so we cover both paths.
    local mod_dir=""
    for candidate in "/lib/modules/${kver}" "/usr/lib/modules/${kver}"; do
        [ -d "$candidate" ] && { mod_dir="$candidate"; break; }
    done
    if [ -n "$mod_dir" ]; then
        echo "  Generating module dependencies at ${mod_dir}..."
        depmod -a 2>&1 | sed 's/^/    /' || \
            depmod -b / "$kver" 2>&1 | sed 's/^/    /' || true
    fi

    echo "  Loading modules..."
    for mod in virtio_pci virtio_scsi virtio_blk sd_mod ahci nvme scsi_mod \
               dm_mod dm_linear dm_striped dm_snapshot; do
        modprobe "$mod" 2>/dev/null || true
    done
    for mod in vfat fat nls_cp437 nls_ascii nls_utf8; do
        modprobe "$mod" 2>/dev/null || true
    done
    for mod in ext4 jbd2 crc16 crc32c_generic mbcache; do
        modprobe "$mod" 2>/dev/null || true
    done

    local mbase="${mod_dir:-/lib/modules/${kver}}/kernel"

    insmod "${mbase}/drivers/md/dm-mod.ko.xz" 2>/dev/null || true

    if ! grep -qE '[[:space:]]ext4$' /proc/filesystems 2>/dev/null; then
        for ko in $(find /lib/modules /usr/lib/modules \
            \( -name 'jbd2.ko*' -o -name 'mbcache.ko*' -o -name 'crc16.ko*' \
               -o -name 'crc32c_generic.ko*' \) 2>/dev/null); do
            insmod "$ko" 2>/dev/null || true
        done
        for ko in $(find /lib/modules /usr/lib/modules -name 'ext4.ko*' 2>/dev/null); do
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

    echo "  /proc/filesystems:"
    sed 's/^/    /' /proc/filesystems 2>/dev/null || true
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
        # Only consider real NICs. The installer ramdisk loads modules that
        # create virtual interfaces (dummy0, ifb0/ifb1, eql, ...); none of them
        # can ever get a DHCP lease, but the discovery loop below was spending a
        # full ~18s DHCP timeout on each, adding over a minute to every install.
        # Physical interfaces have a /sys/class/net/<name>/device link to their
        # backing PCI/USB device; virtual ones do not.
        [ -e "$dev/device" ] || continue
        ifaces="$ifaces $name"
        iface_count=$((iface_count + 1))
    done
    ifaces=$(echo "$ifaces" | sed 's/^ //')

    # Fall back to all non-loopback interfaces if the device-link filter found
    # nothing (some exotic NIC drivers don't expose the link) so we never strand
    # an install with no network to probe.
    if [ -z "$ifaces" ]; then
        for dev in /sys/class/net/*; do
            local name=$(basename "$dev")
            [ "$name" = "lo" ] && continue
            ifaces="$ifaces $name"
            iface_count=$((iface_count + 1))
        done
        ifaces=$(echo "$ifaces" | sed 's/^ //')
    fi

    [ -z "$ifaces" ] && die "No network interface found"

    echo "  Found $iface_count interface(s): $ifaces"
    echo "  Bringing interfaces up..."
    # Plain `wait` would block on every child of the installer, including
    # the long-running Firefox/Xorg/dbus/httpd processes spawned from
    # ui_init_frontend — and hang forever. Capture PIDs and wait only for
    # the link-up commands.
    local link_pids=""
    for iface in $ifaces; do
        ip link set "$iface" up &
        link_pids="$link_pids $!"
    done
    if [ -n "$link_pids" ]; then
        # shellcheck disable=SC2086
        wait $link_pids 2>/dev/null || true
    fi
    sleep 1

    echo "  Network discovery complete."
    echo "  Trying DHCP on all interfaces..."
    local dhcp_tmpdir
    local dhcp_pid
    local dhcp_wait=0
    local dhcp_timeout=18
    local dhcp_iface

    dhcp_tmpdir="$(mktemp -d)"
    for iface in $ifaces; do
        echo "  DHCP attempt on ${iface}..."
        (
            if command -v dhclient >/dev/null 2>&1; then
                dhclient -v "$iface" 2>/dev/null && \
                    touch "$dhcp_tmpdir/$iface"
            elif command -v udhcpc >/dev/null 2>&1; then
                udhcpc -i "$iface" -n -q 2>/dev/null && \
                    touch "$dhcp_tmpdir/$iface"
            fi
        ) &
        dhcp_pid=$!

        dhcp_wait=0
        while [ "$dhcp_wait" -lt "$dhcp_timeout" ]; do
            if [ -f "$dhcp_tmpdir/$iface" ]; then
                break
            fi
            if ! kill -0 "$dhcp_pid" 2>/dev/null; then
                break
            fi
            dhcp_wait=$((dhcp_wait + 1))
            sleep 1
        done

        if kill -0 "$dhcp_pid" 2>/dev/null; then
            kill "$dhcp_pid" 2>/dev/null || true
            wait "$dhcp_pid" 2>/dev/null || true
        else
            wait "$dhcp_pid" 2>/dev/null || true
        fi
        if [ ! -f "$dhcp_tmpdir/$iface" ]; then
            echo "  ${iface}: DHCP did not return an address within ${dhcp_timeout}s."
        fi
    done

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
    local manual_ip gateway dns

    if [ "${SMOOTHISO_SKIP_MANUAL_NETWORK:-1}" = "1" ]; then
        echo "  Manual network configuration skipped by installer policy."
        echo "  Continuing without network configuration."
        return
    fi

    if [ "$UI_FRONTEND_ENABLED" = "1" ]; then
        ui_require_frontend
        manual_ip=$(ui_prompt_text \
            "Network Configuration" \
            "DHCP failed. Configure ${manual_iface} manually.\nEnter IP address (CIDR, e.g. 192.168.1.100/24):" \
            "")
        [ -z "$manual_ip" ] && die "No IP address provided."
        gateway=$(ui_prompt_text \
            "Network Configuration" \
            "Enter gateway IP address for ${manual_iface}:" \
            "")
        if [ -z "$gateway" ]; then gateway=""; fi
        dns=$(ui_prompt_text \
            "Network Configuration" \
            "Enter DNS server IP (defaults to 8.8.8.8):" \
            "8.8.8.8")
        if [ -z "$dns" ]; then dns="8.8.8.8"; fi
    else
        manual_ip=$(run_whiptail \
            --title "Network Configuration" \
            --inputbox "DHCP failed. Configure ${manual_iface} manually.\nEnter IP address (CIDR, e.g. 192.168.1.100/24):" \
            10 70 "") || manual_ip=""
        [ -z "$manual_ip" ] && die "No IP address provided."
        gateway=$(run_whiptail \
            --title "Network Configuration" \
            --inputbox "Enter gateway IP address for ${manual_iface}:" \
            10 60 "") || gateway=""
        dns=$(run_whiptail \
            --title "Network Configuration" \
            --inputbox "Enter DNS server IP (defaults to 8.8.8.8):" \
            10 60 "8.8.8.8") || dns=""
        [ -z "$dns" ] && dns="8.8.8.8"
    fi

    echo "  Network configured on $manual_iface."
}

# ============================================================
# 2b. Deferred browser install
# ============================================================

install_browser_deferred() {
    [ "${INSTALLER_BROWSER_DEFERRED:-0}" = "1" ] || return 0
    local browser_pkg="${INSTALLER_BROWSER_PKG:-firefox-esr}"
    local aux_pkgs="${INSTALLER_BROWSER_AUX_PKGS:-xvfb xinit x11-utils x11-xserver-utils xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-input-evdev xserver-xorg-video-fbdev xserver-xorg-video-vesa xserver-xorg-video-qxl xserver-xorg-video-all xserver-xorg-input-all xfonts-base xfonts-100dpi xfonts-75dpi libegl1 dbus dbus-x11 firmware-linux-free}"

    # Already available — nothing to do.
    if command -v "$browser_pkg" >/dev/null 2>&1 || \
       command -v firefox-esr >/dev/null 2>&1 || \
       command -v firefox >/dev/null 2>&1; then
        return 0
    fi

    msg "Downloading installer browser"
    echo "  Network is up; fetching ${browser_pkg} and display stack from apt..."
    echo "  (This takes a minute — the installer UI will appear once complete.)"

    if ! apt-get update -qq 2>/dev/null; then
        echo "  WARNING: apt-get update failed; attempting install anyway."
    fi

    # shellcheck disable=SC2086
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
            "$browser_pkg" $aux_pkgs \
            2>&1 | grep -v "^debconf:" | sed 's/^/    /'; then
        die "Failed to install installer browser (${browser_pkg}). Check network."
    fi
    echo "  Browser installed."
}

# ============================================================
# 2c. Sync clock
# ============================================================

sync_clock() {
    msg "Syncing system clock"
    local clock_tmpdir
    local clock_pid
    local clock_wait=0
    local clock_timeout=12

    if command -v ntpd >/dev/null 2>&1; then
        echo "  Trying NTP sync..."
        (
            ntpd -dnqp pool.ntp.org 2>/dev/null
        ) &
        clock_pid=$!
        while [ "$clock_wait" -lt "$clock_timeout" ]; do
            if ! kill -0 "$clock_pid" 2>/dev/null; then
                break
            fi
            clock_wait=$((clock_wait + 1))
            sleep 1
        done
        if kill -0 "$clock_pid" 2>/dev/null; then
            kill "$clock_pid" 2>/dev/null || true
            wait "$clock_pid" 2>/dev/null || true
            echo "  NTP failed, falling back to HTTP date..."
        else
            if wait "$clock_pid" 2>/dev/null; then
                echo "  Clock set via NTP: $(date -u)"
                return
            fi
            echo "  NTP failed, falling back to HTTP date..."
        fi
    fi

    local http_date=""
    clock_tmpdir="$(mktemp -d)"
    (
        wget -qS --spider \
            "$DEBIAN_MIRROR/dists/$DEBIAN_SUITE/Release" 2>&1 \
            | sed -n 's/^ *Date: *//p' | head -1 \
            >"${clock_tmpdir}/http_date.txt"
    ) &
    clock_pid=$!
    clock_wait=0
    while [ "$clock_wait" -lt "$clock_timeout" ]; do
        if ! kill -0 "$clock_pid" 2>/dev/null; then
            break
        fi
        clock_wait=$((clock_wait + 1))
        sleep 1
    done
    if kill -0 "$clock_pid" 2>/dev/null; then
        kill "$clock_pid" 2>/dev/null || true
        wait "$clock_pid" 2>/dev/null || true
    fi
    http_date="$(sed -n '1p' "${clock_tmpdir}/http_date.txt" 2>/dev/null || true)"
    rm -rf "$clock_tmpdir"

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
# 2b. Language selection
# ============================================================

select_language() {
    local count
    count=$(printf '%s' "${INSTALLER_LANGUAGES:-}" | wc -w)
    [ "$count" -le 1 ] && return 0

    msg "Language selection"

    if [ "$UI_FRONTEND_ENABLED" = "1" ]; then
        # GUI path: not yet wired; fall through to whiptail.
        true
    fi

    set --
    local first=1
    for lang_entry in $INSTALLER_LANGUAGES; do
        local code="${lang_entry%%:*}"
        local label
        label=$(printf '%s' "${lang_entry#*:}" | tr '_' ' ')
        if [ "$first" = "1" ]; then
            set -- "$@" "$code" "$label" "ON"
            first=0
        else
            set -- "$@" "$code" "$label" "OFF"
        fi
    done

    local selected
    selected=$(run_whiptail \
        --title "${PRODUCT_NAME}" \
        --radiolist "Select installer language / Kies taal:" \
        12 50 "$count" "$@") || true
    selected=$(printf '%s' "$selected" | tr -d '"')
    [ -n "$selected" ] && INSTALLER_LANG="$selected"
    echo "  Language: $INSTALLER_LANG"
}

# ============================================================
# 3. Disk selection
# ============================================================

# Resolve a stable identifier for a block device, suitable for matching
# back to a hypervisor / hardware inventory entry from the kiosk. /dev/sdX
# letters are non-deterministic across boots (depends on virtio-scsi
# probe order), so the kiosk has to surface something durable.
#
# Preference order:
#   wwn-*    — NAA WWN, present on most physical and many virtio-scsi disks
#   nvme-*   — NVMe model + serial
#   scsi-*   — SCSI vendor/product/serial (QEMU virtio-scsi exposes the
#              PVE slot as `drive-scsi0`, so this directly identifies the
#              VM-config slot the operator picks)
#   ata-*    — ATA model + serial
#   virtio-* — virtio-blk fallback
disk_stable_id() {
    local name="$1"
    local prefix link target

    [ -d /dev/disk/by-id ] || return 0
    for prefix in wwn nvme scsi ata virtio; do
        for link in /dev/disk/by-id/${prefix}-*; do
            [ -L "$link" ] || continue
            target=$(readlink -f "$link" 2>/dev/null || true)
            if [ "$target" = "/dev/${name}" ]; then
                basename "$link"
                return 0
            fi
        done
    done
    return 0
}

disk_part() {
    local disk="$1"
    local number="$2"

    # Linux block devices whose base name ends in a digit use a `p`
    # separator before the partition number: nvme0n1p1, mmcblk0p1.
    case "$disk" in
        *[0-9]) printf '%sp%s\n' "$disk" "$number" ;;
        *)      printf '%s%s\n' "$disk" "$number" ;;
    esac
}

select_disks() {
    msg "Disk selection"

    # Pre-set bypass: if SELECTED_DISKS is already exported (from config.sh,
    # kernel cmdline, or an outer automation wrapper), validate the devices
    # exist and skip the interactive picker. This is what lets CI / unattended
    # installs run without operator input.
    if [ -n "${SELECTED_DISKS:-}" ]; then
        echo "  Using pre-configured SELECTED_DISKS: $SELECTED_DISKS"
        for d in $SELECTED_DISKS; do
            [ -b "$d" ] || die "Pre-configured disk is not a block device: $d"
        done
        SELECTED_COUNT=$(echo "$SELECTED_DISKS" | wc -w)
        if [ "$SELECTED_COUNT" -gt 1 ]; then
            USE_RAID=1
            echo "  Mode: RAID-1 + LVM"
        else
            USE_RAID=0
            echo "  Mode: Single disk + LVM"
        fi
        return 0
    fi

    # Build a tab-separated table (size, /dev/name, label, description)
    # so we can sort by size before rendering JSON. Tab is safe — none of
    # the fields ever contain it.
    local entries
    entries=$(mktemp 2>/dev/null || echo /tmp/.smoothiso-disks.$$)
    : > "$entries"

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
            | sed 's/[[:space:]]*$//; s/^[[:space:]]*//' || echo "")
        [ -z "$model" ] && model="Disk"

        local stable_id
        stable_id=$(disk_stable_id "$name")

        # Headline visible to the operator: size + vendor/model + the
        # current /dev/sdX letter (only valid for this boot, but useful
        # for cross-referencing serial output during the install).
        local label="${gb} GB · ${model} (/dev/${name})"
        # Subtitle: the durable identifier they should match against
        # PVE / their hardware inventory. For virtio-scsi this looks
        # like `scsi-0QEMU_QEMU_HARDDISK_drive-scsi0`, so the
        # `drive-scsi0` suffix is the PVE slot name.
        local desc="$stable_id"
        [ -z "$desc" ] && desc="(no stable identifier — /dev/${name} only valid for this boot)"

        printf '%s\t/dev/%s\t%s\t%s\n' "$sz" "$name" "$label" "$desc" >> "$entries"
    done

    if [ ! -s "$entries" ]; then
        rm -f "$entries"
        die "No available disks found"
    fi

    sort -n -k1,1 "$entries" -o "$entries"

    if [ "$UI_FRONTEND_ENABLED" = "1" ]; then
        local ui_disk_options="["
        while IFS="	" read -r _sz dev label desc; do
            [ -n "$dev" ] || continue
            ui_disk_options="${ui_disk_options}{\"value\":\"${dev}\",\"label\":\"$(ui_escape_json "$label")\",\"description\":\"$(ui_escape_json "$desc")\"},"
        done < "$entries"
        rm -f "$entries"
        ui_disk_options="${ui_disk_options%,}]"
        local ui_selected
        ui_selected=$(ui_prompt_checklist \
            "${PRODUCT_NAME} - Select OS Disk(s)" \
            'Select one or more disks for the OS.\n\nOne disk: standard LVM.\nTwo or more: RAID-1 mirror + LVM.\n\nThe identifier under each disk is its stable hardware/hypervisor name.' \
            "$ui_disk_options") || ui_selected=""
        [ -n "$ui_selected" ] && SELECTED_DISKS="$ui_selected"
    else
        set --
        while IFS="	" read -r _sz dev label _desc; do
            [ -n "$dev" ] || continue
            set -- "$@" "$dev" "$label" "OFF"
        done < "$entries"
        rm -f "$entries"
        local raw_selected
        raw_selected=$(run_whiptail \
            --title "${PRODUCT_NAME} - Select OS Disk(s)" \
            --checklist \
            "Select one or more disks for the OS. One disk: LVM. Two or more: RAID-1 mirror + LVM." \
            20 78 10 "$@") || true
        SELECTED_DISKS=$(printf '%s' "$raw_selected" | tr -d '"')
    fi
    [ -z "$SELECTED_DISKS" ] && die "No disks selected"

    SELECTED_COUNT=$(echo "$SELECTED_DISKS" | wc -w)
    echo "  Selected $SELECTED_COUNT disk(s): $SELECTED_DISKS"
    for d in $SELECTED_DISKS; do
        local _name=$(basename "$d")
        local _id
        _id=$(disk_stable_id "$_name")
        [ -n "$_id" ] && echo "    ${d}  ->  ${_id}"
    done

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

    # Pre-set bypass: same automation hook as SELECTED_DISKS. The pre-set
    # value still has to meet the 6-character minimum the interactive
    # prompt enforces, otherwise the install completes with a password
    # the installed system's PAM will reject.
    if [ -n "${ADMIN_PASSWORD:-}" ]; then
        if [ ${#ADMIN_PASSWORD} -lt 6 ]; then
            die "Pre-configured ADMIN_PASSWORD must be at least 6 characters"
        fi
        echo "  Using pre-configured ADMIN_PASSWORD."
        return 0
    fi

    ADMIN_PASSWORD=""

    if [ "$UI_FRONTEND_ENABLED" = "1" ]; then
        ui_require_frontend
        while true; do
            local pass1
            pass1=$(ui_prompt_password \
                "${PRODUCT_NAME} - Admin Password" \
                "Enter password for the 'admin' account (min 6 characters):") || continue
            [ -z "$pass1" ] && die "Password is required"
            if [ ${#pass1} -lt 6 ]; then continue; fi
            local pass2
            pass2=$(ui_prompt_password \
                "${PRODUCT_NAME} - Confirm Password" \
                "Confirm password:") || continue
            if [ "$pass1" != "$pass2" ]; then continue; fi
            ADMIN_PASSWORD="$pass1"
            break
        done
    else
        while true; do
            local pass1
            pass1=$(run_whiptail \
                --title "${PRODUCT_NAME} - Admin Password" \
                --passwordbox "Enter password for the 'admin' account (min 6 characters):" \
                10 60) || pass1=""
            [ -z "$pass1" ] && die "Password is required"
            if [ ${#pass1} -lt 6 ]; then continue; fi
            local pass2
            pass2=$(run_whiptail \
                --title "${PRODUCT_NAME} - Confirm Password" \
                --passwordbox "Confirm password:" \
                10 60) || pass2=""
            if [ "$pass1" != "$pass2" ]; then continue; fi
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
    for dev in /dev/sd*[0-9] /dev/nvme*p[0-9]* /dev/mmcblk*p[0-9]*; do
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

    local p2 p3 p4
    p2=$(disk_part "$disk" 2)
    p3=$(disk_part "$disk" 3)
    p4=$(disk_part "$disk" 4)

    mkfs.vfat -F 32 "$p2"
    mkfs.ext4 -F "$p3"

    vgremove -ff "${VG_NAME}" 2>/dev/null || true
    pvremove -ff "$p4" 2>/dev/null || true
    pvcreate -ff -y "$p4"
    vgcreate "${VG_NAME}" "$p4"
    lvcreate -Wy -y -L 4G -n swap "${VG_NAME}"
    lvcreate -Wy -y -l 100%FREE -n root "${VG_NAME}"

    ensure_lvm_nodes "${VG_NAME}" || \
        die "Could not bring up /dev/${VG_NAME} after lvcreate"

    mkswap "/dev/${VG_NAME}/swap"
    mkfs.ext4 -F "/dev/${VG_NAME}/root"

    # mkfs syncs and closes the dm device; rebuild the node chain again so
    # the next consumer (mount) sees a fully populated /dev/${VG_NAME}/.
    ensure_lvm_nodes "${VG_NAME}" || \
        die "/dev/${VG_NAME}/root vanished after mkfs"

    # mount() needs the filesystem driver registered with the kernel.
    # mkfs is userspace and writes ext4 metadata directly, so it can
    # succeed on a system where mount would still ENODEV. Force-load
    # ext4 + vfat before any mount.
    ensure_filesystem_module ext4 || \
        die "ext4 kernel module not registered; cannot mount root"
    ensure_filesystem_module vfat || \
        echo "  WARNING: vfat module not registered; EFI mount may fail"

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
        p3=$(disk_part "$disk" 3)
        p4=$(disk_part "$disk" 4)

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

    ensure_lvm_nodes "${VG_NAME}" || \
        die "Could not bring up /dev/${VG_NAME} after lvcreate"

    mkswap "/dev/${VG_NAME}/swap"
    mkfs.ext4 -F "/dev/${VG_NAME}/root"

    local first_disk=$(echo "$SELECTED_DISKS" | awk '{print $1}')
    local efi_part
    efi_part=$(disk_part "$first_disk" 2)
    mkfs.vfat -F 32 "$efi_part"

    ensure_lvm_nodes "${VG_NAME}" || \
        die "/dev/${VG_NAME}/root vanished after mkfs"

    ensure_filesystem_module ext4 || \
        die "ext4 kernel module not registered; cannot mount root"
    ensure_filesystem_module vfat || \
        echo "  WARNING: vfat module not registered; EFI mount may fail"

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

    ui_status "Installing base system" "Running debootstrap first stage (downloading Debian ${DEBIAN_SUITE}). This takes a few minutes." 2 6
    echo "  Running debootstrap for ${DEBIAN_SUITE}..."
    debootstrap --foreign --arch="$ARCH" \
        "$DEBIAN_SUITE" "$TARGET" "$DEBIAN_MIRROR" || \
        die "debootstrap first stage failed"

    # Stub postinsts that source debconf confmodule -- they hang in the
    # minimal initrd environment because the Perl frontend blocks on stdin.
    mkdir -p "$TARGET/etc/dpkg/dpkg.cfg.d"
    cat > "$TARGET/etc/dpkg/dpkg.cfg.d/smoothiso-bootstrap" << 'DPKGCFG'
pre-invoke=/debootstrap/stub-debconf-postinsts
# Skip the per-file fsync()/sync() dpkg normally does after unpacking each
# package. The target filesystem was just created and the machine reboots at
# the end of the install, so durability mid-install buys nothing; this is the
# same trade-off the stock Debian installer makes and removes a large amount of
# I/O stall from the base-system configure phase. Removed with this file before
# the install completes, so the running system keeps dpkg's safe default.
force-unsafe-io
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

    ui_status "Installing base system" "Running debootstrap second stage (unpacking and configuring base packages)." 2 6
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
        ui_status "Installing base system" "Reconfiguring deferred postinst scripts." 2 6
        echo "  Reconfiguring:$stubbed_pkgs"
        mount --bind /dev "$TARGET/dev" 2>/dev/null || true
        mount --bind /dev/pts "$TARGET/dev/pts" 2>/dev/null || true
        mount -t proc proc "$TARGET/proc" 2>/dev/null || true
        mount -t sysfs sysfs "$TARGET/sys" 2>/dev/null || true
        # Stub pam-auth-update inside the chroot before reconfiguring.
        # libpam-runtime's postinst calls pam-auth-update, which uses
        # debconf's Perl frontend and hangs in the d-i ramdisk despite
        # DEBIAN_FRONTEND=noninteractive. The dpkg --configure call
        # itself is also wrapped in `timeout` so any other postinst
        # that locks up does not stall the entire install.
        if [ -f "$TARGET/usr/sbin/pam-auth-update" ] && \
            [ ! -f "$TARGET/usr/sbin/pam-auth-update.real" ]; then
            mv "$TARGET/usr/sbin/pam-auth-update" \
               "$TARGET/usr/sbin/pam-auth-update.real"
            printf '#!/bin/sh\nexit 0\n' > "$TARGET/usr/sbin/pam-auth-update"
            chmod +x "$TARGET/usr/sbin/pam-auth-update"
        fi
        for pkg in $stubbed_pkgs; do
            echo "    Configuring $pkg..."
            timeout 60 env DEBIAN_FRONTEND=noninteractive \
                chroot "$TARGET" dpkg --configure "$pkg" 2>&1 \
                || echo "    WARNING: $pkg configure returned non-zero"
        done
        if [ -f "$TARGET/usr/sbin/pam-auth-update.real" ]; then
            mv "$TARGET/usr/sbin/pam-auth-update.real" \
               "$TARGET/usr/sbin/pam-auth-update"
        fi
        umount "$TARGET/sys" "$TARGET/proc" "$TARGET/dev/pts" "$TARGET/dev" \
            2>/dev/null || true
    fi

    echo "  Base system installed."
}

# ============================================================
# 6. Packages
# ============================================================

package_list_contains() {
    local list="$1"
    local want="$2"
    local item
    for item in $list; do
        [ "$item" = "$want" ] && return 0
    done
    return 1
}

configure_bcachefs_repo() {
    local filesystem_pkgs="${INSTALLER_FILESYSTEM_PACKAGES-btrfs-progs}"
    local optional_filesystem_pkgs="${INSTALLER_OPTIONAL_FILESYSTEM_PACKAGES-bcachefs-tools}"
    local combined_pkgs="${filesystem_pkgs} ${optional_filesystem_pkgs}"

    if ! package_list_contains "$combined_pkgs" "bcachefs-tools" && \
       ! package_list_contains "$combined_pkgs" "bcachefs-kernel-dkms"; then
        return 0
    fi

    local repo_codename="${BCACHEFS_APT_CODENAME:-${DEBIAN_SUITE}}"
    local repo_suite="${BCACHEFS_APT_SUITE:-bcachefs-tools-release}"
    local key_path="/etc/apt/trusted.gpg.d/apt.bcachefs.org.asc"
    local source_path="/etc/apt/sources.list.d/apt.bcachefs.org.sources"

    ui_status "Installing packages" "Configuring bcachefs package repository." 3 6
    echo "  Configuring bcachefs APT repository (${repo_codename}/${repo_suite})..."
    mkdir -p "$TARGET/etc/apt/trusted.gpg.d" "$TARGET/etc/apt/sources.list.d"
    if ! chroot "$TARGET" curl -fsSL -o "$key_path" \
        https://apt.bcachefs.org/apt.bcachefs.org.asc; then
        echo "  WARNING: bcachefs APT key download failed; bcachefs tooling may be unavailable."
        return 0
    fi
    cat > "$TARGET$source_path" << SOURCES
Types: deb
URIs: https://apt.bcachefs.org/${repo_codename}/
Suites: ${repo_suite}
Components: main
Signed-By: ${key_path}
SOURCES
    chroot "$TARGET" apt-get update -qq || \
        echo "  WARNING: bcachefs APT repository update failed; bcachefs tooling may be unavailable."
}

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
# See install_base(): skip dpkg's per-file fsync during the package-install
# phase too. Removed at the end of install_packages so it never reaches the
# running system.
force-unsafe-io
DPKGCFG
    # Don't download translated package descriptions (one index per configured
    # language for every apt source) — they are never used by the unattended
    # install and just add round-trips. Removed with policy-rc.d at the end.
    mkdir -p "$TARGET/etc/apt/apt.conf.d"
    cat > "$TARGET/etc/apt/apt.conf.d/99smoothiso-install-speed" << 'APTCFG'
Acquire::Languages "none";
Acquire::http::Pipeline-Depth "10";
APTCFG
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

    ui_status "Installing packages" "Refreshing package indexes." 3 6
    chroot "$TARGET" apt-get update -qq

    ui_status "Installing packages" "Installing GRUB bootloader packages." 3 6
    echo "  Installing bootloader packages..."
    case "$ARCH" in
        amd64) bootloader_pkgs="grub-efi-amd64 grub-pc-bin efibootmgr" ;;
        arm64) bootloader_pkgs="grub-efi-arm64 efibootmgr" ;;
        *)     die "Unsupported ARCH: $ARCH" ;;
    esac
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive chroot "$TARGET" apt-get install -y \
        $bootloader_pkgs \
        2>&1 || die "Failed to install GRUB packages"

    # Firmware packages on the installed system. Without this, kernels
    # that drive modern AMD APUs (gfx_v11), Intel iGPUs, Realtek NICs,
    # etc. fail at -EPROBE with "Direct firmware load ... failed with
    # error -2" because /lib/firmware/ is empty — the display freezes,
    # USB-Ethernet may not come up, and the operator has no way to tell
    # what's wrong from the local console. Install firmware BEFORE the
    # kernel package so the kernel postinst's update-initramfs picks
    # up firmware blobs that early boot needs.
    #
    # non-free-firmware is enabled in the installed sources.list (see
    # the apt-sources stage above). Projects that intentionally want
    # only free firmware can set INSTALLER_FIRMWARE_PACKAGES="" or
    # override with a different list.
    local firmware_pkgs="${INSTALLER_FIRMWARE_PACKAGES-firmware-linux firmware-amd-graphics firmware-intel-graphics}"
    if [ -n "$firmware_pkgs" ]; then
        ui_status "Installing packages" "Installing firmware: ${firmware_pkgs}." 3 6
        echo "  Installing firmware packages: ${firmware_pkgs}..."
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive chroot "$TARGET" apt-get install -y -qq \
            $firmware_pkgs \
            2>/dev/null || \
            echo "  WARNING: firmware install failed; the installed system may boot to a frozen display on AMD/Intel GPUs."
    fi

    # Kernel packages. Projects that ship their own kernel set
    # INSTALLER_KERNEL_PACKAGES="" and install it from packages.sh.
    local kernel_pkgs="${INSTALLER_KERNEL_PACKAGES-linux-image-${ARCH} linux-headers-${ARCH}}"
    if [ -n "$kernel_pkgs" ]; then
        ui_status "Installing packages" "Installing kernel: ${kernel_pkgs}." 3 6
        echo "  Installing kernel packages: ${kernel_pkgs}..."
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive chroot "$TARGET" apt-get install -y -qq \
            $kernel_pkgs \
            2>/dev/null || true
    fi

    ui_status "Installing packages" "Installing LVM, mdadm, SSH, and core utilities." 3 6
    echo "  Installing core packages..."
    DEBIAN_FRONTEND=noninteractive chroot "$TARGET" apt-get install -y -qq \
        lvm2 mdadm \
        openssh-server \
        sudo curl wget ca-certificates \
        systemd-timesyncd systemd-resolved \
        2>/dev/null || true

    configure_bcachefs_repo

    # Filesystem array tooling for SmoothNAS-style managed arrays.
    # btrfs-progs is expected to be available in Debian and is installed
    # as a normal target dependency. bcachefs support depends on both
    # kernel and userspace availability, so its tools are attempted
    # separately and treated as optional for images whose suite does not
    # ship them yet.
    local filesystem_pkgs="${INSTALLER_FILESYSTEM_PACKAGES-btrfs-progs}"
    if [ -n "$filesystem_pkgs" ]; then
        ui_status "Installing packages" "Installing filesystem tooling: ${filesystem_pkgs}." 3 6
        echo "  Installing filesystem tooling: ${filesystem_pkgs}..."
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive chroot "$TARGET" apt-get install -y -qq \
            $filesystem_pkgs \
            2>/dev/null || die "Failed to install filesystem tooling: ${filesystem_pkgs}"
    fi

    local optional_filesystem_pkgs="${INSTALLER_OPTIONAL_FILESYSTEM_PACKAGES-bcachefs-tools}"
    if [ -n "$optional_filesystem_pkgs" ]; then
        local optional_fs_pkg
        for optional_fs_pkg in $optional_filesystem_pkgs; do
            ui_status "Installing packages" "Attempting optional filesystem tooling: ${optional_fs_pkg}." 3 6
            echo "  Attempting optional filesystem tooling: ${optional_fs_pkg}..."
            DEBIAN_FRONTEND=noninteractive chroot "$TARGET" apt-get install -y -qq \
                "$optional_fs_pkg" \
                2>/dev/null || \
                echo "  WARNING: optional filesystem tooling ${optional_fs_pkg} is unavailable in this image suite."
        done
    fi

    # Generate the CA trust bundle now so HTTPS works for tools (curl/wget)
    # used by project hooks. ca-certificates' postinst is stubbed by the
    # debconf pre-invoke hook, so /etc/ssl/certs/ca-certificates.crt would
    # otherwise stay empty until the post-hook cleanup runs.
    #
    # Do NOT call ca-certificates.postinst.real here — it sources
    # /usr/share/debconf/confmodule and blocks waiting for debconf I/O in
    # the d-i environment (the same reason every other debconf postinst is
    # stubbed). Build /etc/ca-certificates.conf manually with a portable
    # `find . | sed` pipeline (no -printf — that flag silently produced an
    # empty file in some target environments, which left the bundle empty).
    chroot "$TARGET" sh -c '
        if [ -d /usr/share/ca-certificates ]; then
            ( cd /usr/share/ca-certificates \
                && find . -name "*.crt" -type f \
                | sed "s|^\./||" | sort > /etc/ca-certificates.conf )
            update-ca-certificates --fresh
        fi
    ' 2>/dev/null || true

    # Product-specific packages.
    ui_status "Installing packages" "Installing product-specific packages." 3 6
    if [ -f /smoothiso-hooks/packages.sh ]; then
        echo "  Running project packages hook..."
        . /smoothiso-hooks/packages.sh
    fi

    # Cleanup hooks and stubs.
    rm -f "$TARGET/etc/dpkg/dpkg.cfg.d/smoothiso-install"
    rm -f "$TARGET/etc/apt/apt.conf.d/99smoothiso-install-speed"
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
        boot_dev=$(disk_part "$disk" 3)
    fi
    local first_disk=$(echo "$SELECTED_DISKS" | awk '{print $1}')
    efi_dev=$(disk_part "$first_disk" 2)

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
    global_filter = [ "a|/dev/md.*|", "r|/dev/sd.*|", "r|/dev/nvme.*|", "r|/dev/mmcblk.*|" ]
}
LVMCFG
    fi

    # Slim down the initrd. Debian's default MODULES=most packs nearly
    # every kernel module + firmware blob into the initrd, which with
    # smoothkernel + zfs-initramfs balloons to several hundred MB.
    # GRUB then has to load that whole thing through the firmware's
    # block-I/O before jumping to the kernel — on physical hardware
    # the screen sits on `Loading initial ramdisk ...` for minutes
    # before any kernel output appears, indistinguishable from a
    # hang.
    #
    # MODULES=dep tells initramfs-tools to bundle only the modules
    # actually required to mount root — typically tens of MB.
    # Trade-off: if the operator later swaps the storage controller
    # for a different driver, the initrd won't have it; they have to
    # boot a rescue ISO and rebuild. For a dedicated NAS appliance
    # whose hardware is set at install time, that's the right
    # default.
    mkdir -p "$TARGET/etc/initramfs-tools/conf.d"
    cat > "$TARGET/etc/initramfs-tools/conf.d/${PRODUCT_ID}-slim" << 'INITCFG'
# smoothiso: ship only the modules needed to mount root. Cuts the
# initrd from hundreds of MB (MODULES=most default) to tens of MB
# so GRUB-side load time is bounded.
MODULES=dep
COMPRESS=zstd
INITCFG

    # Belt-and-suspenders: ensure the storage drivers, common file
    # systems, and md/LVM stack are unconditionally bundled by name
    # so a misdetected MODULES=dep run can't strand the system. These
    # are tiny — adding them to /etc/initramfs-tools/modules adds
    # them on top of whatever dep-mode finds.
    cat > "$TARGET/etc/initramfs-tools/modules" << 'MODLIST'
# smoothiso: explicit boot-essential modules. Belongs in initrd no
# matter what dep-mode chooses, so the boot can find root even when
# update-initramfs ran in an environment where lsmod misled it.
virtio
virtio_pci
virtio_blk
virtio_scsi
virtio_net
ahci
nvme
nvme_core
mmc_block
mmc_core
sdhci
sdhci_pci
sd_mod
sr_mod
xhci_pci
xhci_hcd
ehci_pci
ehci_hcd
ext4
xfs
btrfs
dm_mod
dm_mirror
dm_snapshot
dm_thin_pool
raid0
raid1
raid10
raid456
md_mod
MODLIST

    # GRUB config.
    #
    # Default to a framebuffer-only console. The previous build hard-
    # coded `console=ttyS0,115200n8 console=tty0` plus a dual GRUB
    # terminal, which on environments where serial is not drained at
    # line rate (qemu sockets without a connected reader, USB-serial
    # adapters with flow control, etc.) makes the kernel block on
    # serial-output completion during initramfs init — the system
    # appears frozen right after `Loading Linux …` for many minutes.
    # Operators who genuinely need serial-console boot can opt in
    # via the SMOOTHISO_SERIAL_CONSOLE install env var (or by adding
    # `serial=1` to the installer kernel cmdline, see installer.sh
    # main).
    # Default boot is verbose. PR #27 dropped the hardcoded
    # `console=ttyS0` from GRUB_CMDLINE_LINUX, but Debian's stock
    # `GRUB_CMDLINE_LINUX_DEFAULT="quiet"` was still in effect — so
    # after `Loading initial ramdisk ...` the kernel produced no
    # console output, making any actual problem (slow boot, missing
    # driver, kernel panic) indistinguishable from a hang. Override
    # the default to empty so kernel boot messages stream to tty0
    # and operators can see what's happening. Operators who prefer
    # the silent splash can re-add `quiet` post-install.
    cat >> "$TARGET/etc/default/grub" << 'GRUBCFG'

# smoothiso: preload modules for mdraid + LVM root
GRUB_PRELOAD_MODULES="part_gpt part_msdos mdraid1x lvm ext2"
GRUB_DISABLE_OS_PROBER=true
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUBCFG

    if [ "${SMOOTHISO_SERIAL_CONSOLE:-0}" = "1" ]; then
        cat >> "$TARGET/etc/default/grub" << 'GRUBCFG'
# smoothiso: serial console requested via SMOOTHISO_SERIAL_CONSOLE=1
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
GRUBCFG
    fi

    # Rebuild initramfs for *every* installed kernel (-k all). Without
    # -k, update-initramfs picks the kernel matching `uname -r`, which
    # inside the d-i chroot is the d-i installer kernel — not
    # smoothkernel. So `-u` alone may rebuild the wrong (or no)
    # initrd, leaving smoothkernel's fat MODULES=most initrd from
    # the kernel postinst untouched. -k all makes that
    # impossible.
    #
    # The previous `|| true` swallowed failures silently and shipped
    # broken installs. Keep the install going on failure (so the
    # operator gets a usable rescue prompt rather than a wedged
    # installer), but log the error visibly so the install log shows
    # it.
    ui_status "Configuring system" "Rebuilding initramfs for all installed kernels." 4 6
    echo "  Rebuilding initramfs (all kernels)..."
    if ! chroot "$TARGET" update-initramfs -u -k all 2>&1; then
        echo "  WARNING: update-initramfs -u -k all failed. The installed system may not boot."
        echo "  Recovery: boot a rescue ISO, chroot the target, run update-initramfs -u -k all."
    fi
    echo "  Resulting /boot contents:"
    ls -lh "$TARGET/boot/"vmlinuz* "$TARGET/boot/"initrd* 2>&1 | sed 's/^/    /' || true

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
        cp /smoothiso-firstboot \
            "$TARGET/usr/local/bin/${PRODUCT_ID}-firstboot"
        chmod 755 "$TARGET/usr/local/bin/${PRODUCT_ID}-firstboot"

        # Copy firstboot extension hook for use by the firstboot script.
        if [ -f /smoothiso-hooks/firstboot.sh ]; then
            mkdir -p "$TARGET/usr/local/lib/smoothiso"
            cp /smoothiso-hooks/firstboot.sh \
                "$TARGET/usr/local/lib/smoothiso/firstboot-ext.sh"
            chmod 755 "$TARGET/usr/local/lib/smoothiso/firstboot-ext.sh"
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
        ui_status "Configuring system" "Applying product-specific configuration." 4 6
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

    local uefi_ok=0 bios_ok=0 efi_pkg efi_target
    local grub_log="${TMPDIR:-/tmp}/grub-install.log"
    : > "$grub_log"

    case "$ARCH" in
        amd64) efi_pkg="grub-efi-amd64" ; efi_target="x86_64-efi" ;;
        arm64) efi_pkg="grub-efi-arm64" ; efi_target="arm64-efi"  ;;
        *)     die "Unsupported ARCH: $ARCH" ;;
    esac

    if [ -d /sys/firmware/efi ]; then
        if chroot "$TARGET" dpkg -l "$efi_pkg" 2>/dev/null | grep -q '^ii'; then
            ui_status "Installing bootloader" "Installing GRUB for UEFI." 5 6
            echo "  Installing GRUB (UEFI)..."
            if chroot "$TARGET" grub-install --target="$efi_target" \
                    --efi-directory=/boot/efi \
                    --bootloader-id="${PRODUCT_ID}" \
                    --recheck --no-nvram >>"$grub_log" 2>&1; then
                uefi_ok=1
            else
                echo "  WARNING: UEFI GRUB install failed (see ${grub_log})"
            fi
            ui_status "Installing bootloader" "Installing GRUB (UEFI removable fallback)." 5 6
            echo "  Installing GRUB (UEFI removable)..."
            if chroot "$TARGET" grub-install --target="$efi_target" \
                    --efi-directory=/boot/efi \
                    --recheck --no-nvram --removable >>"$grub_log" 2>&1; then
                uefi_ok=1
            else
                echo "  WARNING: UEFI removable install failed (see ${grub_log})"
            fi
        fi
    fi

    # BIOS path is amd64-only — arm64 has no grub-pc-bin.
    if [ "$ARCH" = "amd64" ] && \
       chroot "$TARGET" dpkg -l grub-pc-bin 2>/dev/null | grep -q '^ii'; then
        for disk in $SELECTED_DISKS; do
            ui_status "Installing bootloader" "Installing GRUB (BIOS) to ${disk}." 5 6
            echo "  Installing GRUB (BIOS) to $disk..."
            if chroot "$TARGET" grub-install --target=i386-pc "$disk" \
                    >>"$grub_log" 2>&1; then
                bios_ok=1
            else
                echo "  WARNING: BIOS GRUB install to $disk failed (see ${grub_log})"
            fi
            # grub-install can return 0 on a partial run if grub-bios-setup
            # fails to embed core.img — the MBR boot sector ends up zeroed
            # and the system silently won't boot. Verify by reading back the
            # first 446 bytes (the bootcode area, before the partition table)
            # and treating an all-zero region as a failed install.
            if [ "$bios_ok" = "1" ]; then
                if dd if="$disk" bs=446 count=1 2>/dev/null \
                       | tr -d '\000' | LC_ALL=C grep -q '[^[:space:]]'; then
                    echo "  Verified MBR boot sector on $disk."
                else
                    bios_ok=0
                    echo "  WARNING: BIOS GRUB exited 0 but MBR on $disk is empty (see ${grub_log})"
                fi
            fi
        done
    fi

    if [ "$uefi_ok" = "0" ] && [ "$bios_ok" = "0" ]; then
        if [ -s "$grub_log" ]; then
            echo "  --- grub-install log ---"
            tail -n 40 "$grub_log"
            echo "  --- end log ---"
        fi
        die "No bootloader installed successfully"
    fi

    ui_status "Installing bootloader" "Generating GRUB configuration." 5 6
    if ! chroot "$TARGET" update-grub >>"$grub_log" 2>&1; then
        tail -n 40 "$grub_log"
        die "update-grub failed (see ${grub_log})"
    fi
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
    echo "   Username: admin"
    echo ""

    if [ "$UI_FRONTEND_ENABLED" = "1" ]; then
        ui_require_frontend
        ui_wait \
            "Installation complete" \
            "Your ${PRODUCT_NAME} installation is finished. Remove installation media and press continue."
    else
        # Plain console countdown — whiptail --msgbox has been observed to
        # hang on bare metal here (OK keypress not dismissing the dialog),
        # leaving the system stuck on the completion screen instead of
        # rebooting. The console echo below is reliable on every console
        # type d-i exposes.
        local secs=10
        while [ "$secs" -gt 0 ]; do
            printf '\r   Remove the installation media. Rebooting in %2d seconds...' "$secs"
            sleep 1
            secs=$((secs - 1))
        done
        printf '\n\n'
    fi

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
install_browser_deferred
ui_init_frontend
trap ui_stop_frontend EXIT INT TERM HUP
select_language
sync_clock
select_disks
prompt_password

ui_status "Partitioning disks" "Wiping and partitioning the selected disks." 1 6
do_partitioning

ui_status "Installing base system" "Running debootstrap to install Debian ${DEBIAN_SUITE}. This takes a few minutes." 2 6
install_base

ui_status "Installing packages" "Installing kernel, bootloader, and product packages." 3 6
install_packages

ui_status "Configuring system" "Writing fstab, network, GRUB defaults, and product services." 4 6
configure_system

ui_status "Installing bootloader" "Installing GRUB to the selected disk(s)." 5 6
install_grub

ui_status "Finalizing" "Finishing up." 6 6
ui_clear_status
finish
