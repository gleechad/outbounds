#!/usr/bin/env bash
# upgrade_cloudflared.sh
# Checks GitHub releases for cloudflare/cloudflared
# Optional CHECK_TYPE: release | prerelease | both

# shellcheck disable=SC1091
source "$SCRIPT_DIR/config/common.sh"


set -euo pipefail
IFS=$'\n\t'

REPO="cloudflare/cloudflared"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        DELIVERABLE="cloudflared-linux-amd64.deb"
        ;;
    aarch64|arm64)
        DELIVERABLE="cloudflared-linux-arm64.deb"
        ;;
    *)
        error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

TMP_DEB="/tmp/cloudflared.deb"
LOG="${LOG_DIR}/upgrade_cf.log"
API="https://api.github.com/repos/${REPO}"

# ==========================================
# CONFIGURABLE OPTION
# release | prerelease | both
CHECK_TYPE="release"
# ==========================================

# log() {
#     mkdir -p "$(dirname "$LOG")"
#     printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$LOG"
# }

get_latest_release() {
    curl -sSf "${API}/releases/latest" | jq -r '.tag_name // empty'
}

get_latest_prerelease() {
    curl -sSf "${API}/releases" | jq -r '.[] | select(.prerelease==true) | .tag_name' | head -n1 || true
}

norm() {
    echo "$1" | sed 's/^v//'
}

get_local_version() {
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared --version 2>/dev/null \
            | awk '{ for (i=1;i<=NF;i++) if ($i ~ /^[0-9]/) { print $i; exit } }'
    else
        echo ""
    fi
}

ver_gt() {
    dpkg --compare-versions "$(norm "$1")" gt "$(norm "$2")"
}

main() {
    info "=== Starting cloudflared upgrade check ==="
    info "CHECK_TYPE = ${CHECK_TYPE}"

    release_tag=""
    prerelease_tag=""

    # Retrieve tags depending on CHECK_TYPE
    case "$CHECK_TYPE" in
        release)
            release_tag="$(norm "$(get_latest_release || true)")"
            info "Latest release tag: ${release_tag:-<none>}"
            VERSION="$release_tag"
            ;;
        prerelease)
            prerelease_tag="$(norm "$(get_latest_prerelease || true)")"
            info "Latest prerelease tag: ${prerelease_tag:-<none>}"
            VERSION="$prerelease_tag"
            ;;
        both)
            release_tag="$(norm "$(get_latest_release || true)")"
            prerelease_tag="$(norm "$(get_latest_prerelease || true)")"
            info "Latest release tag: ${release_tag:-<none>}"
            info "Latest prerelease tag: ${prerelease_tag:-<none>}"

            if [ -n "$release_tag" ] && [ -n "$prerelease_tag" ]; then
                if ver_gt "$prerelease_tag" "$release_tag"; then
                    VERSION="$prerelease_tag"
                else
                    VERSION="$release_tag"
                fi
            elif [ -n "$release_tag" ]; then
                VERSION="$release_tag"
            elif [ -n "$prerelease_tag" ]; then
                VERSION="$prerelease_tag"
            else
                error "No release or prerelease found."
                exit 2
            fi
            ;;
        *)
            error "Invalid CHECK_TYPE: $CHECK_TYPE"
            exit 1
            ;;
    esac

    if [ -z "$VERSION" ]; then
        error "Could not determine VERSION."
        exit 2
    fi

    info "Chosen VERSION: $VERSION"

    # Local version
    LOCAL_VERSION="$(norm "$(get_local_version || true)")"
    info "Local version: ${LOCAL_VERSION:-<none>}"

    # Compare versions if local exists
    if [ -n "$LOCAL_VERSION" ] && ! ver_gt "$VERSION" "$LOCAL_VERSION"; then
        info "No upgrade needed. VERSION ($VERSION) <= LOCAL_VERSION ($LOCAL_VERSION)"
        exit 0
    fi

    # Download and upgrade
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${DELIVERABLE}"
    info "Downloading: $DOWNLOAD_URL"

    curl -fL --retry 3 --retry-delay 2 -o "$TMP_DEB" "$DOWNLOAD_URL"
    info "Downloaded to $TMP_DEB"

    info "Installing..."
    if dpkg -i "$TMP_DEB" >>"$LOG" 2>&1; then
        info "Upgrade to cloudflared $VERSION successful."
        rm -f "$TMP_DEB"
        exit 0
    else
        info "dpkg failed, attempting: apt -f install"
        apt-get -f install -y >>"$LOG" 2>&1
        rm -f "$TMP_DEB"
        info "Completed with dependency fix."
        exit 0
    fi
}

main "$@"
