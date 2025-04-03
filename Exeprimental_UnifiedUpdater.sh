#!/usr/bin/bash

# === Configuration ===
# Set to true to automatically run cleanup tasks, false to skip.
# Can be overridden with --clean or --no-clean arguments.
AUTO_CLEANUP=false
# Set to true to automatically confirm package manager upgrades (USE WITH CAUTION).
# Can be overridden with --yes or -y argument.
AUTO_CONFIRM_UPGRADES=false

# === Colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# === Helper Functions ===
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_cmd() {
    # Log the command, masking potential sensitive info if needed in future
    echo -e "${PURPLE}[CMD]${NC} $1"
}

# Function to run commands and check exit status
run_command() {
    local cmd_string="$1"
    log_cmd "$cmd_string"
    # Use eval carefully, primarily for commands involving pipes or complex structures passed as a single string
    eval "$cmd_string"
    local status=$?
    if [ $status -ne 0 ]; then
        log_error "Command failed with status $status: $cmd_string"
    fi
    return $status
}

# Get disk usage info (Used GiB, Total GiB) for a given mount point (default /)
get_disk_info() {
    local mount_point="${1:-/}"
    local disk_info
    disk_info=$(df --output=used,size "$mount_point" 2>/dev/null | awk 'NR==2')
    if [ -z "$disk_info" ]; then
        log_warning "Could not get disk info for $mount_point"
        echo "0.00 0.00"
        return 1
    fi

    local disk_used_kib
    local disk_total_kib
    disk_used_kib=$(echo "$disk_info" | awk '{print $1}')
    disk_total_kib=$(echo "$disk_info" | awk '{print $2}')

    # Check if values are numeric before calculation
    if ! [[ "$disk_used_kib" =~ ^[0-9]+$ ]] || ! [[ "$disk_total_kib" =~ ^[0-9]+$ ]]; then
         log_warning "Invalid disk size numbers obtained: used='$disk_used_kib', total='$disk_total_kib'"
         echo "0.00 0.00"
         return 1
    fi

    local disk_used_gib
    local disk_total_gib
    disk_used_gib=$(awk "BEGIN {printf \"%.2f\", $disk_used_kib / 1024 / 1024}")
    disk_total_gib=$(awk "BEGIN {printf \"%.2f\", $disk_total_kib / 1024 / 1024}")

    echo "$disk_used_gib $disk_total_gib"
}

# Calculate and display disk space saved
display_disk_saved() {
    local usage_before_gib=$1
    local total_before_gib=$2
    local usage_after_gib=$3
    local total_after_gib=$4 # Usually same as before, but recalculate just in case

    log_info "Disk Usage Before: ${usage_before_gib} GiB / ${total_before_gib} GiB"
    log_info "Disk Usage After:  ${usage_after_gib} GiB / ${total_after_gib} GiB"
    # Check if inputs are valid numbers before calculation
     if ! [[ "$usage_before_gib" =~ ^[0-9]+(\.[0-9]+)?$ ]] || \
        ! [[ "$usage_after_gib" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_warning "Cannot calculate disk savings due to invalid input."
        return 1
     fi

    local saved_gib
    saved_gib=$(bc -l <<< "scale=2; $usage_before_gib - $usage_after_gib")

    if (( $(echo "$saved_gib > 0.00" | bc -l) )); then
        log_success "Freed up ${saved_gib} GiB of disk space."
    elif (( $(echo "$saved_gib == 0.00" | bc -l) )); then
        log_info "No significant disk space freed up by cleaning."
    else
        # This shouldn't normally happen unless something wrote data during cleanup
        log_warning "Disk usage increased by ${saved_gib#-} GiB after cleaning."
    fi
}

# === Core Functions ===

check_boot_partition() {
    log_info "Checking /boot partition..."
    if mountpoint -q /boot; then
        log_success "/boot is mounted."
        return 0
    else
        log_warning "/boot is NOT mounted. This might cause issues if a kernel update occurs."
        # Decide if this should be fatal
        # read -p "Press Enter to continue despite warning, or Ctrl+C to abort..."
        return 1 # Indicate a potential issue
    fi
}

update_os() {
    local pm=$1
    local update_cmd=$2
    local upgrade_cmd=$3
    local package_count_cmd=$4
    local packages_desc=$5
    # The confirm_flag ($6) is handled directly in the call now

    local package_count
    package_count=$(eval "$package_count_cmd" 2>/dev/null) # Suppress stderr from count cmd
    # Check if package count command succeeded and got a number
    if ! [[ "$package_count" =~ ^[0-9]+$ ]]; then
       log_warning "Could not determine package count accurately. Command used: '$package_count_cmd'"
       package_count="N/A" # Set to N/A if count failed
    fi
    log_info "Detected $pm ($package_count $packages_desc)"

    # Only run update_cmd if it's not empty
    if [ -n "$update_cmd" ]; then
        log_info "Updating package lists..."
        run_command "sudo $update_cmd" || return 1 # Stop if explicit update fails
    else
        # Optional: Log that the step is skipped/integrated
        log_info "Package list update is integrated with upgrade command for $pm."
    fi

    log_info "Upgrading packages..."
    run_command "sudo $upgrade_cmd" || return 1 # Run the already assembled upgrade command

    log_success "$pm package upgrade complete."
    return 0 # Explicitly return 0 on success
}


clean_os() {
    local pm=$1
    local autoremove_cmd=$2
    local clean_cache_cmd=$3
    local cache_path=$4
    local cache_size_cmd="du -sh $cache_path 2>/dev/null || echo '0K'" # Handle non-existent cache

    log_info "Starting cleanup for $pm..."

    if [ -n "$autoremove_cmd" ]; then
        log_info "Removing unused packages..."
        run_command "sudo $autoremove_cmd" # Assume flags like --noconfirm/-y are part of the command string
    fi

    if [ -n "$clean_cache_cmd" ]; then
        log_info "Cleaning package manager cache ($cache_path)..."
        local cache_size_before
        cache_size_before=$(eval "$cache_size_cmd")
        log_info "Cache size before: $cache_size_before"
        run_command "sudo $clean_cache_cmd" # Assume flags are part of the command string
        local cache_size_after
        cache_size_after=$(eval "$cache_size_cmd")
        log_info "Cache size after: $cache_size_after"
    fi

    log_info "Cleaning user cache (~/.cache)..."
    if [ -d "$HOME/.cache" ]; then
        local user_cache_size_before
        user_cache_size_before=$(du -sh "$HOME/.cache" 2>/dev/null)
        log_info "User cache size before: $user_cache_size_before"
        # Use find to delete contents - safer than rm -rf * with weird filenames
        run_command "find '$HOME/.cache' -mindepth 1 -delete"
        local user_cache_size_after
        user_cache_size_after=$(du -sh "$HOME/.cache" 2>/dev/null)
        log_info "User cache size after: $user_cache_size_after"
    else
       log_info "User cache directory (~/.cache) not found."
    fi

    log_success "$pm cleanup complete."
}

update_flatpak() {
    if command -v flatpak &> /dev/null; then
        log_info "Checking for Flatpak updates..."
        local flatpak_count
        flatpak_count=$(flatpak list --app | wc -l) # Count only apps
        if [ "$flatpak_count" -gt 0 ]; then
             log_info "Found $flatpak_count Flatpak applications."
             run_command "flatpak update $FLATPAK_CONFIRM_FLAG" # Use flag set earlier
        else
             log_info "No Flatpaks applications installed or detected."
        fi
    else
        log_info "Flatpak not installed."
    fi
}

# === Argument Parsing ===
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--clean) AUTO_CLEANUP=true; shift ;;
        --no-clean) AUTO_CLEANUP=false; shift ;;
        -y|--yes) AUTO_CONFIRM_UPGRADES=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--clean | --no-clean] [-y | --yes] [-h | --help]"
            echo "  --clean      Perform cleanup tasks after updates (overrides config)."
            echo "  --no-clean   Skip cleanup tasks (overrides config)."
            echo "  -y, --yes    Automatically confirm package manager upgrades (use with caution)."
            echo "  -h, --help   Show this help message."
            exit 0
            ;;
        *) log_warning "Unknown parameter passed: $1"; exit 1 ;;
    esac
    # Removed shift from here, handled in each case
done

# Determine confirmation flags based on AUTO_CONFIRM_UPGRADES
# These flags are now appended directly to the command strings where needed
PACMAN_CONFIRM_FLAG=""
APT_CONFIRM_FLAG=""
DNF_CONFIRM_FLAG=""
FLATPAK_CONFIRM_FLAG=""

if [ "$AUTO_CONFIRM_UPGRADES" = true ]; then
    log_warning "AUTO-CONFIRMING package upgrades!"
    PACMAN_CONFIRM_FLAG="--noconfirm"
    APT_CONFIRM_FLAG="-y"
    DNF_CONFIRM_FLAG="-y"
    FLATPAK_CONFIRM_FLAG="-y"
    # Cleanup flags are hardcoded below as they are less risky
fi

# === Main Execution ===

echo -e "${BOLD}${CYAN}=== System Update Script ===${NC}"
log_info "Date: $(date)"
log_info "Auto-Cleanup: ${AUTO_CLEANUP}"
log_info "Auto-Confirm Upgrades: ${AUTO_CONFIRM_UPGRADES}"
echo "-----------------------------"

# --- Pre-checks ---
if [ "$EUID" -eq 0 ]; then
  log_error "This script should not be run as root. It uses 'sudo' where needed."
  exit 1
fi

if ! command -v sudo &> /dev/null; then
    log_error "'sudo' command not found. Please install it."
    exit 1
fi

# Check sudo credentials early and refresh timestamp
log_info "Checking sudo access..."
if sudo -v; then
    log_success "Sudo access verified."
else
    log_error "Failed to obtain sudo privileges. Please run 'sudo -v' first or check your sudoers file."
    exit 1
fi

check_boot_partition # Run boot check once

# --- Detect Distro and Update ---
DISTRO_TYPE="Unknown"
UPDATE_SUCCESS=false # Default to failure

# Get initial disk info if cleaning is enabled
DISK_USED_BEFORE="0.00"
DISK_TOTAL_BEFORE="0.00"
if [ "$AUTO_CLEANUP" = true ]; then
    read -r DISK_USED_BEFORE DISK_TOTAL_BEFORE < <(get_disk_info /)
fi

# Assemble command strings including confirmation flags
PACMAN_UPGRADE_CMD="pacman -Su $PACMAN_CONFIRM_FLAG"
APT_UPGRADE_CMD="apt upgrade $APT_CONFIRM_FLAG"
DNF_UPGRADE_CMD="dnf upgrade $DNF_CONFIRM_FLAG" # Removed the stray 'Use'

# *** Use if/then structure instead of && for setting UPDATE_SUCCESS ***
if command -v pacman &> /dev/null; then
    DISTRO_TYPE="Arch"
    if update_os "pacman" \
                 "pacman -Sy" \
                 "$PACMAN_UPGRADE_CMD" \
                 "pacman -Q | wc -l" \
                 "packages" ; then
        UPDATE_SUCCESS=true
    fi

elif command -v apt &> /dev/null; then
    DISTRO_TYPE="Debian/Ubuntu"
    if update_os "apt" \
                 "apt update" \
                 "$APT_UPGRADE_CMD" \
                 "dpkg-query -f '.\n' -W | wc -l" \
                 "packages" ; then
        UPDATE_SUCCESS=true
    fi

elif command -v dnf &> /dev/null; then
    DISTRO_TYPE="Fedora"
    # *** CORRECTED 3rd argument below - removed stray word 'Use' ***
    if update_os "dnf" \
                 "" \
                 "$DNF_UPGRADE_CMD" \
                 "rpm -qa | wc -l" \
                 "packages (rpm)" ; then
        UPDATE_SUCCESS=true
    fi
else
    log_error "Unsupported distribution. No known package manager (pacman, apt, dnf) found."
    exit 1
fi

# --- Flatpak Update ---
# Only run if OS update was successful OR if no OS package manager was found but flatpak exists
if [ "$UPDATE_SUCCESS" = true ] || { [ "$DISTRO_TYPE" = "Unknown" ] && command -v flatpak &> /dev/null; }; then
    # Consider if Flatpak update failure should affect overall success? For now, it doesn't.
    update_flatpak
fi

# --- Cleanup ---
if [ "$AUTO_CLEANUP" = true ] && [ "$UPDATE_SUCCESS" = true ]; then
    log_info "=== Starting Post-Update Cleanup ==="
    DISK_USED_AFTER="0.00"
    DISK_TOTAL_AFTER="0.00"
    case "$DISTRO_TYPE" in
        "Arch")
            # Added --noconfirm flags directly here
            clean_os "pacman" \
                     "pacman -Rns \$(pacman -Qtdq) --noconfirm" \
                     "pacman -Scc --noconfirm" \
                     "/var/cache/pacman/pkg/"
            ;;
        "Debian/Ubuntu")
            # Added -y flags directly here
            clean_os "apt" \
                     "apt autoremove --purge -y" \
                     "apt clean" \
                     "/var/cache/apt/archives"
            ;;
        "Fedora")
             # Added -y flags directly here
            clean_os "dnf" \
                     "dnf autoremove -y" \
                     "dnf clean all" \
                     "/var/cache/dnf"
            ;;
    esac

    # Get final disk info and display savings
    read -r DISK_USED_AFTER DISK_TOTAL_AFTER < <(get_disk_info /)
    display_disk_saved "$DISK_USED_BEFORE" "$DISK_TOTAL_BEFORE" "$DISK_USED_AFTER" "$DISK_TOTAL_AFTER"

elif [ "$AUTO_CLEANUP" = true ] && [ "$UPDATE_SUCCESS" = false ]; then
    log_warning "Skipping cleanup because the update process failed."
else
    log_info "Skipping cleanup tasks."
fi

echo "-----------------------------"
if [ "$UPDATE_SUCCESS" = true ]; then
    log_success "${BOLD}System update process finished.${NC}"
else
     log_error "${BOLD}System update process finished with errors.${NC}"
fi
echo -e "${BOLD}${CYAN}============================${NC}"

# Set exit status based on success
if [ "$UPDATE_SUCCESS" = true ]; then
    exit 0
else
    exit 1 # Exit with error status if update failed
fi
