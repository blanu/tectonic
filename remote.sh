#!/bin/bash
set -e

# Usage function
usage() {
    echo "Usage: $0 -h HOST -c CONFIG [-u USER] [-o OUTPUT] [-d DEST]"
    echo ""
    echo "Required:"
    echo "  -h, --host HOST        SSH host to build on"
    echo "  -c, --config CONFIG    Config file name (e.g., professor.conf)"
    echo ""
    echo "Optional:"
    echo "  -u, --user USER        SSH user (default: root)"
    echo "  -o, --output NAME      Output image name (default: from config)"
    echo "  -d, --dest DIR         Local destination directory (default: ./images)"
    echo "  -g, --git-url URL      Git repository URL (default: none, assumes already cloned)"
    echo "  -b, --branch BRANCH    Git branch to pull (default: main)"
    echo "  --help                 Show this help"
    echo ""
    echo "Example:"
    echo "  $0 -h build.example.com -c professor.conf"
    echo "  $0 -h 192.168.1.100 -u root -c professor.conf -o korean-ollama.img"
    exit 1
}

# Default values
SSH_USER="root"
SSH_HOST=""
CONFIG_FILE=""
OUTPUT_NAME=""
DEST_DIR="./images"
GIT_URL=""
GIT_BRANCH="main"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)
            SSH_HOST="$2"
            shift 2
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -u|--user)
            SSH_USER="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_NAME="$2"
            shift 2
            ;;
        -d|--dest)
            DEST_DIR="$2"
            shift 2
            ;;
        -g|--git-url)
            GIT_URL="$2"
            shift 2
            ;;
        -b|--branch)
            GIT_BRANCH="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$SSH_HOST" ] || [ -z "$CONFIG_FILE" ]; then
    echo "Error: Host and config file are required"
    usage
fi

SSH_TARGET="$SSH_USER@$SSH_HOST"
REMOTE_TECTONIC="/opt/tectonic"
REMOTE_CONFIG="$REMOTE_TECTONIC/configs/$CONFIG_FILE"

echo "=== Tectonic Remote Build ==="
echo "Target: $SSH_TARGET"
echo "Config: $CONFIG_FILE"
echo ""

# Create local destination directory
mkdir -p "$DEST_DIR"

# Step 1: Update Tectonic from git if URL provided
if [ -n "$GIT_URL" ]; then
    echo "[1/5] Updating Tectonic from git..."
    ssh "$SSH_TARGET" "cd $REMOTE_TECTONIC && git pull origin $GIT_BRANCH || (git clone $GIT_URL $REMOTE_TECTONIC && cd $REMOTE_TECTONIC && git checkout $GIT_BRANCH)"
else
    echo "[1/5] Skipping git update (no --git-url provided)..."
fi

# Step 2: Upload config if it exists locally
if [ -f "$CONFIG_FILE" ]; then
    echo "[2/5] Uploading config file..."
    scp "$CONFIG_FILE" "$SSH_TARGET:$REMOTE_CONFIG"
else
    echo "[2/5] Using existing remote config..."
    # Verify config exists on remote
    if ! ssh "$SSH_TARGET" "test -f $REMOTE_CONFIG"; then
        echo "Error: Config file not found locally or on remote: $CONFIG_FILE"
        exit 1
    fi
fi

# Step 3: Build the image
echo "[3/5] Building image on remote host..."
if [ -n "$OUTPUT_NAME" ]; then
    ssh "$SSH_TARGET" "cd $REMOTE_TECTONIC && ./build.sh -c configs/$CONFIG_FILE -o $OUTPUT_NAME"
else
    ssh "$SSH_TARGET" "cd $REMOTE_TECTONIC && ./build.sh -c configs/$CONFIG_FILE"
fi

# Step 4: Get the image filename
echo "[4/5] Getting image filename..."
if [ -n "$OUTPUT_NAME" ]; then
    REMOTE_IMAGE="$REMOTE_TECTONIC/images/$OUTPUT_NAME"
else
    # Get the most recent image
    REMOTE_IMAGE=$(ssh "$SSH_TARGET" "ls -t $REMOTE_TECTONIC/images/*.img | head -1")
fi

if [ -z "$REMOTE_IMAGE" ]; then
    echo "Error: No image file found on remote"
    exit 1
fi

IMAGE_BASENAME=$(basename "$REMOTE_IMAGE")
echo "Image: $IMAGE_BASENAME"

# Step 5: Download the image
echo "[5/5] Downloading image..."
scp "$SSH_TARGET:$REMOTE_IMAGE" "$DEST_DIR/$IMAGE_BASENAME"

echo ""
echo "=== Build Complete ==="
echo "Image downloaded to: $DEST_DIR/$IMAGE_BASENAME"
echo ""
echo "To write to USB:"
echo "  sudo dd if=$DEST_DIR/$IMAGE_BASENAME of=/dev/sdX bs=4M status=progress"
echo ""
echo "Replace /dev/sdX with your USB device"
