#!/bin/bash
set -e

echo "=== Tectonic Development Environment Setup ==="
echo "Alpine Linux bootable application builder"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (sudo ./setup.sh)"
   exit 1
fi

# Update system
echo "[1/4] Updating system packages..."
apt-get update
apt-get upgrade -y

# Install required packages
echo "[2/4] Installing dependencies..."
apt-get install -y \
    wget \
    curl \
    git \
    qemu-utils \
    e2fsprogs \
    dosfstools \
    parted \
    python3 \
    python3-pip

# Create tectonic project directory
echo "[3/4] Creating project structure..."
PROJECT_DIR="/opt/tectonic"
mkdir -p "$PROJECT_DIR"/{build,images,apps,configs}

cd "$PROJECT_DIR"

# Download alpine-make-vm-image
echo "[4/4] Downloading alpine-make-vm-image..."
wget https://raw.githubusercontent.com/alpinelinux/alpine-make-vm-image/master/alpine-make-vm-image -O alpine-make-vm-image
chmod +x alpine-make-vm-image

# Create example configuration
cat > configs/example.conf << 'EOF'
# Tectonic Configuration Example
# All fields are optional except APP_COMMAND

# Application to run (required)
APP_COMMAND="echo 'Replace with your application command'"

# Display name for the application
APP_NAME="Example App"

# Packages to install (space-separated)
PACKAGES="htop tmux bash"

# Locale settings
LOCALE="en_US.UTF-8"
TIMEZONE="UTC"
KEYBOARD_LAYOUT="us"

# Input method for CJK languages (ibus or fcitx)
# Leave empty for no input method
INPUT_METHOD=""

# Additional fonts (space-separated)
# Options: chinese japanese korean all
FONTS=""
EOF

# Create README
cat > README.md << 'EOF'
# Tectonic v2

Build bootable Alpine Linux images that boot directly into your application.

## Directory Structure

- `build/` - Temporary build artifacts
- `images/` - Generated bootable images  
- `apps/` - Application binaries/scripts
- `configs/` - Configuration files

## Quick Start

1. Create a configuration file in `configs/`:
```bash
cat > configs/ollama.conf << 'CONF'
APP_COMMAND="ollama serve"
APP_NAME="Ollama"
PACKAGES="curl"
LOCALE="ko_KR.UTF-8"
INPUT_METHOD="ibus"
FONTS="korean"
KEYBOARD_LAYOUT="kr"
CONF
```

2. Build the image:
```bash
sudo ./build.sh -c configs/ollama.conf -o ollama.img
```

3. Write to USB:
```bash
sudo dd if=images/ollama.img of=/dev/sdX bs=4M status=progress
```

## Configuration Options

See `configs/example.conf` for all available options.

## Localization

Supported locales: any valid Linux locale (en_US.UTF-8, ko_KR.UTF-8, ja_JP.UTF-8, zh_CN.UTF-8, etc.)
Input methods: ibus (recommended) or fcitx
Font packs: chinese, japanese, korean, all
EOF

echo ""
echo "=== Setup Complete ==="
echo "Project directory: $PROJECT_DIR"
echo ""
echo "Next steps:"
echo "1. Create a configuration in $PROJECT_DIR/configs/"
echo "2. Run: cd $PROJECT_DIR && sudo ./build.sh -c configs/yourconfig.conf"
echo ""
