#!/bin/bash
# firefox-nvidia-vaapi-check.sh
# Checks Firefox hardware video decoding (VAAPI) configuration
# Enhanced with NVIDIA-specific checks for dual-GPU, Blackwell, and RDD process issues
# Requires: bash ≥4, grep with PCRE (-P), lspci (pciutils), vainfo (libva-utils)

SCRIPT_VERSION="1.0.0"

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Section divider styling — override these to retheme
DIVIDER_FG='\033[38;2;118;185;0m'  # Foreground for ━━━ rules  (default: NVIDIA Green #76B900)
TITLE_FG='\033[1;37m'               # Foreground for section title text (default: bold white)

# Auto-disable colors when piped, NO_COLOR is set, or terminal is dumb
[[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" || ! -t 1 ]] && {
    BOLD=''; GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''; DIVIDER_FG=''; TITLE_FG=''
}

# Cache terminal width once — divider() uses this to avoid repeated tput calls
_TERM_COLS=$(tput cols 2>/dev/null || echo 72)
[[ "$_TERM_COLS" =~ ^[0-9]+$ ]] || _TERM_COLS=72

# Verify grep supports PCRE (-P), required for pref parsing
echo "" | grep -qP "" 2>/dev/null || { echo "Error: grep with PCRE (-P) is required (install grep from GNU coreutils)" >&2; exit 1; }

# Parse CLI flags
FILTER_PROFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-V)
            echo "$(basename "$0") $SCRIPT_VERSION"
            exit 0
            ;;
        --help|-h)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Check Firefox NVIDIA VAAPI hardware video decoding configuration."
            echo ""
            echo "Options:"
            echo "  --help, -h       Show this help message and exit"
            echo "  --version, -V    Print version and exit"
            echo "  --no-color       Disable ANSI color output (useful for piping to a file)"
            echo "  --profile NAME   Only check profiles matching NAME (case-insensitive substring match)"
            echo ""
            echo "Examples:"
            echo "  $(basename "$0")                    # Normal run"
            echo "  $(basename "$0") --no-color | tee /tmp/vaapi-report.txt"
            echo "  $(basename "$0") --profile default  # Only check 'default' profile"
            echo "  NVD_LOG=1 MOZ_LOG=\"PlatformDecoderModule:5\" firefox 2>&1 | tee /tmp/ff-vaapi.log"
            exit 0
            ;;
        --no-color)
            BOLD=''
            GREEN=''
            RED=''
            YELLOW=''
            CYAN=''
            NC=''
            DIVIDER_FG=''
            TITLE_FG=''
            ;;
        --profile)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --profile requires an argument" >&2; exit 1
            fi
            FILTER_PROFILE="$2"
            shift
            ;;
        --profile=*)
            FILTER_PROFILE="${1#--profile=}"
            ;;
        *)
            echo "Error: Unknown option: $1" >&2; exit 1
            ;;
    esac
    shift
done

issues=0
warnings=0

# Detect real user when run under sudo
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    if [[ -z "$REAL_HOME" ]]; then
        echo -e "${YELLOW}Warning: could not determine home for $SUDO_USER via getent — falling back to /home/$SUDO_USER${NC}"
        REAL_HOME="/home/$SUDO_USER"
    fi
    echo -e "${YELLOW}Note: Running as root (sudo) — using $REAL_USER's profile and groups${NC}"
else
    REAL_USER=$(whoami)
    REAL_HOME="$HOME"
fi

divider() {
    local title=" $1 "
    local cols=$_TERM_COLS
    local right=$(( cols - 3 - ${#title} ))
    [[ $right -lt 1 ]] && right=1
    local left_bar='━━━'
    local right_bar=""
    printf -v right_bar '%*s' "$right" ''; right_bar="${right_bar// /━}"
    echo ""
    echo -e "${DIVIDER_FG}${left_bar}${NC}${TITLE_FG}${title}${NC}${DIVIDER_FG}${right_bar}${NC}"
}

flag_issue() {
    echo -e "  ${RED}✘ $1${NC}"
    [[ -n "${2:-}" ]] && echo -e "    Fix: $2"
    ((issues++))
}

flag_warn() {
    echo -e "  ${YELLOW}~ $1${NC}"
    [[ -n "${2:-}" ]] && echo -e "    Hint: $2"
    ((warnings++))
}

flag_ok() {
    echo -e "  ${GREEN}✔${NC} $1"
}

# install_hint pkg_apt [pkg_pacman [pkg_dnf]]
# Outputs the distro-appropriate install command for a package.
install_hint() {
    local pkg_apt="${1}" pkg_pacman="${2:-$1}" pkg_dnf="${3:-$1}"
    if   command -v apt-get &>/dev/null; then echo "sudo apt-get install $pkg_apt"
    elif command -v pacman  &>/dev/null; then echo "sudo pacman -S $pkg_pacman"
    elif command -v dnf     &>/dev/null; then echo "sudo dnf install $pkg_dnf"
    else echo "Install $pkg_apt via your package manager"; fi
}

# ─── Session type detection ────────────────────────────────────

# Prefer loginctl (most accurate), then XDG_SESSION_TYPE, then raw env vars
SESSION_TYPE=""
_sid=$(loginctl 2>/dev/null | awk -v u="$REAL_USER" '$0 ~ u {print $1; exit}')
[[ -n "$_sid" ]] && SESSION_TYPE=$(loginctl show-session "$_sid" -p Type --value 2>/dev/null)
if [[ -z "$SESSION_TYPE" ]]; then
    SESSION_TYPE="${XDG_SESSION_TYPE:-}"
fi
if [[ -z "$SESSION_TYPE" ]]; then
    [[ -n "${WAYLAND_DISPLAY:-}" ]] && SESSION_TYPE="wayland"
    [[ -z "$SESSION_TYPE" && -n "${DISPLAY:-}" ]] && SESSION_TYPE="x11"
fi
SESSION_TYPE="${SESSION_TYPE:-unknown}"

# ─── System Info ───────────────────────────────────────────────

FIREFOX_IS_SNAP=false
[[ -d /snap/firefox/current ]] && FIREFOX_IS_SNAP=true

divider "SYSTEM INFO"

echo -e "  Kernel:          $(uname -r)"
echo -e "  Display Server:  $SESSION_TYPE"
echo -e "  Desktop:         ${XDG_CURRENT_DESKTOP:-unknown}"
echo -e "  GPU(s):"
if command -v lspci &>/dev/null; then
    timeout 10 lspci -nn 2>/dev/null | grep -iE "vga|3d|display" | sed 's/^/    /'
else
    echo "    (lspci not found — install pciutils)"
fi

FIREFOX_PATH=$(which firefox 2>/dev/null)
if [[ -n "$FIREFOX_PATH" ]]; then
    REAL_PATH=$(readlink -f "$FIREFOX_PATH" 2>/dev/null)
    echo -e "  Firefox Path:    $FIREFOX_PATH -> $REAL_PATH"
    # Prefer reading version from application.ini (no subprocess startup overhead)
    FF_VERSION_STR=""
    _appini="$(dirname "${REAL_PATH:-$FIREFOX_PATH}")/application.ini"
    if [[ -f "$_appini" ]]; then
        _ver=$(grep -oP '(?<=^Version=)\S+' "$_appini" 2>/dev/null | head -1)
        [[ -n "$_ver" ]] && FF_VERSION_STR="Mozilla Firefox $_ver"
    fi
    if [[ -z "$FF_VERSION_STR" ]]; then
        FF_VERSION_STR=$(timeout 10 firefox --version 2>/dev/null)
    fi
    unset _appini _ver
    echo -e "  Firefox Version: $FF_VERSION_STR"
    FF_MAJOR=$(echo "$FF_VERSION_STR" | grep -oP '\d+' | head -1)

    if $FIREFOX_IS_SNAP; then
        echo -e "  Package Type:    ${YELLOW}Snap${NC} (may have VAAPI sandbox issues)"
    elif dpkg-query -W -f='${Status}' firefox 2>/dev/null | grep -q "install"; then
        FF_SOURCE=""
        if command -v apt-cache &>/dev/null; then
            FF_SOURCE=$(apt-cache policy firefox 2>/dev/null | grep -A1 '^\s*\*\*\*' | tail -1 | awk '{print $NF}')
        fi
        if [[ -n "$FF_SOURCE" ]]; then
            echo -e "  Package Type:    deb (source: $FF_SOURCE)"
        else
            echo -e "  Package Type:    deb"
        fi
    elif rpm -q firefox &>/dev/null; then
        echo -e "  Package Type:    rpm"
    elif flatpak info org.mozilla.firefox &>/dev/null; then
        echo -e "  Package Type:    ${YELLOW}Flatpak${NC}"
        flag_warn "Firefox is installed as a Flatpak — sandbox may restrict VAAPI access" \
            "Check Flatpak permissions: flatpak override --user --show org.mozilla.firefox"
    else
        echo -e "  Package Type:    unknown"
    fi
else
    echo -e "  ${RED}Firefox not found in PATH${NC}"
fi

# ─── NVIDIA Driver Info ───────────────────────────────────────

divider "NVIDIA DRIVER INFO"

if command -v nvidia-smi &>/dev/null; then
    _nv_line=$(timeout 10 nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)
    NV_GPU_NAME="${_nv_line%%, *}"
    NV_DRIVER_VER="${_nv_line##*, }"

    if [[ -n "$NV_DRIVER_VER" ]]; then
        echo -e "  GPU Name:        $NV_GPU_NAME"
        echo -e "  Driver Version:  $NV_DRIVER_VER"

        # Check if open kernel modules are in use
        LSMOD_NV=$(timeout 5 lsmod 2>/dev/null)
        if ! grep -q "^nvidia_drm " <<< "$LSMOD_NV"; then
            flag_issue "nvidia_drm kernel module is not loaded" \
                "Load it with: sudo modprobe nvidia_drm"
        else
            # Check if using open modules
            NV_OPEN=""
            if [[ -f /proc/driver/nvidia/params ]]; then
                NV_OPEN=$(grep -i "OpenRMEnabled" /proc/driver/nvidia/params 2>/dev/null | awk '{print $2}')
            fi
            # Check via /proc/driver/nvidia/params OpenRMEnabled, then modinfo filename path
            if [[ "$NV_OPEN" == "1" ]]; then
                echo -e "  Kernel Modules:  ${GREEN}open${NC}"
            elif modinfo -F filename nvidia 2>/dev/null | grep -q "open"; then
                echo -e "  Kernel Modules:  ${GREEN}open${NC}"
            else
                # Check if it's a Blackwell GPU (RTX 50xx)
                if echo "$NV_GPU_NAME" | grep -qiE "RTX 5[0-9]{3}|GB[12][0-9]{2}"; then
                    echo -e "  Kernel Modules:  proprietary"
                    flag_issue "Blackwell GPU detected but proprietary modules are loaded" \
                        "Blackwell GPUs require open kernel modules; install nvidia-open package"
                else
                    echo -e "  Kernel Modules:  proprietary"
                fi
            fi
        fi

        # Detect pre-Ampere GPU — Ampere (RTX 30xx / GA10x) and newer support NVDEC AV1
        NV_IS_PRE_AMPERE=false
        if [[ -n "$NV_GPU_NAME" ]]; then
            if ! echo "$NV_GPU_NAME" | grep -qiE "RTX [3-9][0-9]{3}|GA10[0-9]|AD10[0-9]|GB[12][0-9]{2}|\bA[13][0-9]{2}[A-Z]?\b"; then
                NV_IS_PRE_AMPERE=true
            fi
        fi

        # Check nvidia-drm.modeset=1
        CMDLINE=$(cat /proc/cmdline 2>/dev/null)
        MODESET_PARAM=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null)
        MODESET_EXIT=$?  # exit code of the cat command above

        if [[ "$MODESET_PARAM" == "Y" || "$MODESET_PARAM" == "1" ]]; then
            flag_ok "nvidia-drm.modeset=1 is active"
        elif echo "$CMDLINE" | grep -qE "nvidia-drm\.modeset=[1Y]"; then
            flag_ok "nvidia-drm.modeset=1 in kernel cmdline"
        elif [[ -f /sys/module/nvidia_drm/parameters/modeset && $MODESET_EXIT -ne 0 ]]; then
            # File exists but couldn't read it (permission denied) — try sudo
            MODESET_SUDO=$(sudo -n cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null)
            if [[ "$MODESET_SUDO" == "Y" || "$MODESET_SUDO" == "1" ]]; then
                flag_ok "nvidia-drm.modeset=1 is active (verified via sudo)"
            elif [[ -z "$MODESET_SUDO" ]]; then
                flag_warn "nvidia-drm.modeset could not be verified (sysfs requires root)" \
                    "Run: sudo cat /sys/module/nvidia_drm/parameters/modeset"
            else
                flag_issue "nvidia-drm.modeset=1 not set (current: $MODESET_SUDO)" \
                    "Add 'nvidia-drm.modeset=1' to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, then run sudo update-grub"
            fi
        else
            flag_issue "nvidia-drm.modeset=1 not set (current: ${MODESET_PARAM:-unreadable})" \
                "Add 'nvidia-drm.modeset=1' to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub or add 'options nvidia-drm modeset=1' to /etc/modprobe.d/nvidia.conf, then run sudo update-initramfs -u"
        fi

        # Scan /etc/modprobe.d/ for persistent modeset=1 configuration
        MODPROBE_MODESET_SRC=""
        for _mf in /etc/modprobe.d/*.conf; do
            [[ -f "$_mf" ]] || continue
            if grep -qE "options\s+nvidia[_-]drm\s+.*modeset=1" "$_mf" 2>/dev/null; then
                MODPROBE_MODESET_SRC="$_mf"
                break
            fi
        done
        if [[ -n "$MODPROBE_MODESET_SRC" ]]; then
            _modprobe_line=$(grep -E "options\s+nvidia[_-]drm\s+.*modeset=1" "$MODPROBE_MODESET_SRC" 2>/dev/null | head -1)
            flag_ok "nvidia-drm modeset=1 configured in $MODPROBE_MODESET_SRC: $_modprobe_line"
        fi

        # Check nvidia-drm.fbdev=1 (required on some Wayland setups with kernel 6.2+ and driver ≥545)
        FBDEV_PARAM=$(cat /sys/module/nvidia_drm/parameters/fbdev 2>/dev/null)
        NV_DRIVER_MAJOR_CHECK="${NV_DRIVER_VER%%.*}"
        if [[ "$SESSION_TYPE" == "wayland" \
              && "$NV_DRIVER_MAJOR_CHECK" =~ ^[0-9]+$ \
              && "$NV_DRIVER_MAJOR_CHECK" -ge 545 ]]; then
            if [[ "$FBDEV_PARAM" == "Y" || "$FBDEV_PARAM" == "1" ]]; then
                flag_ok "nvidia-drm.fbdev=1 is active"
            elif [[ -z "$FBDEV_PARAM" ]]; then
                flag_warn "nvidia-drm.fbdev could not be verified (sysfs not readable)" \
                    "Run: sudo cat /sys/module/nvidia_drm/parameters/fbdev"
            else
                flag_warn "nvidia-drm.fbdev=1 not set (current: ${FBDEV_PARAM:-unreadable})" \
                    "Some Wayland setups (kernel ≥6.2, driver ≥545) require 'nvidia-drm.fbdev=1'; add to /etc/modprobe.d/nvidia.conf"
            fi
        fi
        unset FBDEV_PARAM NV_DRIVER_MAJOR_CHECK
    else
        flag_warn "nvidia-smi found but could not determine driver version" \
            "Check that the NVIDIA driver is fully loaded: nvidia-smi"
    fi
else
    echo -e "  ${YELLOW}nvidia-smi not found — skipping NVIDIA-specific checks${NC}"
fi

# ─── nvidia-vaapi-driver ──────────────────────────────────────

divider "NVIDIA-VAAPI-DRIVER"

NVD_INSTALLED=false
NVD_PATH=""

# Check for the driver library in standard locations
for path in \
    /usr/lib/x86_64-linux-gnu/dri/nvidia_drv_video.so \
    /usr/lib64/dri/nvidia_drv_video.so \
    /usr/lib/dri/nvidia_drv_video.so; do
    if [[ -f "$path" ]]; then
        NVD_INSTALLED=true
        NVD_PATH="$path"
        break
    fi
done

# Also search LD_LIBRARY_PATH directories before declaring the library missing
if ! $NVD_INSTALLED && [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    IFS=: read -ra _ldpaths <<< "$LD_LIBRARY_PATH"
    for _ldpath in "${_ldpaths[@]}"; do
        [[ -d "$_ldpath" ]] || continue
        if [[ -f "$_ldpath/nvidia_drv_video.so" ]]; then
            NVD_INSTALLED=true
            NVD_PATH="$_ldpath/nvidia_drv_video.so"
            break
        fi
    done
    unset _ldpaths _ldpath
fi

# Fall back to the system linker cache
if ! $NVD_INSTALLED; then
    _ldconfig_path=$(ldconfig -p 2>/dev/null | grep -oP '(?<==> ).*nvidia_drv_video\.so$' | head -1)
    if [[ -f "$_ldconfig_path" ]]; then
        NVD_INSTALLED=true
        NVD_PATH="$_ldconfig_path"
    fi
    unset _ldconfig_path
fi

if $NVD_INSTALLED; then
    flag_ok "nvidia_drv_video.so found at $NVD_PATH"
else
    flag_issue "nvidia_drv_video.so not found" \
        "$(install_hint nvidia-vaapi-driver libva-nvidia-driver nvidia-vaapi-driver)"
fi

# Sanity-check that nvidia_drv_video.so links against the installed libva ABI
if $NVD_INSTALLED && command -v objdump &>/dev/null; then
    _nvd_libva_dep=$(objdump -p "$NVD_PATH" 2>/dev/null | awk '/NEEDED.*libva[^-]/{print $2}' | head -1)
    if [[ -n "$_nvd_libva_dep" && -n "$LIBVA_PKG_VER" ]]; then
        # Extract major from NEEDED name (e.g. libva.so.2 → 2) and from installed version
        _needed_major=$(grep -oP '(?<=\.so\.)\d+' <<< "$_nvd_libva_dep")
        _installed_major=$(grep -oP '^\d+' <<< "$LIBVA_PKG_VER")
        if [[ -n "$_needed_major" && -n "$_installed_major" && "$_needed_major" != "$_installed_major" ]]; then
            flag_warn "nvidia_drv_video.so requires $_nvd_libva_dep but installed libva major is $_installed_major" \
                "ABI mismatch — reinstall nvidia-vaapi-driver against the current libva version"
        fi
    fi
    unset _nvd_libva_dep _needed_major _installed_major
fi

# Check EGL vendor config
EGL_FOUND=false
for egl_path in \
    /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
    /usr/local/share/glvnd/egl_vendor.d/10_nvidia.json \
    /etc/glvnd/egl_vendor.d/10_nvidia.json; do
    if [[ -f "$egl_path" ]]; then
        flag_ok "NVIDIA EGL vendor config found at $egl_path"
        EGL_FOUND=true
        break
    fi
done
if ! $EGL_FOUND; then
    flag_warn "NVIDIA EGL vendor config (10_nvidia.json) not found in standard locations" \
        "May cause EGL init failures; check that the nvidia-utils / libnvidia-egl-gbm package is installed"
fi

# Warn if multiple EGL vendor configs exist and __EGL_VENDOR_LIBRARY_FILENAMES is unset
# (on multi-GPU Intel+NVIDIA systems, EGL may pick the wrong vendor without this)
_egl_configs=()
for _d in /usr/share/glvnd/egl_vendor.d /usr/local/share/glvnd/egl_vendor.d /etc/glvnd/egl_vendor.d; do
    [[ -d "$_d" ]] && _egl_configs+=( "$_d"/*.json )
done
_real_egl_configs=()
for _f in "${_egl_configs[@]}"; do [[ -f "$_f" ]] && _real_egl_configs+=("$_f"); done
_egl_vendor_count=${#_real_egl_configs[@]}
if [[ "$_egl_vendor_count" -gt 1 && -z "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" ]]; then
    flag_warn "Multiple EGL vendor configs found ($_egl_vendor_count) and __EGL_VENDOR_LIBRARY_FILENAMES is not set" \
        "On multi-GPU Intel+NVIDIA systems, set: __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
fi
unset _egl_configs _real_egl_configs _egl_vendor_count _f _d

# Check package version if available
if dpkg-query -W -f='${Status}' nvidia-vaapi-driver 2>/dev/null | grep -q "install ok installed"; then
    NVD_PKG_VER=$(dpkg-query -W -f='${Version}' nvidia-vaapi-driver 2>/dev/null)
    echo -e "  Package Version: $NVD_PKG_VER"
elif pacman -Q libva-nvidia-driver &>/dev/null; then
    echo -e "  Package:         $(pacman -Q libva-nvidia-driver 2>/dev/null)"
elif rpm -q nvidia-vaapi-driver &>/dev/null; then
    NVD_PKG_VER=$(rpm -q --queryformat '%{VERSION}' nvidia-vaapi-driver 2>/dev/null)
    echo -e "  Package Version: $NVD_PKG_VER (rpm)"
fi

# Check libva backend libraries required for DRM/X11 VAAPI
for _lib in libva-drm2 libva-x11-2; do
    if dpkg-query -W -f='${Status}' "$_lib" 2>/dev/null | grep -q "install ok installed"; then
        flag_ok "$_lib installed"
    elif command -v pacman &>/dev/null && pacman -Q libva &>/dev/null 2>&1; then
        flag_ok "libva installed (pacman — provides $_lib equivalent)"
        break  # only report once for pacman
    elif command -v rpm &>/dev/null && rpm -q libva &>/dev/null 2>&1; then
        flag_ok "libva installed (rpm — provides $_lib equivalent)"
        break  # only report once for rpm
    elif command -v dpkg &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            flag_warn "$_lib not found (needed for DRM/X11 VAAPI backend)" \
                "sudo apt-get install $_lib"
        else
            flag_warn "$_lib not found (needed for DRM/X11 VAAPI backend)" \
                "Install $_lib via your package manager"
        fi
    fi
done

# Check libva version
LIBVA_PKG_VER=$(dpkg-query -W -f='${Status} ${Version}' libva2 2>/dev/null | awk '/install ok installed/{print $NF}')
if [[ -z "$LIBVA_PKG_VER" ]] && command -v pacman &>/dev/null; then
    LIBVA_PKG_VER=$(pacman -Q libva 2>/dev/null | awk '{print $2}')
fi
if [[ -z "$LIBVA_PKG_VER" ]] && command -v rpm &>/dev/null; then
    LIBVA_PKG_VER=$(rpm -q --queryformat '%{VERSION}' libva 2>/dev/null)
fi
if [[ -n "$LIBVA_PKG_VER" ]]; then
    echo -e "  libva Version:   $LIBVA_PKG_VER"
    LIBVA_MINOR=$(grep -oP '^\d+\.\K\d+' <<< "$LIBVA_PKG_VER")
    if [[ -z "$LIBVA_MINOR" ]]; then
        flag_warn "Could not determine libva minor version from '$LIBVA_PKG_VER'" \
            "Version check skipped; ensure libva ≥ 2.20 is installed"
    elif [[ "$LIBVA_MINOR" =~ ^[0-9]+$ && "$LIBVA_MINOR" -lt 20 ]]; then
        flag_warn "libva2 $LIBVA_PKG_VER may be too old for nvidia-vaapi-driver" \
            "Version 2.20+ recommended; upgrade via your package manager"
    fi
fi

# ─── VAAPI System Support ─────────────────────────────────────

divider "VAAPI SYSTEM SUPPORT"

VAAPI_OK=false
if command -v vainfo &>/dev/null; then
    VAINFO_OUTPUT=$(timeout 10 vainfo 2>&1)
    VAINFO_EXIT=$?
    if [[ $VAINFO_EXIT -eq 124 ]]; then
        flag_warn "vainfo timed out after 10s — GPU driver may be in a bad state"
    elif [[ $VAINFO_EXIT -eq 0 ]]; then
        VAAPI_OK=true
        flag_ok "vainfo succeeded (system default driver)"
        echo "$VAINFO_OUTPUT" | grep -E "vainfo:|Driver version|supported profile" | sed 's/^/    /'
    else
        flag_issue "vainfo failed (exit code $VAINFO_EXIT)"
        echo "$VAINFO_OUTPUT" | sed 's/^/    /'
    fi

    if $NVD_INSTALLED; then
        echo ""
        echo "  vainfo with LIBVA_DRIVER_NAME=nvidia:"
        # Note: this test only sets LIBVA_DRIVER_NAME; some systems also need
        # __EGL_VENDOR_LIBRARY_FILENAMES or LIBVA_DRIVERS_PATH to match Firefox's
        # exact runtime environment. A failure here may not reproduce Firefox's behavior.
        VAINFO_NV_OUTPUT=$(LIBVA_DRIVER_NAME=nvidia NVD_BACKEND=direct timeout 10 vainfo 2>&1)
        VAINFO_NV_EXIT=$?
        if [[ $VAINFO_NV_EXIT -eq 124 ]]; then
            flag_warn "vainfo (nvidia driver) timed out after 10s — GPU driver may be in a bad state"
        elif [[ $VAINFO_NV_EXIT -eq 0 ]]; then
            flag_ok "vainfo with nvidia driver succeeded"
            echo "$VAINFO_NV_OUTPUT" | grep -E "vainfo:|Driver version|supported profile" | sed 's/^/    /'
        else
            flag_issue "vainfo with LIBVA_DRIVER_NAME=nvidia failed (exit code $VAINFO_NV_EXIT)"
            echo "$VAINFO_NV_OUTPUT" | sed 's/^/    /'
        fi
    fi
else
    flag_issue "vainfo not installed" "$(install_hint libva-utils)"
fi

echo ""
echo "  Installed VA-API drivers:"
VAAPI_DRIVERS=""
if command -v dpkg &>/dev/null; then
    VAAPI_DRIVERS+=$(dpkg -l 2>/dev/null | grep -iE "va-driver|vdpau|mesa-va|intel-media|nvidia-vaapi|libva-nvidia" | awk '{printf "    %-40s %s\n", $2, $3}')
fi
if command -v rpm &>/dev/null; then
    RPM_DRIVERS=$(rpm -qa 2>/dev/null | grep -iE "va-driver|vdpau|mesa-va|intel-media|libva" | sed 's/^/    /')
    [[ -n "$RPM_DRIVERS" ]] && VAAPI_DRIVERS+=$'\n'"$RPM_DRIVERS"
fi
if command -v pacman &>/dev/null; then
    PACMAN_DRIVERS=$(pacman -Q 2>/dev/null | grep -iE "va-driver|vdpau|mesa-va|intel-media|libva" | awk '{printf "    %-40s %s\n", $1, $2}')
    [[ -n "$PACMAN_DRIVERS" ]] && VAAPI_DRIVERS+=$'\n'"$PACMAN_DRIVERS"
fi
if [[ -n "$VAAPI_DRIVERS" ]]; then
    echo "$VAAPI_DRIVERS"
else
    echo -e "    ${RED}No VA-API drivers found!${NC}"
fi

# ─── Environment Variables ─────────────────────────────────────

divider "ENVIRONMENT VARIABLES"

# Shared grep pattern for env var source scanning — update here when adding vars
_ENV_VAR_NAMES="LIBVA_DRIVER_NAME|NVD_BACKEND|NVD_GPU|MOZ_DISABLE_RDD_SANDBOX|MOZ_X11_EGL|MOZ_ENABLE_WAYLAND|MOZ_LOG|NVD_LOG|LIBVA_DRIVERS_PATH|MOZ_GFX_DEBUG|EGL_PLATFORM|GST_VAAPI_ALL_DRIVERS|MOZ_WEBRENDER|GBM_BACKEND|__GLX_VENDOR_LIBRARY_NAME|__EGL_VENDOR_LIBRARY_FILENAMES"
_ENV_VAR_GREP_PAT="(^|^export )($_ENV_VAR_NAMES)="
_ENV_VAR_GREP_PAT_BARE="^($_ENV_VAR_NAMES)="  # for environment.d/ files (no 'export')

ENV_VARS=(
    "LIBVA_DRIVER_NAME|varies|Forces specific VA driver (nvidia, iHD, radeonsi)|CRITICAL for NVIDIA VAAPI"
    "NVD_BACKEND|direct|nvidia-vaapi-driver backend (EGL backend broken on driver >=525)|CRITICAL"
    "NVD_GPU|varies|CUDA GPU index for multi-GPU systems|Set if wrong GPU is selected"
    "MOZ_DISABLE_RDD_SANDBOX|1|Disables RDD sandbox (may help VAAPI)|Recommended"
    "MOZ_X11_EGL|1|Enables EGL on X11 (needed for VAAPI on X11)|Required on X11"
    "MOZ_ENABLE_WAYLAND|1|Enables native Wayland backend|Usually auto-detected"
    "MOZ_LOG|varies|Logging config (for debugging)|Debug only"
    "NVD_LOG|1|Enable nvidia-vaapi-driver debug output|Debug only"
    "LIBVA_DRIVERS_PATH|varies|Custom path to VA driver libraries|Usually not needed"
    "MOZ_GFX_DEBUG|1|Enables extra gfx debug output|Debug only"
    "EGL_PLATFORM|wayland|EGL platform hint|Usually auto-detected"
    "GST_VAAPI_ALL_DRIVERS|1|Allows all GStreamer VAAPI drivers|For GStreamer apps"
    "MOZ_WEBRENDER|1|Forces WebRender (legacy; prefer gfx.webrender.all)|Legacy"
    "GBM_BACKEND|nvidia-drm|GBM backend for NVIDIA Wayland|Wayland only"
    "__GLX_VENDOR_LIBRARY_NAME|nvidia|Force NVIDIA GLX vendor|Wayland only"
    "__EGL_VENDOR_LIBRARY_FILENAMES|varies|Force NVIDIA EGL vendor lib on multi-vendor EGL systems|Advanced"
)

printf "  %-30s %-15s %-12s %s\n" "VARIABLE" "CURRENT" "SUGGESTED" "DESCRIPTION"
printf "  %-30s %-15s %-12s %s\n" "--------" "-------" "---------" "-----------"

for entry in "${ENV_VARS[@]}"; do
    IFS='|' read -r varname expected desc note <<< "$entry"
    current="${!varname:-<unset>}"

    if [[ "$current" == "<unset>" ]]; then
        icon=" "
    elif [[ "$expected" == "varies" ]]; then
        icon="${GREEN}●${NC}"
    elif [[ "$current" == "$expected" ]]; then
        icon="${GREEN}✔${NC}"
    else
        icon="${YELLOW}~${NC}"
    fi

    printf "  "; printf '%b ' "${icon}"; printf '%-28s %-15s %-12s %s\n' "$varname" "$current" "$expected" "$desc"
done

# Flag critical missing env vars for NVIDIA
echo ""
if [[ "${LIBVA_DRIVER_NAME:-}" != "nvidia" ]] && $NVD_INSTALLED; then
    flag_warn "LIBVA_DRIVER_NAME is not set to 'nvidia' but nvidia-vaapi-driver is installed" \
        "Add LIBVA_DRIVER_NAME=nvidia to /etc/environment"
fi

if [[ "${NVD_BACKEND:-}" != "direct" ]] && $NVD_INSTALLED; then
    NV_DRIVER_MAJOR="${NV_DRIVER_VER%%.*}"
    if [[ "$SESSION_TYPE" == "wayland" ]] && [[ "$NV_DRIVER_MAJOR" =~ ^[0-9]+$ ]] && [[ "$NV_DRIVER_MAJOR" -ge 560 ]]; then
        flag_ok "NVD_BACKEND not required on Wayland with driver $NV_DRIVER_VER ≥ 560 (add NVD_BACKEND=direct to /etc/environment only if VAAPI fails)"
    else
        flag_warn "NVD_BACKEND is not set to 'direct' (EGL backend is broken on driver >=525)" \
            "Add NVD_BACKEND=direct to /etc/environment"
    fi
fi

if [[ -z "${MOZ_DISABLE_RDD_SANDBOX:-}" ]] && $NVD_INSTALLED; then
    flag_warn "MOZ_DISABLE_RDD_SANDBOX is not set" \
        "Add MOZ_DISABLE_RDD_SANDBOX=1 to /etc/environment (required on some setups)"
fi

echo ""
echo "  Env var sources:"
LIBVA_DRIVER_NAME_IN_PERSISTENT=false
PAM_ENV_HAS_HITS=false
# Track which source files define each variable (for shadowing/conflict detection)
declare -A _var_sources  # varname -> space-separated list of source files

_record_var_sources() {
    local _src="$1" _hits="$2"
    local _varname
    while IFS= read -r _line; do
        # Strip optional leading 'export '
        _varname="${_line#export }"
        _varname="${_varname%%=*}"
        [[ -z "$_varname" ]] && continue
        if [[ -n "${_var_sources[$_varname]:-}" ]]; then
            _var_sources[$_varname]+=" $_src"
        else
            _var_sources[$_varname]="$_src"
        fi
    done <<< "$_hits"
}

for _src in /etc/environment "$REAL_HOME/.profile" "$REAL_HOME/.bash_profile" \
            "$REAL_HOME/.pam_environment"; do
    [[ -f "$_src" ]] || continue
    _hits=$(grep -E "$_ENV_VAR_GREP_PAT" "$_src" 2>/dev/null)
    if [[ -n "$_hits" ]]; then
        echo -e "  ${CYAN}$_src${NC}:"
        echo "$_hits" | sed 's/^/    /'
        grep -qE "(^|^export )LIBVA_DRIVER_NAME=" "$_src" 2>/dev/null && LIBVA_DRIVER_NAME_IN_PERSISTENT=true
        [[ "$_src" == "$REAL_HOME/.pam_environment" ]] && PAM_ENV_HAS_HITS=true
        _record_var_sources "$_src" "$_hits"
    fi
done
if $PAM_ENV_HAS_HITS; then
    flag_warn "~/.pam_environment is disabled by default on Ubuntu 22.04+ (CVE-2010-4708) and may not be read" \
        "Move these variables to /etc/environment or ~/.config/environment.d/"
fi
# Check /etc/profile.d/ scripts
for _src in /etc/profile.d/*.sh; do
    [[ -f "$_src" ]] || continue
    _hits=$(grep -E "$_ENV_VAR_GREP_PAT" "$_src" 2>/dev/null)
    if [[ -n "$_hits" ]]; then
        echo -e "  ${CYAN}$_src${NC}:"
        echo "$_hits" | sed 's/^/    /'
        grep -qE "(^|^export )LIBVA_DRIVER_NAME=" "$_src" 2>/dev/null && LIBVA_DRIVER_NAME_IN_PERSISTENT=true
        _record_var_sources "$_src" "$_hits"
    fi
done
# Check ~/.bashrc separately
if [[ -f "$REAL_HOME/.bashrc" ]]; then
    _hits=$(grep -E "$_ENV_VAR_GREP_PAT" "$REAL_HOME/.bashrc" 2>/dev/null)
    if [[ -n "$_hits" ]]; then
        echo -e "  ${CYAN}$REAL_HOME/.bashrc${NC}:"
        echo "$_hits" | sed 's/^/    /'
        _record_var_sources "$REAL_HOME/.bashrc" "$_hits"
        if grep -qE "(^|^export )LIBVA_DRIVER_NAME=" "$REAL_HOME/.bashrc" 2>/dev/null && ! $LIBVA_DRIVER_NAME_IN_PERSISTENT; then
            flag_warn "LIBVA_DRIVER_NAME is set only in ~/.bashrc" \
                "~/.bashrc is not read by GUI-launched applications; move to /etc/environment or ~/.profile"
        fi
    fi
fi
# Check ~/.config/environment.d/ (read by systemd for user environments, e.g. GNOME/Wayland)
# These files use bare KEY=VALUE syntax; 'export' is not valid here
for _src in "$REAL_HOME/.config/environment.d/"*.conf; do
    [[ -f "$_src" ]] || continue
    _hits=$(grep -E "$_ENV_VAR_GREP_PAT_BARE" "$_src" 2>/dev/null)
    if [[ -n "$_hits" ]]; then
        echo -e "  ${CYAN}$_src${NC}:"
        echo "$_hits" | sed 's/^/    /'
        grep -qE "^LIBVA_DRIVER_NAME=" "$_src" 2>/dev/null && LIBVA_DRIVER_NAME_IN_PERSISTENT=true
        _record_var_sources "$_src" "$_hits"
    fi
done

# Warn about variables defined in multiple source files (shadowing/conflict risk)
for _varname in "${!_var_sources[@]}"; do
    _srcs="${_var_sources[$_varname]}"
    # Count source files — use array to avoid wc -w mis-counting paths with spaces
    read -ra _src_arr <<< "$_srcs"
    _src_count="${#_src_arr[@]}"
    if [[ "$_src_count" -gt 1 ]]; then
        flag_warn "$_varname is defined in multiple config files — values may conflict" \
            "Defined in:$(echo "$_srcs" | tr ' ' '\n' | sed 's/^/ /')"
    fi
done
unset _var_sources

# Flag variables that are configured in persistent files but not active in the current environment
# (common after adding to /etc/environment without logging out)
if $LIBVA_DRIVER_NAME_IN_PERSISTENT && [[ -z "${LIBVA_DRIVER_NAME:-}" ]]; then
    flag_warn "LIBVA_DRIVER_NAME is configured in a file but not active in this shell" \
        "Log out and back in (or re-source the config file) for the change to take effect"
fi

# ─── Firefox Preferences ──────────────────────────────────────

divider "FIREFOX PREFERENCES (from prefs.js / user.js)"

# Locate Firefox profile(s)
PROFILE_DIRS=()
declare -A PROFILE_NAMES  # maps profile path -> Name= from profiles.ini

for base in "$REAL_HOME/.mozilla/firefox" "$REAL_HOME/snap/firefox/common/.mozilla/firefox" "$REAL_HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
    if [[ -f "$base/profiles.ini" ]]; then
        _cur_name=""
        _is_relative=1  # default: relative
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[Profile ]]; then
                # Reset all tracking vars at every new profile section header to prevent
                # stale data leaking between sections if they are out of order
                _cur_name=""
                _is_relative=1
            elif [[ "$line" =~ ^Name= ]]; then
                _cur_name="${line#Name=}"
            elif [[ "$line" =~ ^IsRelative= ]]; then
                _is_relative="${line#IsRelative=}"
            elif [[ "$line" =~ ^Path= ]]; then
                p="${line#Path=}"
                if [[ "$_is_relative" == "0" || "$p" == /* ]]; then
                    PROFILE_DIRS+=("$p")
                    PROFILE_NAMES["$p"]="$_cur_name"
                else
                    PROFILE_DIRS+=("$base/$p")
                    PROFILE_NAMES["$base/$p"]="$_cur_name"
                fi
                _cur_name=""
                _is_relative=1  # reset for next section
            fi
        done < "$base/profiles.ini"
    fi
done

if [[ ${#PROFILE_DIRS[@]} -eq 0 ]]; then
    echo -e "  ${RED}No Firefox profiles found!${NC}"
else
    # Prefs: name|expected|critical(yes/no)|firefox_default|description
    # firefox_default = Firefox's built-in default when not set in prefs.js
    PREFS=(
        "media.rdd-process.enabled|true|yes|true|RDD process hosts VAAPI decoder — MUST be true"
        "media.ffmpeg.vaapi.enabled|true|yes|false|Master VAAPI switch (required until FF137)"
        "media.hardware-video-decoding.enabled|true|yes|true|General HW decode switch"
        "media.hardware-video-decoding.force-enabled|true|yes|false|Force HW decode even if blocklisted"
        "widget.dmabuf.force-enabled|true|yes|false|Force DMA-BUF for HW decode buffer sharing"
        "media.rdd-ffmpeg.enabled|true|no|true|FFmpeg in RDD process"
        "media.ffvpx.enabled|varies|no|true|FFVPX software decoder (disabling may force VAAPI path)"
        "media.av1.enabled|true|no|true|AV1 codec support"
        "media.ffmpeg.enabled|true|no|true|FFmpeg integration"
        "gfx.webrender.all|true|no|false|Force WebRender everywhere"
        "gfx.webrender.enabled|true|no|true|WebRender enabled"
        "gfx.x11-egl.force-enabled|true|no|false|Force EGL on X11"
        "gfx.canvas.accelerated|true|no|true|Accelerated canvas"
        "layers.acceleration.force-enabled|true|no|false|Force GPU-accelerated layers"
        "widget.wayland.opaque-region.enabled|varies|no|true|Wayland opaque region optimization"
        "media.navigator.mediadatadecoder_vpx_enabled|varies|no|true|VPX media data decoder"
        "media.ffmpeg.low-latency.enabled|varies|no|false|Low-latency FFmpeg decoding"
        "media.utility-ffmpeg.enabled|varies|no|true|FFmpeg in Utility process"
    )

    if pgrep -u "$REAL_USER" -x firefox &>/dev/null || pgrep -u "$REAL_USER" -x firefox-esr &>/dev/null; then
        flag_warn "Firefox is currently running — prefs.js may be stale; changes in about:config won't persist until restart"
    fi

    for profile_dir in "${PROFILE_DIRS[@]}"; do
        if [[ ! -d "$profile_dir" ]]; then
            continue
        fi

        _profile_basename=$(basename "$profile_dir")
        _profile_ini_name="${PROFILE_NAMES[$profile_dir]:-}"
        if [[ -n "$FILTER_PROFILE" ]]; then
            _filter_lower="${FILTER_PROFILE,,}"
            if [[ "${_profile_basename,,}" != *"$_filter_lower"* \
                  && "${_profile_ini_name,,}" != *"$_filter_lower"* ]]; then
                continue
            fi
        fi

        profile_name=$(basename "$profile_dir")
        echo ""
        echo -e "  ${BOLD}Profile: $profile_name${NC}"
        echo -e "  Path:   $profile_dir"
        echo ""

        PREFS_FILE="$profile_dir/prefs.js"
        USER_FILE="$profile_dir/user.js"

        if [[ ! -f "$PREFS_FILE" && ! -f "$USER_FILE" ]]; then
            echo -e "    ${YELLOW}No prefs.js or user.js found (profile may not have been used yet)${NC}"
            continue
        fi

        printf "    %-52s %-16s %-10s  %s\n" "PREFERENCE" "CURRENT" "EXPECTED" "SOURCE"
        printf "    %-52s %-16s %-10s  %s\n" "----------" "-------" "--------" "------"

        unset pref_values; declare -A pref_values  # cache extracted values for post-loop checks
        for entry in "${PREFS[@]}"; do
            IFS='|' read -r pref expected critical ff_default desc <<< "$entry"

            if [[ "$pref" == "media.ffmpeg.vaapi.enabled" && -n "$FF_MAJOR" && "$FF_MAJOR" -ge 137 ]]; then
                printf "    "; printf '%b ' "${CYAN}–${NC}"; printf '%-50s %-16s %-10s  %s\n' \
                    "$pref" "(removed in FF 137)" "N/A" "N/A"
                continue
            fi

            current="<not set>"
            source=""

            if [[ -f "$PREFS_FILE" ]]; then
                val=$(grep -oP "user_pref\\(\"${pref//./\\.}\",\\s*\\K(?:\"[^\"]*\"|true|false|-?\\d+)" "$PREFS_FILE" 2>/dev/null | tail -1)
                if [[ -n "$val" ]]; then
                    current="$val"
                    source="prefs.js"
                fi
            fi

            if [[ -f "$USER_FILE" ]]; then
                val=$(grep -oP "user_pref\\(\"${pref//./\\.}\",\\s*\\K(?:\"[^\"]*\"|true|false|-?\\d+)" "$USER_FILE" 2>/dev/null | tail -1)
                if [[ -n "$val" ]]; then
                    current="$val"
                    source="user.js"
                fi
            fi

            # Determine icon — account for Firefox defaults when pref is not set
            if [[ "$current" == "<not set>" ]]; then
                if [[ "$expected" == "varies" ]]; then
                    icon=" "
                elif [[ -n "$ff_default" && "$ff_default" == "$expected" ]]; then
                    # Not set, but Firefox default matches expected — OK
                    icon="${GREEN}✔${NC}"
                    current="(default: $ff_default)"
                    source="built-in"
                elif [[ "$critical" == "yes" ]]; then
                    icon="${YELLOW}!${NC}"
                    current="(default: ${ff_default:-?})"
                    source="built-in"
                else
                    icon=" "
                fi
            elif [[ "$expected" == "varies" ]]; then
                icon="${CYAN}●${NC}"
            elif [[ "$current" == "$expected" ]]; then
                icon="${GREEN}✔${NC}"
            else
                if [[ "$critical" == "yes" ]]; then
                    icon="${RED}✘${NC}"
                else
                    icon="${YELLOW}~${NC}"
                fi
            fi

            pref_values["$pref"]="$current"
            printf "    "; printf '%b ' "${icon}"; printf '%-50s %-16s %-10s  %s\n' "$pref" "$current" "$expected" "$source"
        done

        # Specific critical check for media.rdd-process.enabled (reuse cached value)
        echo ""
        rdd_val="${pref_values[media.rdd-process.enabled]:-}"
        av1_val="${pref_values[media.av1.enabled]:-}"
        unset pref_values

        if [[ "$rdd_val" == "false" ]]; then
            flag_issue "CRITICAL: media.rdd-process.enabled is FALSE" \
                "VA-API decoding CANNOT work without the RDD process — set to true in about:config immediately"
        fi

        # Warn if AV1 is enabled on a pre-Ampere GPU (NVDEC AV1 requires Ampere / RTX 30xx+)
        if ${NV_IS_PRE_AMPERE:-false} && [[ "$av1_val" != "false" ]]; then
            flag_warn "media.av1.enabled is true but NVDEC AV1 hardware decode requires Ampere (RTX 30xx+)" \
                "AV1 will fall back to software decode on $NV_GPU_NAME — this is expected on pre-Ampere hardware"
        fi
    done
fi

# ─── Detect NVIDIA render node ─────────────────────────────────

NVIDIA_RENDER_NODE=""
NVIDIA_RENDER_NODE_FOUND=false
for _node in /dev/dri/render*; do
    [[ -e "$_node" ]] || continue
    _drv_link=$(readlink -f "/sys/class/drm/$(basename "$_node")/device/driver" 2>/dev/null)
    _drv=""
    [[ -n "$_drv_link" ]] && _drv=$(basename "$_drv_link" 2>/dev/null)
    if [[ "$_drv" == "nvidia" ]]; then
        NVIDIA_RENDER_NODE="$_node"
        NVIDIA_RENDER_NODE_FOUND=true
        break
    fi
done

# ─── DRM Render Nodes ─────────────────────────────────────────

divider "DRM RENDER NODES"

RENDER_NODES=(/dev/dri/render*)
if [[ -e "${RENDER_NODES[0]}" ]]; then
    for node in "${RENDER_NODES[@]}"; do
        perms=$(stat -c '%A %U:%G' "$node" 2>/dev/null)
        node_name=$(basename "$node")
        echo -e "  $node  $perms"

        # Show which GPU this render node belongs to
        driver_link=$(readlink -f "/sys/class/drm/$node_name/device/driver" 2>/dev/null)
        driver_name=""
        [[ -n "$driver_link" ]] && driver_name=$(basename "$driver_link" 2>/dev/null)
        pci_path=$(readlink -f "/sys/class/drm/$node_name/device" 2>/dev/null)
        pci_id=""
        if [[ -f "$pci_path/vendor" && -f "$pci_path/device" ]]; then
            vendor=$(cat "$pci_path/vendor" 2>/dev/null)
            device=$(cat "$pci_path/device" 2>/dev/null)
            pci_id="$vendor:$device"
        fi
        echo -e "    Driver: ${driver_name:-unknown}  PCI: ${pci_id:-unknown}"

        if [[ -r "$node" && -w "$node" ]]; then
            echo -e "    ${GREEN}Current user has read/write access${NC}"
        else
            echo -e "    ${RED}Current user lacks access — add yourself to 'video' or 'render' group${NC}"
        fi
        echo ""
    done

    # Warn about multi-GPU ambiguity
    NODE_COUNT=${#RENDER_NODES[@]}
    if [[ $NODE_COUNT -gt 1 ]]; then
        flag_warn "Multiple render nodes detected ($NODE_COUNT GPUs)" \
            "If VAAPI selects the wrong GPU, set NVD_GPU=<cuda_index> in /etc/environment"
        if [[ -n "${NVD_GPU:-}" ]]; then
            if [[ "$NVD_GPU" =~ ^[0-9]+$ ]]; then
                CUDA_GPU_COUNT=$(timeout 5 nvidia-smi --list-gpus 2>/dev/null | wc -l)
                if [[ "$CUDA_GPU_COUNT" =~ ^[0-9]+$ && "$CUDA_GPU_COUNT" -gt 0 ]]; then
                    if [[ "$NVD_GPU" -ge "$CUDA_GPU_COUNT" ]]; then
                        flag_warn "NVD_GPU=$NVD_GPU is out of range (valid: 0–$((CUDA_GPU_COUNT - 1)); $CUDA_GPU_COUNT CUDA device(s) found)" \
                            "Set NVD_GPU to a value between 0 and $((CUDA_GPU_COUNT - 1))"
                    else
                        flag_ok "NVD_GPU is set to $NVD_GPU"
                    fi
                else
                    flag_ok "NVD_GPU is set to $NVD_GPU"
                fi
            else
                flag_warn "NVD_GPU='$NVD_GPU' is not a valid integer (should be CUDA GPU index, e.g. 0 or 1)"
            fi
        fi
    fi
else
    flag_issue "No render nodes found in /dev/dri/"
fi

echo ""
echo "  User ($REAL_USER) groups: $(id -nG "$REAL_USER" 2>/dev/null || groups)"
echo ""
REQUIRED_GROUPS=("video" "render")
for grp in "${REQUIRED_GROUPS[@]}"; do
    if id -nG "$REAL_USER" 2>/dev/null | grep -qw "$grp"; then
        flag_ok "$REAL_USER is a member of '$grp'"
    else
        flag_issue "$REAL_USER is not a member of '$grp'" "sudo usermod -aG $grp $REAL_USER (then log out/in)"
    fi
done

# ─── Live Decode Test ──────────────────────────────────────────

divider "LIVE DECODE CHECK"

if command -v nvidia-smi &>/dev/null; then
    DECODER_UTIL=$(timeout 10 nvidia-smi --query-gpu=utilization.decoder --format=csv,noheader,nounits 2>/dev/null | head -1)
    PMON_OUTPUT=$(timeout 10 nvidia-smi pmon -c 1 2>/dev/null)
    FIREFOX_PIDS=$(awk 'NR>2 && $8~/^firefox/{printf "%s%s", sep, $1; sep=","}' <<< "$PMON_OUTPUT")
    RDD_LINE=$(echo "$PMON_OUTPUT" | awk 'NR>2 && $8 == "rdd"')

    if [[ "$DECODER_UTIL" =~ ^[0-9]+$ && "$DECODER_UTIL" -gt 0 ]]; then
        flag_ok "NVDEC decoder is active (${DECODER_UTIL}% utilization)"
    else
        echo -e "  Decoder utilization: ${DECODER_UTIL:-0}% (play a video and re-run to test)"
    fi

    if [[ -n "$FIREFOX_PIDS" ]]; then
        flag_ok "Firefox processes on GPU: $FIREFOX_PIDS"
    else
        echo -e "  No Firefox processes detected on GPU (is Firefox running with video?)"
    fi

    # Show RDD process type
    if [[ -n "$RDD_LINE" ]]; then
        RDD_TYPE=$(echo "$RDD_LINE" | awk '{print $3}')
        flag_ok "RDD process on GPU (type: $RDD_TYPE)"
    fi
else
    echo -e "  ${YELLOW}nvidia-smi not available — cannot check live decode status${NC}"
fi

# ─── Summary ──────────────────────────────────────────────────

divider "SUMMARY"

# Collect summary checks (some already counted above)

# Check VAAPI driver (reuse result from VAAPI SYSTEM SUPPORT section above)
# Note: do NOT call flag_ok/flag_issue here — those were already counted in the
# VAAPI SYSTEM SUPPORT section; this recap just re-displays the status.
if $VAAPI_OK; then
    echo -e "  ${GREEN}✔${NC} VAAPI working at system level"
else
    echo -e "  ${RED}✘${NC} VAAPI not working at system level — fix drivers first (see above)"
fi

# Check display server + env var combo
if [[ "$SESSION_TYPE" == "x11" && "${MOZ_X11_EGL:-}" != "1" ]]; then
    flag_issue "On X11 but MOZ_X11_EGL is not set" \
        "export MOZ_X11_EGL=1 (add to /etc/environment)"
elif [[ "$SESSION_TYPE" == "wayland" && "${MOZ_ENABLE_WAYLAND:-}" != "1" ]]; then
    flag_warn "On Wayland but MOZ_ENABLE_WAYLAND is not set (may auto-detect)"
fi

# Check snap
if $FIREFOX_IS_SNAP; then
    flag_warn "Firefox is a Snap — consider switching to .deb for better VAAPI support"
fi

# Check render node access
if ! $NVIDIA_RENDER_NODE_FOUND; then
    flag_issue "No NVIDIA render node detected in /dev/dri/" \
        "Check that nvidia kernel modules are loaded: lsmod | grep nvidia"
elif ! [[ -r "$NVIDIA_RENDER_NODE" && -w "$NVIDIA_RENDER_NODE" ]] 2>/dev/null; then
    flag_issue "No access to $NVIDIA_RENDER_NODE" \
        "Add yourself to the 'render' and 'video' groups: sudo usermod -aG render,video $REAL_USER"
else
    flag_ok "NVIDIA render node $NVIDIA_RENDER_NODE accessible"
fi

echo ""
if [[ $issues -eq 0 && $warnings -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All checks passed!${NC}"
elif [[ $issues -eq 0 ]]; then
    echo -e "  ${YELLOW}Found $warnings warning(s), no critical issues.${NC}"
    echo ""
    echo -e "  ${CYAN}Tip:${NC} To test with full logging, run:"
    echo -e "    NVD_LOG=1 MOZ_LOG=\"PlatformDecoderModule:5\" firefox 2>&1 | tee /tmp/ff-vaapi.log"
else
    echo -e "  ${RED}${BOLD}Found $issues critical issue(s)${NC} and ${YELLOW}$warnings warning(s).${NC}"
    echo -e "  Fix the ${RED}✘${NC} items above first, then re-run this script."
    echo ""
    echo -e "  ${CYAN}Tip:${NC} To test with full logging, run:"
    echo -e "    NVD_LOG=1 MOZ_LOG=\"PlatformDecoderModule:5\" firefox 2>&1 | tee /tmp/ff-vaapi.log"
fi
echo ""