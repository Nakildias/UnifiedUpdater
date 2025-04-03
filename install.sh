#!/usr/bin/bash

# === Configuration ===
UPDATER_SOURCE_NAME="UnifiedUpdater"
INSTALL_DIR="/usr/local/bin"
INSTALL_NAME="UnifiedUpdater"
ALIASES=("UniUpdater" "uniupdater" "unifiedupdater")
RC_FILES=("$HOME/.bashrc" "$HOME/.zshrc") # Add other shell rc files if needed

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

# === Check Prerequisites ===
check_prerequisites() {
    log_step "Checking Prerequisites"

    # 1. Check if running as root (should use sudo instead)
    if [ "$EUID" -eq 0 ]; then
      log_error "Please do not run this script as root. Use 'sudo' when prompted."
      exit 1
    fi

    # 2. Check for sudo command
    if ! command -v sudo &> /dev/null; then
        log_error "'sudo' command not found. Cannot elevate privileges for installation."
        exit 1
    fi
    log_success "'sudo' command found."

    # 3. Check if source file exists
    if [ ! -f "$UPDATER_SOURCE_NAME" ]; then
        log_error "Updater script '$UPDATER_SOURCE_NAME' not found in the current directory."
        log_error "Please ensure this installer is in the same directory as '$UPDATER_SOURCE_NAME'."
        exit 1
    fi
    log_success "Updater script '$UPDATER_SOURCE_NAME' found."

    # 4. Check system compatibility (Step 0)
    log_info "Checking system compatibility (dnf, apt, or pacman)..."
    local compatible=false
    if command -v dnf &> /dev/null; then
        log_success "Compatible package manager found: dnf"
        compatible=true
    elif command -v apt &> /dev/null; then
        log_success "Compatible package manager found: apt"
        compatible=true
    elif command -v pacman &> /dev/null; then
        log_success "Compatible package manager found: pacman"
        compatible=true
    fi

    if [ "$compatible" = false ]; then
        log_error "No compatible package manager (dnf, apt, pacman) found."
        log_error "This system may not be supported by $INSTALL_NAME."
        exit 1
    fi
}

# === Installation ===
install_script() {
    log_step "Installing $INSTALL_NAME"

    local target_path="$INSTALL_DIR/$INSTALL_NAME"

    log_info "Attempting to install '$UPDATER_SOURCE_NAME' to '$target_path'..."
    log_info "This requires root privileges."

    # Create target directory if it doesn't exist (requires sudo)
    if [ ! -d "$INSTALL_DIR" ]; then
        log_warning "Directory '$INSTALL_DIR' does not exist. Attempting to create..."
        if sudo mkdir -p "$INSTALL_DIR"; then
            log_success "Directory '$INSTALL_DIR' created."
        else
            log_error "Failed to create directory '$INSTALL_DIR'. Check permissions."
            return 1
        fi
    fi

    # Copy the file (requires sudo)
    if sudo cp "$UPDATER_SOURCE_NAME" "$target_path"; then
        log_success "Script copied to '$target_path'."
    else
        log_error "Failed to copy script to '$target_path'. Check permissions."
        return 1
    fi

    # Make executable (requires sudo)
    if sudo chmod +x "$target_path"; then
        log_success "Script set as executable."
    else
        log_error "Failed to set executable permissions on '$target_path'."
        # Attempt cleanup? Maybe not necessary, user can fix permissions.
        return 1
    fi

    log_success "$INSTALL_NAME installed successfully to $target_path"
    return 0
}

# === Alias Setup ===
setup_aliases() {
    log_step "Setting up Aliases"
    local target_command="$INSTALL_DIR/$INSTALL_NAME"
    local alias_added_count=0

    for rc_file in "${RC_FILES[@]}"; do
        if [ -f "$rc_file" ]; then
            log_info "Checking aliases in $rc_file..."
            local file_changed=false
            for alias_name in "${ALIASES[@]}"; do
                local alias_line="alias $alias_name='$target_command'"
                # Use grep -Fx to match the exact whole line
                if ! grep -Fxq "$alias_line" "$rc_file"; then
                    log_info "Adding alias '$alias_name' to $rc_file."
                    # Add a comment indicating where the alias came from
                    echo "" >> "$rc_file" # Add a blank line before
                    echo "# Alias for $INSTALL_NAME (added by installer)" >> "$rc_file"
                    echo "$alias_line" >> "$rc_file"
                    file_changed=true
                    ((alias_added_count++))
                else
                    log_info "Alias '$alias_name' already exists in $rc_file."
                fi
            done
            if [ "$file_changed" = true ]; then
                 log_success "Aliases updated in $rc_file."
            fi
        else
            log_info "Shell configuration file '$rc_file' not found. Skipping aliases for it."
        fi
    done

    if [ "$alias_added_count" -gt 0 ]; then
        log_warning "Aliases added/updated. Please reload your shell configuration for changes to take effect."
        log_warning "Run 'source ~/.bashrc', 'source ~/.zshrc', or open a new terminal."
    else
        log_info "No new aliases were added."
    fi
}

# === Main Execution ===
echo -e "${BOLD}${CYAN}=== $INSTALL_NAME Installer ===${NC}"

check_prerequisites || exit 1 # Exit if prerequisites fail

# Confirmation Prompt
read -p "$(echo -e ${YELLOW}"\n>>> Proceed with installation to '$INSTALL_DIR' and alias setup? (y/N): "${NC})" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Installation cancelled by user."
    exit 0
fi

install_script || exit 1 # Exit if installation fails
setup_aliases

echo -e "\n${BOLD}${GREEN}=== Installation Complete ===${NC}"
log_info "You can now run the updater using '$INSTALL_NAME' or one of its aliases: ${ALIASES[*]}"
log_info "Remember to reload your shell or open a new terminal if aliases were added."
echo -e "${BOLD}${CYAN}=============================${NC}"

exit 0
