#!/bin/bash

# Script to update system packages (Arch, Debian, Fedora) and Flatpaks,
# with an option to clean up caches and unused packages.

# --- Configuration ---
# Set to true to enable colored output, false to disable
USE_COLORS=true
# Set to false to skip the /boot mount check
CHECK_BOOT_MOUNT=true
# Set to false to skip cleaning ~/.cache
CLEAN_USER_CACHE=true

# --- Colors and Formatting (Optional) ---
if $USE_COLORS && [[ -t 1 ]]; then # Check if connected to a terminal
  CLR_RESET='\033[0m'
  CLR_INFO='\033[1;34m'    # Blue Bold
  CLR_SUCCESS='\033[1;32m' # Green Bold
  CLR_WARNING='\033[1;33m' # Yellow Bold
  CLR_ERROR='\033[1;31m'   # Red Bold
  CLR_BOLD='\033[1m'
else
  CLR_RESET=''
  CLR_INFO=''
  CLR_SUCCESS=''
  CLR_WARNING=''
  CLR_ERROR=''
  CLR_BOLD=''
fi

# --- Helper Functions ---
info() {
  echo -e "${CLR_INFO}[INFO]${CLR_RESET} $*"
}

success() {
  echo -e "${CLR_SUCCESS}[SUCCESS]${CLR_RESET} $*"
}

warning() {
  echo -e "${CLR_WARNING}[WARNING]${CLR_RESET} $*"
}

error() {
  echo -e "${CLR_ERROR}[ERROR]${CLR_RESET} $*" >&2
}

# Check if running as root, prompt if not using sudo prefix
check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        if ! command -v sudo &>/dev/null; then
            error "sudo command not found, and script not run as root. Please install sudo or run as root."
            exit 1
        fi
        SUDO="sudo"
        info "Using sudo for privileged operations."
    else
        SUDO="" # Already root
    fi
}

# Get disk usage information for the root filesystem
# Outputs: used_gib total_gib
get_disk_info() {
  local used_k size_k used_gib total_gib
  # Use POSIX locale for consistent decimal point, get KiB values
  if ! { LC_NUMERIC=C df --output=used,size / | awk 'NR==2 {print $1, $2}'; } | read used_k size_k; then
      error "Failed to get disk usage information."
      return 1 # Indicate failure
  fi

  # Check if values are numeric
  if ! [[ "$used_k" =~ ^[0-9]+$ ]] || ! [[ "$size_k" =~ ^[0-9]+$ ]]; then
      error "Invalid disk usage values obtained: used='$used_k', size='$size_k'"
      return 1
  fi

  # Calculate GiB using awk for floating point math
  used_gib=$(awk "BEGIN {printf \"%.2f\", $used_k / 1024 / 1024}")
  total_gib=$(awk "BEGIN {printf \"%.2f\", $size_k / 1024 / 1024}")

  echo "$used_gib $total_gib"
}

# Check if /boot is mounted
check_boot_partition() {
  if ! $CHECK_BOOT_MOUNT; then
      info "Skipping /boot mount check as configured."
      return 0
  fi

  info "Checking if /boot partition is mounted..."
  if mountpoint -q /boot; then
    success "/boot is mounted."
    # No need for pause here, let the script flow
  else
    warning "/boot is NOT mounted! This might be important for kernel updates."
    # Decide if this is critical. Exiting might be too harsh for some setups.
    # read -p "Press Enter to continue despite missing /boot, or Ctrl+C to abort..."
  fi
}

# Update Flatpak packages if Flatpak is installed
update_flatpak() {
  if command -v flatpak &> /dev/null; then
    local pkg_count
    pkg_count=$(flatpak list | wc -l) # Simple count, might include header
    info "Found $pkg_count Flatpak packages. Updating..."
    if flatpak update -y; then
      success "Flatpak packages updated."
    else
      error "Flatpak update failed."
      # Decide whether to continue or exit
    fi
  else
    info "Flatpak not found, skipping Flatpak update."
  fi
}

# Perform system cleanup
# Arguments:
# 1: Package manager name (e.g., "Pacman", "APT", "DNF")
# 2: Command to remove unused packages (e.g., "pacman -Rns \$(pacman -Qtdq)")
# 3: Command to clean package cache (e.g., "pacman -Scc --noconfirm")
# 4: Path to package cache directory for size check (e.g., "/var/cache/pacman/pkg/")
perform_cleanup() {
  local pm_name="$1"
  local autoremove_cmd="$2"
  local clean_cache_cmd="$3"
  local cache_dir="$4"
  local before_used before_total after_used after_total saved_gib cache_size_before cache_size_after user_cache_size_before user_cache_size_after

  info "Starting cleanup process for $pm_name..."

  # Get initial disk usage
  if ! read before_used before_total < <(get_disk_info); then
       error "Cannot proceed with cleanup without initial disk info."
       return 1
  fi
  info "Disk usage before cleanup: ${before_used}G / ${before_total}G"

  # 1. Remove unused packages
  if [[ -n "$autoremove_cmd" ]]; then
    info "Removing unused packages..."
    # Need to handle cases where the command might fail if no packages match (e.g., pacman -Qtdq)
    eval "$SUDO $autoremove_cmd" || warning "Autoremove command encountered issues (maybe no packages to remove)."
  fi

  # 2. Clean package manager cache
  if [[ -n "$clean_cache_cmd" ]]; then
    if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
        cache_size_before=$($SUDO du -sh "$cache_dir" | awk '{print $1}')
        info "Cleaning $pm_name cache (size before: $cache_size_before)..."
    else
        info "Cleaning $pm_name cache..."
    fi
    eval "$SUDO $clean_cache_cmd"
    if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
        cache_size_after=$($SUDO du -sh "$cache_dir" | awk '{print $1}')
        info "$pm_name cache size after: $cache_size_after"
    fi
  fi

  # 3. Clean user cache (~/.cache)
  if $CLEAN_USER_CACHE && [[ -d "$HOME/.cache" ]]; then
      user_cache_size_before=$(du -sh "$HOME/.cache" | awk '{print $1}')
      info "Cleaning user cache: ~/.cache (size before: $user_cache_size_before)"
      rm -rf "$HOME/.cache"
      # Recreate the directory, as some apps expect it
      mkdir "$HOME/.cache" &>/dev/null || warning "Could not recreate ~/.cache"
      user_cache_size_after=$(du -sh "$HOME/.cache" | awk '{print $1}') # Should be small now
      info "User cache size after: $user_cache_size_after"
  elif $CLEAN_USER_CACHE; then
      info "User cache ~/.cache not found or not a directory."
  else
      info "Skipping user cache cleanup as configured."
  fi

  # Get final disk usage
  if ! read after_used after_total < <(get_disk_info); then
      error "Could not get disk info after cleanup."
      return 1
  fi
  info "Disk usage after cleanup: ${after_used}G / ${after_total}G"

  # Calculate and report saved space
  saved_gib=$(awk "BEGIN {printf \"%.2f\", $before_used - $after_used}")
  if (( $(awk 'BEGIN {print ("'$saved_gib'" > 0)}') )); then
      success "Cleaned up approximately ${saved_gib}G"
  elif (( $(awk 'BEGIN {print ("'$saved_gib'" < 0)}') )); then
      warning "Disk usage appears to have increased by ${saved_gib#-}G. This might happen due to concurrent writes."
  else
      info "No significant change in disk space detected after cleanup."
  fi
}

# --- Main Logic ---
main() {
  # Strict mode: exit on error, exit on unset variables, pipe failures count
  set -eo pipefail -u # add -u only if you are sure all variables are defined

  check_sudo # Determine if we need to prepend sudo

  local pm=""
  local pm_name=""
  local update_cmd=""
  local upgrade_cmd=""
  local autoremove_cmd=""
  local clean_cache_cmd=""
  local cache_dir=""
  local pkg_count_cmd=""
  local pkg_count=0

  # Detect Package Manager
  if command -v pacman &> /dev/null; then
    pm="pacman"
    pm_name="Pacman (Arch)"
    update_cmd="pacman -Syu --noconfirm" # Use --noconfirm cautiously or remove
    # upgrade_cmd="" # Syu does both
    # Handle potential error if no orphans: Add || true
    autoremove_cmd='sh -c '\''orphans=$(pacman -Qtdq); if [ -n "$orphans" ]; then pacman -Rns --noconfirm $orphans; else echo "No orphans found."; fi'\'' || true'
    clean_cache_cmd="pacman -Scc --noconfirm"
    cache_dir="/var/cache/pacman/pkg/"
    pkg_count_cmd="pacman -Q | wc -l"
    CHECK_BOOT_MOUNT=true # Generally more important for Arch rolling release kernel updates

  elif command -v apt &> /dev/null; then
    pm="apt"
    pm_name="APT (Debian/Ubuntu)"
    update_cmd="apt update"
    upgrade_cmd="apt upgrade -y"
    autoremove_cmd="apt autoremove --purge -y"
    clean_cache_cmd="apt clean" # apt autoclean removes only old packages
    cache_dir="/var/cache/apt/archives/"
    pkg_count_cmd="dpkg-query -f '.\n' -W | wc -l" # More accurate than dpkg --list
    CHECK_BOOT_MOUNT=false # Standard apt upgrade usually doesn't touch kernel unless using dist-upgrade

  elif command -v dnf &> /dev/null; then
    pm="dnf"
    pm_name="DNF (Fedora)"
    update_cmd="dnf check-update" # Check first is optional but good practice
    upgrade_cmd="dnf upgrade -y"
    autoremove_cmd="dnf autoremove -y"
    clean_cache_cmd="dnf clean all"
    cache_dir="/var/cache/dnf/"
    pkg_count_cmd="dnf list installed | wc -l"
    CHECK_BOOT_MOUNT=true # Kernel updates common

  else
    error "Unsupported package manager. Could not find pacman, apt, or dnf."
    exit 1
  fi

  info "Detected package manager: ${CLR_BOLD}$pm_name${CLR_RESET}"
  eval "pkg_count=$($pkg_count_cmd)" # Run the command to get count
  info "Found $pkg_count native packages."

  # --- Update Phase ---
  info "Starting system update..."
  check_boot_partition # Check /boot mount status if configured/needed

  info "Running package list update..."
  if $SUDO $update_cmd; then
      success "$pm_name package lists updated."
  else
      error "$pm_name package list update failed."
      exit 1 # Critical step
  fi

  if [[ -n "$upgrade_cmd" ]]; then
    info "Running system upgrade..."
    if $SUDO $upgrade_cmd; then
      success "$pm_name system upgrade completed."
    else
      error "$pm_name system upgrade failed."
      # Decide whether to exit or continue with flatpak/cleanup
      # exit 1
    fi
  fi

  update_flatpak # Update flatpaks if present

  # --- Cleanup Phase ---
  read -p "$(echo -e ${CLR_BOLD}"Perform cleanup (remove unused packages and caches)? [y/N]: "${CLR_RESET})" -n 1 -r REPLY
  echo # Move to a new line

  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    perform_cleanup "$pm_name" "$autoremove_cmd" "$clean_cache_cmd" "$cache_dir"
  else
    info "Skipping cleanup phase."
  fi

  success "Script finished."
  # Optional: remove the final 'press enter to exit'
  # read -p "Press Enter to exit..."
}

# --- Run Script ---
main "$@" # Pass command line arguments if needed in the future
