#!/usr/bin/bash

# === Configuration ===
INSTALL_DIR="/usr/local/bin"
INSTALL_NAME="UnifiedUpdater"
TARGET_PATH="$INSTALL_DIR/$INSTALL_NAME"
ALIASES=("UniUpdater" "uniupdater" "unifiedupdater")
RC_FILES=("$HOME/.bashrc" "$HOME/.zshrc") # Match files checked during installation

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

log_step() {
    echo -e "\n${BOLD}${CYAN}>>> Step: $1${NC}"
}

# === Prerequisite Check ===
check_prerequisites() {
    log_step "Checking Prerequisites"
    # 1. Check if running as root (should use sudo instead)
    if [ "$EUID" -eq 0 ]; then
      log_error "Please do not run this script as root. Use 'sudo' when prompted."
      exit 1
    fi

    # 2. Check for sudo command
    if ! command -v sudo &> /dev/null; then
        log_error "'sudo' command not found. Cannot elevate privileges for removal."
        exit 1
    fi
    log_success "'sudo' command found."
}

# === Remove Binary ===
remove_binary() {
    log_step "Removing $INSTALL_NAME Binary"

    if [ ! -f "$TARGET_PATH" ]; then
        log_warning "File '$TARGET_PATH' not found. Already uninstalled or not installed there?"
        return 0 # Not an error if already gone
    fi

    log_info "Attempting to remove '$TARGET_PATH'..."
    log_info "This requires root privileges."

    if sudo rm "$TARGET_PATH"; then
        log_success "Successfully removed '$TARGET_PATH'."
        return 0
    else
        log_error "Failed to remove '$TARGET_PATH'. Check permissions or if the file is in use."
        return 1
    fi
}

# === Remove Aliases ===
remove_aliases() {
    log_step "Removing Aliases"
    local alias_removed_count=0
    # Use # as sed delimiter because TARGET_PATH contains /
    local escaped_target_path
    escaped_target_path=$(printf '%s\n' "$TARGET_PATH" | sed 's/[\/&]/\\&/g') # Escape / and & for sed regex


    for rc_file in "${RC_FILES[@]}"; do
        if [ -f "$rc_file" ]; then
            log_info "Checking for aliases in '$rc_file'..."
            local file_changed=false
            local original_checksum
            original_checksum=$(md5sum "$rc_file" 2>/dev/null || cksum "$rc_file") # Get checksum before edit

            for alias_name in "${ALIASES[@]}"; do
                 # Pattern to match the alias line exactly
                 # Needs careful escaping for sed. Match start, 'alias', space, name, '=', quote, path, quote, end.
                local alias_pattern="^alias ${alias_name}='${escaped_target_path}'$"

                # Check if alias exists before attempting removal
                if grep -qE "$alias_pattern" "$rc_file"; then
                    log_info "Removing alias '$alias_name' from '$rc_file'..."
                    # Use sed to delete the line matching the pattern.
                    # Using # as delimiter. Need -i for in-place edit. Add '.bak' for backup on macOS/BSD sed.
                    # Assuming GNU sed here (common on Linux targeted by original script).
                    if sed -i "\#${alias_pattern}#d" "$rc_file"; then
                       log_success " -> Removed alias line for '$alias_name'."
                       file_changed=true
                       ((alias_removed_count++))

                       # Optional: Attempt to remove the comment line added by the installer *if* it's immediately above
                       # This is slightly risky if the file structure changed.
                       # Example using sed to remove comment if previous line matches:
                       # sed -i "/^# Alias for ${INSTALL_NAME//\ /\\ } (added by installer)$/{N;s/\\n.*//;}" "$rc_file"
                       # For simplicity, we'll just remove the alias line itself. The comment is harmless.
                    else
                        log_warning " -> Failed to execute sed command for '$alias_name' in '$rc_file'."
                    fi
                else
                     log_info "Alias '$alias_name' not found in '$rc_file'."
                fi
            done

            # Check if file actually changed after potential sed operations
            local final_checksum
            final_checksum=$(md5sum "$rc_file" 2>/dev/null || cksum "$rc_file")
            if [ "$file_changed" = true ] && [ "$original_checksum" != "$final_checksum" ]; then
                 log_success "Finished checking/modifying '$rc_file'."
            elif [ "$file_changed" = true ]; then
                 log_warning "Sed reported changes, but file content seems unchanged in '$rc_file'."
            fi
        else
            log_info "Shell configuration file '$rc_file' not found. Skipping alias removal for it."
        fi
    done

    if [ "$alias_removed_count" -gt 0 ]; then
        log_warning "Aliases removed. Please reload your shell configuration for changes to take effect."
        log_warning "Run 'source ~/.bashrc', 'source ~/.zshrc', or open a new terminal."
    else
        log_info "No aliases specific to this installation were found or removed."
    fi
}

# === Main Execution ===
echo -e "${BOLD}${CYAN}=== $INSTALL_NAME Uninstaller ===${NC}"

check_prerequisites || exit 1

# Confirmation Prompt
read -p "$(echo -e ${YELLOW}"\n>>> WARNING: This will remove '$TARGET_PATH' and associated aliases."$NC \
           "\n${YELLOW}>>> Are you sure you want to uninstall? (y/N): "${NC})" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Uninstallation cancelled by user."
    exit 0
fi

# Perform Uninstall Steps
remove_binary || log_warning "Proceeding despite issues removing binary file." # Decide if failure should stop alias removal
remove_aliases

echo -e "\n${BOLD}${GREEN}=== Uninstallation Complete ===${NC}"
log_info "If the binary file and any aliases were found, they have been removed."
log_info "Remember to reload your shell or open a new terminal."
echo -e "${BOLD}${CYAN}===============================${NC}"

exit 0
