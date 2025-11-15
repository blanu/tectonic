#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="/opt/tectonic"
OUTPUT_NAME="tectonic-$(date +%Y%m%d-%H%M%S).img"
IMAGE_SIZE="8G"
VM_IMAGES=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_NAME="$2"
            shift 2
            ;;
        -s|--size)
            IMAGE_SIZE="$2"
            shift 2
            ;;
        -v|--vm)
            VM_IMAGES+=("$2")
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -o, --output NAME    Output image filename (default: tectonic-TIMESTAMP.img)"
            echo "  -s, --size SIZE      Image size (default: 8G)"
            echo "  -v, --vm PATH        VM image to include (can be used multiple times)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Example:"
            echo "  $0 -v /path/to/vm1.qcow2 -v /path/to/vm2.qcow2 -o custom.img"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (sudo ./build.sh)"
   exit 1
fi

echo "=== Tectonic Image Builder ==="
echo "Output: $PROJECT_DIR/images/$OUTPUT_NAME"
echo "Size: $IMAGE_SIZE"
echo "VM Images: ${#VM_IMAGES[@]}"
echo ""

# Build vm-picker if source exists
if [ -d "$PROJECT_DIR/scripts/vm-picker-src" ]; then
    echo "Building vm-picker..."
    cd "$PROJECT_DIR/scripts/vm-picker-src"
    go build -o ../vm-picker .
    cd "$PROJECT_DIR"
    
    if [ ! -f "$PROJECT_DIR/scripts/vm-picker" ]; then
        echo "Error: Failed to build vm-picker"
        exit 1
    fi
    echo "vm-picker built successfully"
    echo ""
fi

# Verify VM images exist
for vm in "${VM_IMAGES[@]}"; do
    if [ ! -f "$vm" ]; then
        echo "Error: VM image not found: $vm"
        exit 1
    fi
    echo "  - $(basename "$vm")"
done

# Check if vm-picker exists
if [ ! -f "$PROJECT_DIR/scripts/vm-picker" ]; then
    echo ""
    echo "Warning: vm-picker not found at $PROJECT_DIR/scripts/vm-picker"
    echo "Creating a placeholder. Replace this with your actual VM picker application."
    
    cat > "$PROJECT_DIR/scripts/vm-picker" << 'EOF'
#!/bin/sh
echo "VM Picker Placeholder"
echo "Replace this with your actual VM picker application"
echo ""
echo "Available VMs:"
ls -1 /opt/vms/
EOF
    chmod +x "$PROJECT_DIR/scripts/vm-picker"
fi

# Create the configuration script
echo ""
echo "Generating Alpine configuration..."

cat > "$PROJECT_DIR/build/alpine-config.sh" << 'CONFIGEOF'
#!/bin/sh
set -e

echo "=== Configuring Alpine Linux for Tectonic ==="

# Install base packages
apk add --no-cache \
    qemu-system-x86_64 \
    qemu-img \
    tmux \
    bash \
    ncurses \
    ncurses-terminfo \
    coreutils \
    util-linux \
    eudev

# Create necessary directories
mkdir -p /opt/vms
mkdir -p /usr/local/bin
mkdir -p /etc/tectonic

# Copy VM picker application
if [ -f /tmp/tectonic-build/vm-picker ]; then
    cp /tmp/tectonic-build/vm-picker /usr/local/bin/
    chmod +x /usr/local/bin/vm-picker
fi

# Copy VM images
if [ -d /tmp/tectonic-build/vms ]; then
    cp /tmp/tectonic-build/vms/* /opt/vms/ 2>/dev/null || true
fi

# Create VM registry file
cat > /etc/tectonic/vms.conf << 'EOF'
# Tectonic VM Registry
# Format: name|path|memory|description
EOF

# Auto-populate VM registry from available images
for vm in /opt/vms/*; do
    if [ -f "$vm" ]; then
        vmname=$(basename "$vm" | sed 's/\.[^.]*$//')
        echo "$vmname|$vm|2048|Imported VM" >> /etc/tectonic/vms.conf
    fi
done

# Setup auto-login to root
sed -i 's/^tty1::respawn:\/sbin\/getty 38400 tty1$/tty1::respawn:\/sbin\/getty -n -l \/usr\/local\/bin\/auto-login 38400 tty1/' /etc/inittab

# Create auto-login script
cat > /usr/local/bin/auto-login << 'LOGINEOF'
#!/bin/sh
exec /bin/login -f root
LOGINEOF
chmod +x /usr/local/bin/auto-login

# Setup .profile to launch vm-picker on login
cat > /root/.profile << 'PROFILEOF'
# Launch vm-picker on login
if [ -z "$TECTONIC_LAUNCHED" ]; then
    export TECTONIC_LAUNCHED=1
    if [ -x /usr/local/bin/vm-picker ]; then
        exec /usr/local/bin/vm-picker
    else
        echo "Error: vm-picker not found"
    fi
fi
PROFILEOF

# Enable services
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwdrivers sysinit

rc-update add bootmisc boot
rc-update add hostname boot
rc-update add sysctl boot
rc-update add syslog boot

rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

echo "=== Alpine configuration complete ==="
CONFIGEOF

chmod +x "$PROJECT_DIR/build/alpine-config.sh"

# Create temporary build directory for assets
mkdir -p "$PROJECT_DIR/build/tectonic-build/vms"

# Copy vm-picker
cp "$PROJECT_DIR/scripts/vm-picker" "$PROJECT_DIR/build/tectonic-build/"

# Copy VM images
for vm in "${VM_IMAGES[@]}"; do
    echo "Copying $(basename "$vm")..."
    cp "$vm" "$PROJECT_DIR/build/tectonic-build/vms/"
done

# Build the image
echo ""
echo "Building Alpine Linux image..."
echo "This may take several minutes..."
echo ""

cd "$PROJECT_DIR/build"

"$PROJECT_DIR/scripts/alpine-make-vm-image" \
    --image-format raw \
    --image-size "$IMAGE_SIZE" \
    --serial-console \
    --packages "qemu-system-x86_64 qemu-img tmux bash ncurses coreutils util-linux eudev" \
    --script-chroot \
    --fs-skel-dir "$PROJECT_DIR/build/tectonic-build" \
    --fs-skel-chown root:root \
    alpine-config.sh \
    "$PROJECT_DIR/images/$OUTPUT_NAME"

# Cleanup
rm -rf "$PROJECT_DIR/build/tectonic-build"
rm -f "$PROJECT_DIR/build/alpine-config.sh"

echo ""
echo "=== Build Complete ==="
echo "Image created: $PROJECT_DIR/images/$OUTPUT_NAME"
echo ""
echo "To write to USB:"
echo "  sudo dd if=$PROJECT_DIR/images/$OUTPUT_NAME of=/dev/sdX bs=4M status=progress"
echo ""
echo "Replace /dev/sdX with your USB device (use 'lsblk' to find it)"
