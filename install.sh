#!/usr/bin/env bash
set -euo pipefail

# claude-sync installer
# Usage: curl -fsSL https://raw.githubusercontent.com/your-user/claude-sync/main/install.sh | bash

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
REPO="your-user/claude-sync"
BRANCH="main"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

echo -e "${BOLD}Installing claude-sync...${NC}"

# Create install dir
mkdir -p "$INSTALL_DIR"

# Download
if command -v curl &>/dev/null; then
    curl -fsSL "https://raw.githubusercontent.com/$REPO/$BRANCH/claude-sync.sh" -o "$INSTALL_DIR/claude-sync"
elif command -v wget &>/dev/null; then
    wget -qO "$INSTALL_DIR/claude-sync" "https://raw.githubusercontent.com/$REPO/$BRANCH/claude-sync.sh"
else
    echo -e "${RED}Error: curl or wget required${NC}" >&2
    exit 1
fi

chmod +x "$INSTALL_DIR/claude-sync"

# Check PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo -e "${BLUE}[info]${NC} Add to your shell profile:"
    echo ""
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
fi

echo -e "${GREEN}[ok]${NC} Installed to $INSTALL_DIR/claude-sync"
echo ""
echo -e "Next steps:"
echo -e "  1. ${BOLD}claude-sync init${NC}                          # Create config repo"
echo -e "  2. ${BOLD}claude-sync export${NC}                        # Snapshot your setup"
echo -e "  3. ${BOLD}cd ~/.claude-config && git remote add origin <url>${NC}"
echo -e "  4. ${BOLD}claude-sync push${NC}                          # Push to remote"
