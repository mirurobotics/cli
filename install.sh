#!/bin/sh
set -e

# =============================================================================
# Configuration
# =============================================================================

BINARY_NAME="miru"
GITHUB_REPO="mirurobotics/cli"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
SUDO="${SUDO:-}"
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-2}"

# =============================================================================
# Output helpers
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

QUIET=false

log()   { [ "$QUIET" = true ] || printf "${GREEN}==>${NC} %s\n" "$1"; }
warn()  { [ "$QUIET" = true ] || printf "${YELLOW}Warning:${NC} %s\n" "$1"; }
error() { printf "${RED}Error:${NC} %s\n" "$1" >&2; exit 1; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# =============================================================================
# Network helpers
# =============================================================================

# Retry a command up to MAX_RETRIES times
retry() {
    attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        if "$@"; then
            return 0
        fi
        if [ $attempt -lt $MAX_RETRIES ]; then
            log "Retry $attempt/$MAX_RETRIES failed, waiting ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# Download with retry
download() {
    url="$1"
    output="$2"
    if [ "$QUIET" = true ]; then
        retry curl -fsSL "$url" -o "$output" 2>/dev/null
    else
        retry curl -fSL "$url" -o "$output" 2>/dev/null
    fi
}

# =============================================================================
# Setup
# =============================================================================

check_dependencies() {
    for cmd in curl tar grep cut; do
        cmd_exists "$cmd" || error "$cmd is required but not installed"
    done
}

detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$OS" in
        darwin) OS="Darwin" ;;
        linux)  OS="Linux" ;;
        *)      error "Unsupported operating system: $OS (supported: Linux, macOS)" ;;
    esac

    case "$ARCH" in
        x86_64|amd64)   ARCH="x86_64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        armv7l)         ARCH="armv7" ;;
        *)              error "Unsupported architecture: $ARCH (supported: x86_64, arm64, armv7)" ;;
    esac

    # Apple Silicon uses /opt/homebrew/bin by default
    if [ "$OS" = "Darwin" ] && [ "$ARCH" = "arm64" ] && [ "$INSTALL_DIR" = "/usr/local/bin" ]; then
        [ -d "/opt/homebrew/bin" ] && INSTALL_DIR="/opt/homebrew/bin"
    fi
}

resolve_version() {
    if [ -n "$VERSION" ]; then
        # Ensure version has v prefix
        case "$VERSION" in
            v*) ;;
            *)  VERSION="v$VERSION" ;;
        esac
        log "Using version: $VERSION"
    else
        log "Fetching latest version..."
        API_RESPONSE=$(retry curl -sL "$API_URL") || error "Failed to reach GitHub API: $API_URL"
        VERSION=$(echo "$API_RESPONSE" | grep "tag_name" | cut -d '"' -f 4)
        [ -z "$VERSION" ] && error "Could not parse version from GitHub API response"
        log "Latest version: $VERSION"
    fi
}

check_existing_install() {
    binary_path="$INSTALL_DIR/$BINARY_NAME"
    if [ -x "$binary_path" ]; then
        installed_version=$("$binary_path" --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1) || true
        if [ "$installed_version" = "$VERSION" ]; then
            log "$BINARY_NAME $VERSION is already installed"
            exit 0
        elif [ -n "$installed_version" ]; then
            log "Upgrading $BINARY_NAME from $installed_version to $VERSION"
        fi
    fi
}

verify_checksum() {
    file="$1"
    expected="$2"
    actual=""

    if cmd_exists shasum; then
        actual=$(shasum -a 256 "$file" | cut -d ' ' -f 1)
    elif cmd_exists sha256sum; then
        actual=$(sha256sum "$file" | cut -d ' ' -f 1)
    else
        error "No checksum tool available (need shasum or sha256sum)"
    fi

    if [ "$actual" != "$expected" ]; then
        error "Checksum mismatch for $file
  Expected: $expected
  Actual:   $actual"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    # Parse arguments
    VERSION=""
    for arg in "$@"; do
        case "$arg" in
            --version=*) VERSION="${arg#*=}" ;;
            --quiet|-q)  QUIET=true ;;
        esac
    done

    check_dependencies
    detect_platform
    resolve_version
    check_existing_install

    # Setup sudo if needed
    if [ ! -w "$INSTALL_DIR" ]; then
        cmd_exists sudo || error "Cannot write to $INSTALL_DIR and sudo is unavailable"
        SUDO="sudo"
    fi

    # Build URLs
    version_num=$(echo "$VERSION" | sed 's/^v//')
    tarball_url="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/cli_${OS}_${ARCH}.tar.gz"
    checksum_url="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/cli_${version_num}_checksums.txt"

    # Create temp directory
    tmp_dir=$(mktemp -d) || error "Failed to create temporary directory"
    trap 'rm -rf "$tmp_dir"' EXIT

    # Download
    log "Downloading $BINARY_NAME $VERSION..."
    download "$tarball_url" "$tmp_dir/$BINARY_NAME.tar.gz" \
        || error "Failed to download: $tarball_url"

    # Verify
    log "Verifying checksum..."
    download "$checksum_url" "$tmp_dir/checksums.txt" \
        || error "Failed to download checksums: $checksum_url"
    expected=$(grep "cli_${OS}_${ARCH}.tar.gz" "$tmp_dir/checksums.txt" | cut -d ' ' -f 1)
    [ -z "$expected" ] && error "Checksum not found for cli_${OS}_${ARCH}.tar.gz in checksums file"
    verify_checksum "$tmp_dir/$BINARY_NAME.tar.gz" "$expected"

    # Extract and install
    log "Installing..."
    tar -xzf "$tmp_dir/$BINARY_NAME.tar.gz" -C "$tmp_dir" \
        || error "Failed to extract archive (file may be corrupted)"
    $SUDO mv "$tmp_dir/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME" \
        || error "Failed to install binary to $INSTALL_DIR/$BINARY_NAME"
    $SUDO chmod +x "$INSTALL_DIR/$BINARY_NAME"

    # Done
    log "$BINARY_NAME $VERSION successfully installed to $INSTALL_DIR/$BINARY_NAME"
    [ "$QUIET" = true ] || echo "$PATH" | grep -q "$INSTALL_DIR" || warn "$INSTALL_DIR is not in your PATH"
}

main "$@"
