#!/bin/sh
set -e
# DISPLAY #
# ======= #
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NO_COLOR='\033[0m'
debug() { echo "${BLUE}==>${NO_COLOR} $1"; }
log() { echo "${GREEN}==>${NO_COLOR} $1"; }
warn() { echo "${YELLOW}Warning:${NO_COLOR} $1"; }
error() { echo "${RED}Error:${NO_COLOR} $1"; }
fatal() { echo "${RED}Error:${NO_COLOR} $1"; exit 1; }
# ARGUMENTS #
# ========= #
DEBUG=false
for arg in "$@"; do
    case $arg in
    --debug=*) DEBUG="${arg#*=}";;
    --debug) DEBUG=true;;
    esac
done
PRERELEASE=false
for arg in "$@"; do
    case $arg in
    --prerelease=*) PRERELEASE="${arg#*=}";;
    --prerelease) PRERELEASE=true;;
    esac
done
if [ "$DEBUG" = true ]; then
    debug "prerelease: '$PRERELEASE' (should be true or false)"
fi
# Configuration
BINARY_NAME="miru"
GITHUB_REPO="miruml/cli"
INSTALL_DIR="/usr/local/bin"
SUDO=""
# Check if command exists
cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}
# Verify SHA256 checksum
verify_checksum() {
    file=$1
    expected_checksum=$2
    if [ -z "$expected_checksum" ]; then
        fatal "Expected checksum is required but not provided"
    fi
    if [ -z "$file" ]; then
        fatal "File is required but not provided"
    fi
    if cmd_exists shasum; then
        printf "%s  %s\n" "$expected_checksum" "$file" | shasum -a 256 -c >/dev/null 2>&1 || {
            fatal "Checksum verification failed using shasum"
        }
    elif cmd_exists sha256sum; then
        printf "%s  %s\n" "$expected_checksum" "$file" | sha256sum -c >/dev/null 2>&1 || {
            fatal "Checksum verification failed using sha256sum"
        }
    else
        fatal "Could not verify checksum: no sha256sum or shasum command found"
    fi
}
# Check for required commands
for cmd in curl tar grep cut; do
    cmd_exists "$cmd" || error "$cmd is required but not installed."
done
# Determine if sudo is needed
if [ ! -w "$INSTALL_DIR" ]; then
    if cmd_exists sudo; then
        SUDO="sudo"
    else
        error "Installation directory is not writable and sudo is not available"
    fi
fi
# Add macOS helper functions here (before OS detection)
is_macos() {
    [ "$(uname -s)" = "Darwin" ]
}
# Determine OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
# Add macOS-specific checks right after OS detection
if is_macos; then
    # Check minimum macOS version
    MACOS_VERSION=$(sw_vers -productVersion)
    if [ "$(echo "$MACOS_VERSION" | cut -d. -f1)" -lt 11 ] && \
       [ "$(echo "$MACOS_VERSION" | cut -d. -f2)" -lt 15 ]; then
        error "macOS version $MACOS_VERSION is not supported. Please upgrade to macOS 10.15 or newer."
    fi
    # Handle Apple Silicon architecture naming
    if [ "$ARCH" = "arm64" ]; then
        log "Detected Apple Silicon Mac"
    fi
    # Use more reliable macOS-specific paths
    if [ "$INSTALL_DIR" = "/usr/local/bin" ]; then
        if [ -d "/opt/homebrew/bin" ] && [ "$ARCH" = "arm64" ]; then
            INSTALL_DIR="/opt/homebrew/bin"
            log "Using Apple Silicon default path: $INSTALL_DIR"
        fi
    fi
fi
# Get latest version
if [ "$PRERELEASE" = "true" ]; then
    log "Fetching latest pre-release version..."
    VERSION=$(curl -sL "https://api.github.com/repos/${GITHUB_REPO}/releases" |
        jq -r '.[] | select(.prerelease==true) | .tag_name' | head -n 1) || error "Failed to fetch latest pre-release version"
else
    log "Fetching latest stable version..."
    VERSION=$(curl -sL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" |
        grep "tag_name" | cut -d '"' -f 4) || error "Failed to fetch latest version"
fi
[ -z "$VERSION" ] && error "Could not determine latest version"
log "Latest version: ${VERSION}"
# Convert architecture names
case $ARCH in
    x86_64|amd64) ARCH="x86_64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l) ARCH="armv7" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac
# Set download URL based on OS
case $OS in
    darwin) OS="Darwin" ;;
    linux) OS="Linux" ;;
    *) error "Unsupported operating system: $OS" ;;
esac
VERSION_WO_V=$(echo "$VERSION" | cut -d 'v' -f 2)
URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/cli_${OS}_${ARCH}.tar.gz"
CHECKSUM_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/cli_${VERSION_WO_V}_checksums.txt"
# Create temporary directory
TMP_DIR=$(mktemp -d) || error "Failed to create temporary directory"
trap 'rm -rf "$TMP_DIR"' EXIT
# Add as helper function
download_with_progress() {
    url="$1"
    output="$2"
    curl -#fL "$url" -o "$output"
}
# Download files
log "Downloading ${BINARY_NAME} CLI ${VERSION}..."
download_with_progress "$URL" "$TMP_DIR/${BINARY_NAME}.tar.gz" ||
    error "Failed to download ${BINARY_NAME}"
log "Verifying checksum..."
curl -fsSL "$CHECKSUM_URL" -o "$TMP_DIR/checksums.txt" 2>/dev/null
EXPECTED_CHECKSUM=$(grep "cli_${OS}_${ARCH}.tar.gz" "$TMP_DIR/checksums.txt" | cut -d ' ' -f 1)
verify_checksum "$TMP_DIR/${BINARY_NAME}.tar.gz" "$EXPECTED_CHECKSUM" ||
    fatal "Checksum verification failed"
# Extract archive
log "Extracting..."
tar -xzf "$TMP_DIR/${BINARY_NAME}.tar.gz" -C "$TMP_DIR" ||
    error "Failed to extract archive"
# Install binary
log "Installing ${BINARY_NAME} CLI..."
$SUDO mv "$TMP_DIR/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}" ||
    error "Failed to install binary"
$SUDO chmod +x "${INSTALL_DIR}/${BINARY_NAME}" ||
    error "Failed to set executable permissions"
# Verify installation
if cmd_exists ${BINARY_NAME}; then
    log "${BINARY_NAME} CLI ${VERSION} installed successfully to ${INSTALL_DIR}/${BINARY_NAME}"
else
    error "Installation completed, but ${BINARY_NAME} command not found. Please check your PATH"
fi
# Print PATH warning if necessary
echo "$PATH" | grep -q "${INSTALL_DIR}" ||
    warn "${INSTALL_DIR} is not in your PATH. You may need to add it to use ${BINARY_NAME}"
# After binary installation, add macOS-specific post-install steps
if is_macos; then
    for shell_rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [ -f "$shell_rc" ]; then
            if ! grep -q "$INSTALL_DIR" "$shell_rc"; then
                warn "You may want to add the following line to $shell_rc:"
                warn "export PATH=\"$INSTALL_DIR:\$PATH\""
            fi
        fi
    done
fi