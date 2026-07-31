#!/usr/bin/env bash
#
# VMware Linux Health Check
# Read-only diagnostics for VMware Workstation host modules and networking.
#
# Usage:
#   chmod +x verify.sh
#   ./verify.sh
#   ./verify.sh --report
#   ./verify.sh --no-color
#

set -u

VERSION="1.0.0"
EXPECTED_VMWARE_VERSION="17.6.3"
EXPECTED_BRANCH="workstation-17.6.3"
REPORT_FILE="vmware-report.txt"

USE_COLOR=1
CREATE_REPORT=0
INTERNAL_REPORT=0

for arg in "$@"; do
    case "$arg" in
        --report)
            CREATE_REPORT=1
            ;;
        --no-color)
            USE_COLOR=0
            ;;
        --internal-report)
            INTERNAL_REPORT=1
            USE_COLOR=0
            ;;
        -h|--help)
            cat <<EOF
VMware Linux Health Check v${VERSION}

Usage:
  ./verify.sh              Run diagnostics
  ./verify.sh --report     Run diagnostics and save ${REPORT_FILE}
  ./verify.sh --no-color   Disable ANSI colors
  ./verify.sh --help       Show this help
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Run ./verify.sh --help for usage."
            exit 2
            ;;
    esac
done

if [[ "$CREATE_REPORT" -eq 1 && "$INTERNAL_REPORT" -eq 0 ]]; then
    SCRIPT_PATH="$(readlink -f "$0")"
    "$SCRIPT_PATH" --internal-report | tee "$REPORT_FILE"
    printf '\nReport saved to: %s\n' "$(readlink -f "$REPORT_FILE")"
    exit "${PIPESTATUS[0]}"
fi

if [[ "$USE_COLOR" -eq 1 && -t 1 && -z "${NO_COLOR:-}" ]]; then
    RESET=$'\033[0m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    CYAN=$'\033[36m'
else
    RESET=""
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
fi

PASS=0
WARN=0
FAIL=0
FIXES=()

line() {
    printf '%s\n' "======================================================================"
}

section() {
    printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"
    printf '%s\n' "----------------------------------------------------------------------"
}

pass() {
    PASS=$((PASS + 1))
    printf '  %s✔%s %-30s %s\n' "$GREEN" "$RESET" "$1" "${2:-}"
}

warn() {
    WARN=$((WARN + 1))
    printf '  %s!%s %-30s %s\n' "$YELLOW" "$RESET" "$1" "${2:-}"
    [[ -n "${3:-}" ]] && FIXES+=("$1|$3")
}

fail() {
    FAIL=$((FAIL + 1))
    printf '  %s✘%s %-30s %s\n' "$RED" "$RESET" "$1" "${2:-}"
    [[ -n "${3:-}" ]] && FIXES+=("$1|$3")
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

module_loaded() {
    grep -qE "^${1}[[:space:]]" /proc/modules 2>/dev/null
}

module_available() {
    modinfo "$1" >/dev/null 2>&1
}

device_or_interface_exists() {
    local name="$1"
    [[ -e "/dev/$name" ]] || ip link show "$name" >/dev/null 2>&1
}

get_os_name() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        printf '%s' "${PRETTY_NAME:-${NAME:-Unknown Linux}}"
    else
        printf 'Unknown Linux'
    fi
}

get_vmware_version() {
    local version=""
    if [[ -r /etc/vmware/config ]]; then
        version="$(sed -n 's/^product\.version = "\(.*\)"/\1/p' /etc/vmware/config | head -n1)"
    fi
    if [[ -z "$version" ]] && command_exists vmware; then
        version="$(vmware -v 2>/dev/null | awk '{print $3}' | head -n1)"
    fi
    printf '%s' "$version"
}

print_header() {
    clear 2>/dev/null || true
    line
    printf '%s%s        VMware Linux Health Check v%s%s\n' "$BOLD" "$CYAN" "$VERSION" "$RESET"
    line
    printf '%sRead-only diagnostics for VMware Workstation on Linux.%s\n' "$DIM" "$RESET"
}

print_header

OS_NAME="$(get_os_name)"
KERNEL="$(uname -r)"
ARCH="$(uname -m)"
VMWARE_VERSION="$(get_vmware_version)"

section "🖥  System"
pass "Distribution" "$OS_NAME"
pass "Kernel" "$KERNEL"
pass "Architecture" "$ARCH"

if [[ -r /proc/meminfo ]]; then
    RAM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    RAM_GB="$((RAM_KB / 1024 / 1024)) GB"
    pass "Memory" "$RAM_GB"
fi

section "📦 VMware installation"

if command_exists vmware; then
    pass "VMware executable" "$(command -v vmware)"
else
    fail "VMware executable" "Not found" \
        "Install VMware Workstation before running this diagnostic."
fi

if [[ -n "$VMWARE_VERSION" ]]; then
    if [[ "$VMWARE_VERSION" == "$EXPECTED_VMWARE_VERSION" ]]; then
        pass "VMware version" "$VMWARE_VERSION"
    else
        warn "VMware version" "$VMWARE_VERSION (guide targets $EXPECTED_VMWARE_VERSION)" \
            "Use a patched branch matching your exact VMware version."
    fi
else
    fail "VMware version" "Could not determine" \
        "Check /etc/vmware/config or run: vmware -v"
fi

if command_exists vmware-installer; then
    pass "VMware installer" "$(command -v vmware-installer)"
else
    warn "VMware installer" "Not found"
fi

section "🛠  Build environment"

for tool in gcc make git; do
    if command_exists "$tool"; then
        if [[ "$tool" == "gcc" ]]; then
            detail="$(gcc --version 2>/dev/null | head -n1)"
        else
            detail="$(command -v "$tool")"
        fi
        pass "$tool" "$detail"
    else
        fail "$tool" "Missing" \
            "Install required tools: sudo apt install build-essential git"
    fi
done

HEADER_PATH="/lib/modules/$KERNEL/build"
if [[ -e "$HEADER_PATH" ]]; then
    pass "Kernel headers" "$HEADER_PATH"
else
    fail "Kernel headers" "Missing for $KERNEL" \
        "Install them with: sudo apt install linux-headers-\$(uname -r)"
fi

section "🧩 Kernel modules"

for module in vmmon vmnet; do
    if module_available "$module"; then
        MODULE_FILE="$(modinfo -n "$module" 2>/dev/null || true)"
        pass "$module installed" "$MODULE_FILE"
    else
        fail "$module installed" "Module not found" \
            "Build and install the patched modules: make && sudo make install"
    fi

    if module_loaded "$module"; then
        pass "$module loaded" "Loaded in the running kernel"
    else
        fail "$module loaded" "Not loaded" \
            "Load it with: sudo modprobe $module"
    fi
done

section "🔌 VMware devices"

if [[ -e /dev/vmmon ]]; then
    pass "/dev/vmmon" "$(ls -l /dev/vmmon 2>/dev/null)"
else
    fail "/dev/vmmon" "Missing" \
        "Run: sudo modprobe vmmon"
fi

section "🌐 Virtual networking"

for tool in vmware-netcfg vmware-networks; do
    if command_exists "$tool"; then
        pass "$tool" "$(command -v "$tool")"
    else
        warn "$tool" "Not found"
    fi
done

for net in vmnet0 vmnet1 vmnet8; do
    if device_or_interface_exists "$net"; then
        if [[ -e "/dev/$net" ]]; then
            detail="/dev/$net"
        else
            detail="network interface"
        fi
        pass "$net" "$detail"
    else
        warn "$net" "Not found" \
            "Run vmware-netcfg, choose Restore Defaults, save, and restart VMware."
    fi
done

if [[ -r /etc/vmware/networking ]]; then
    pass "Network configuration" "/etc/vmware/networking"
else
    warn "Network configuration" "File not found" \
        "Run vmware-netcfg and restore the default networks."
fi

section "📋 Recent VMware kernel messages"

if [[ "$EUID" -eq 0 ]]; then
    DMESG_OUTPUT="$(dmesg 2>/dev/null | grep -Ei 'vmmon|vmnet' | tail -n 8 || true)"
elif command_exists sudo && sudo -n true 2>/dev/null; then
    DMESG_OUTPUT="$(sudo -n dmesg 2>/dev/null | grep -Ei 'vmmon|vmnet' | tail -n 8 || true)"
else
    DMESG_OUTPUT=""
fi

if [[ -n "$DMESG_OUTPUT" ]]; then
    printf '%s\n' "$DMESG_OUTPUT" | sed 's/^/  /'
else
    printf '  %sNo accessible vmmon/vmnet messages found.%s\n' "$DIM" "$RESET"
    printf '  Run manually: sudo dmesg | grep -Ei "vmmon|vmnet"\n'
fi

section "💡 Suggested fixes"

if [[ "${#FIXES[@]}" -eq 0 ]]; then
    printf '  %sNo corrective actions are currently suggested.%s\n' "$GREEN" "$RESET"
else
    index=1
    for entry in "${FIXES[@]}"; do
        title="${entry%%|*}"
        fix="${entry#*|}"
        printf '  %s%d.%s %s%s%s\n' "$YELLOW" "$index" "$RESET" "$BOLD" "$title" "$RESET"
        printf '     %s\n\n' "$fix"
        index=$((index + 1))
    done
fi

TOTAL=$((PASS + WARN + FAIL))

printf '\n'
line
printf '%s%s                         FINAL REPORT%s\n' "$BOLD" "$CYAN" "$RESET"
line
printf '  Checks: %s%d%s   Passed: %s%d%s   Warnings: %s%d%s   Failed: %s%d%s\n' \
    "$BOLD" "$TOTAL" "$RESET" \
    "$GREEN" "$PASS" "$RESET" \
    "$YELLOW" "$WARN" "$RESET" \
    "$RED" "$FAIL" "$RESET"
printf '\n'

if [[ "$FAIL" -eq 0 && "$WARN" -eq 0 ]]; then
    printf '  %s%s✓ SYSTEM HEALTHY%s\n' "$BOLD" "$GREEN" "$RESET"
    printf '  VMware appears to be fully configured. Happy virtualizing! 🚀\n'
    EXIT_CODE=0
elif [[ "$FAIL" -eq 0 ]]; then
    printf '  %s%s⚠ SYSTEM WORKING WITH WARNINGS%s\n' "$BOLD" "$YELLOW" "$RESET"
    printf '  VMware may work, but review the warnings above.\n'
    EXIT_CODE=0
else
    printf '  %s%s✘ PROBLEMS DETECTED%s\n' "$BOLD" "$RED" "$RESET"
    printf '  Review the suggested fixes above.\n'
    EXIT_CODE=1
fi

line

if [[ "$INTERNAL_REPORT" -eq 1 ]]; then
    printf '\nGenerated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
fi

exit "$EXIT_CODE"
