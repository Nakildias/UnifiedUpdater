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
# Check if connected to a terminal and USE_COLORS is true
if $USE_COLORS && [[ -t 1 ]]; then
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
    # Use global scope for SUDO or pass it back if preferred
    declare -g SUDO # Ensure SUDO is globally accessible from this function

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
        cache_size_before=$($SUDO du -sh "$cache_dir" 2>/dev/null | awk '{print $1}')
        info "Cleaning $pm_name cache (size before: ${cache_size_before:-unknown})..."
    else
        info "Cleaning $pm_name cache..."
    fi
    eval "$SUDO $clean_cache_cmd"
    if [[ -n "$cache_dir" && -d "$cache_dir" ]]; then
        cache_size_after=$($SUDO du -sh "$cache_dir" 2>/dev/null | awk '{print $1}')
        info "$pm_name cache size after: ${cache_size_after:-unknown}"
    fi
  fi

  # 3. Clean user cache (~/.cache)
  # Ensure HOME is set correctly, especially if run via sudo
  local user_home="${HOME:-$(getent passwd $SUDO_USER | cut -d: -f6)}"
  local user_cache_dir="${user_home}/.cache"

  if $CLEAN_USER_CACHE && [[ -n "$user_home" && -d "$user_cache_dir" ]]; then
      user_cache_size_before=$(du -sh "$user_cache_dir" | awk '{print $1}')
      info "Cleaning user cache: ${user_cache_dir} (size before: $user_cache_size_before)"
      rm -rf "$user_cache_dir"
      # Recreate the directory, as some apps expect it
      # Ensure correct ownership if running as root but cleaning user cache
      if [[ $EUID -eq 0 && -n "$SUDO_USER" ]]; then
          mkdir "$user_cache_dir" &>/dev/null && chown "$SUDO_USER:$SUDO_USER" "$user_cache_dir" || warning "Could not recreate or chown ${user_cache_dir}"
      else
          mkdir "$user_cache_dir" &>/dev/null || warning "Could not recreate ${user_cache_dir}"
      fi
      user_cache_size_after=$(du -sh "$user_cache_dir" | awk '{print $1}') # Should be small now
      info "User cache size after: $user_cache_size_after"
  elif $CLEAN_USER_CACHE; then
      info "User cache ${user_cache_dir} not found or not a directory."
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
  # Removed -u because SUDO_USER might be unset if run directly as root
  set -eo pipefail

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
  local pm_path="" # Store full path to package manager

  # Detect Package Manager
  if command -v pacman &> /dev/null; then
    pm="pacman"
    pm_name="Pacman (Arch)"
    pm_path=$(command -v pacman)
    update_cmd="$pm_path -Syu --noconfirm" # Use --noconfirm cautiously or remove
    # upgrade_cmd="" # Syu does both
    # Handle potential error if no orphans: Add || true
    autoremove_cmd='sh -c '\''orphans=$('"$pm_path"' -Qtdq); if [ -n "$orphans" ]; then '"$pm_path"' -Rns --noconfirm $orphans; else echo "No orphans found."; fi'\'' || true'
    clean_cache_cmd="$pm_path -Scc --noconfirm"
    cache_dir="/var/cache/pacman/pkg/"
    pkg_count_cmd="$pm_path -Q | wc -l"
    CHECK_BOOT_MOUNT=true # Generally more important for Arch rolling release kernel updates

  elif command -v apt &> /dev/null; then
    pm="apt"
    pm_name="APT (Debian/Ubuntu)"
    pm_path=$(command -v apt)
    update_cmd="$pm_path update"
    upgrade_cmd="$pm_path upgrade -y"
    autoremove_cmd="$pm_path autoremove --purge -y"
    clean_cache_cmd="$pm_path clean" # apt autoclean removes only old packages
    cache_dir="/var/cache/apt/archives/"
    pkg_count_cmd="dpkg-query -f '.\n' -W | wc -l" # More accurate than dpkg --list
    CHECK_BOOT_MOUNT=false # Standard apt upgrade usually doesn't touch kernel unless using dist-upgrade

  elif command -v dnf &> /dev/null; then
    pm="dnf"
    pm_name="DNF (Fedora)"
    pm_path=$(command -v dnf)
    update_cmd="$pm_path check-update" # Check first is optional but good practice
    upgrade_cmd="$pm_path upgrade -y"
    autoremove_cmd="$pm_path autoremove -y"
    clean_cache_cmd="$pm_path clean all"
    cache_dir="/var/cache/dnf/"
    # *** MODIFICATION: Use rpm -qa for package count on Fedora ***
    pkg_count_cmd="rpm -qa | wc -l"
    CHECK_BOOT_MOUNT=true # Kernel updates common

  else
    error "Unsupported package manager. Could not find pacman, apt, or dnf."
    exit 1
  fi

  info "Detected package manager: ${CLR_BOLD}$pm_name${CLR_RESET} (Path: $pm_path)"
  # Use eval carefully, ensure pkg_count_cmd is safe
  if [[ -n "$pkg_count_cmd" ]]; then
      eval "pkg_count=$($pkg_count_cmd)" # Run the command to get count
      info "Found $pkg_count native packages."
  else
      info "Could not determine package count command."
  fi


  # --- Update Phase ---
  info "Starting system update..."
  check_boot_partition # Check /boot mount status if configured/needed


  # *** Debugging block kept, but verbosity logic simplified ***
  info "--- Debug: Checking Environment Before Update ---"
  echo "Running as user: $(whoami)"
  echo "Effective user ID: $EUID"
  echo "SUDO variable: '$SUDO'"
  echo "SUDO_USER variable: '${SUDO_USER:-<not set>}'" # Show who invoked sudo
  echo "update_cmd: '$update_cmd'"
  echo "PATH: $PATH"
  echo "HOME: $HOME"
  echo "TERM: ${TERM:-<not set>}"
  echo "HTTP_PROXY: ${HTTP_PROXY:-<not set>}"
  echo "HTTPS_PROXY: ${HTTPS_PROXY:-<not set>}"
  echo "NO_PROXY: ${NO_PROXY:-<not set>}"
  echo "LANG: ${LANG:-<not set>}"
  echo "LC_ALL: ${LC_ALL:-<not set>}"
  info "--- End Debug ---"

  info "Running package list update..."
  # Create temporary files to capture output
  STDOUT_FILE=$(mktemp)
  STDERR_FILE=$(mktemp)

  # *** MODIFICATION: Removed automatic addition of -v for dnf/apt ***
  # Just use the base update command defined earlier
  verbose_update_cmd="$update_cmd"

  # Run the command, redirecting stdout and stderr
  set +e # Temporarily disable exit on error to capture exit code
  $SUDO $verbose_update_cmd > "$STDOUT_FILE" 2> "$STDERR_FILE"
  CMD_EXIT_CODE=$? # Capture the exit code
  set -e # Re-enable exit on error

  echo -e "${CLR_BOLD}--- Update Command stdout ---${CLR_RESET}"
  cat "$STDOUT_FILE"
  echo -e "${CLR_BOLD}--- Update Command stderr ---${CLR_RESET}"
  cat "$STDERR_FILE"
  echo -e "${CLR_BOLD}--- Update Command exit code: $CMD_EXIT_CODE ---${CLR_RESET}"
  rm "$STDOUT_FILE" "$STDERR_FILE" # Clean up temp files

  if [ $CMD_EXIT_CODE -eq 0 ]; then
      success "$pm_name package lists updated."
  else
      # Check for specific DNF exit codes if needed
      # 100 = no updates available (success for check-update)
      # 1 = general error
      # 0 = success (already handled)
      if [[ "$pm" == "dnf" && "$update_cmd" == *check-update && $CMD_EXIT_CODE -eq 100 ]]; then
           success "$pm_name package list check complete. No updates found."
      else
           error "$pm_name package list update failed (Exit code: $CMD_EXIT_CODE)."
           # Optionally add more specific error handling based on CMD_EXIT_CODE here
           # For now, any non-zero and non-100 code is treated as failure.
           exit 1 # Critical step
       fi
  fi
  # *** End of MODIFIED package list update block ***


  if [[ -n "$upgrade_cmd" ]]; then
    info "Running system upgrade..."
    # Add similar detailed logging here if upgrade fails
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
  # Use prompt with current user context in mind
  prompt_user="${SUDO_USER:-$(whoami)}"
  read -p "$(echo -e ${CLR_BOLD}"${prompt_user}, perform cleanup (remove unused packages and caches)? [y/N]: "${CLR_RESET})" -n 1 -r REPLY
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
