#!/bin/bash
set -e

PROJECT_DIR="/opt/tectonic"
OUTPUT_NAME="tectonic-$(date +%Y%m%d-%H%M%S).img"
IMAGE_SIZE="8G"
CONFIG_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_NAME="$2"
            shift 2
            ;;
        -s|--size)
            IMAGE_SIZE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 -c CONFIG [OPTIONS]"
            echo ""
            echo "Required:"
            echo "  -c, --config FILE    Configuration file"
            echo ""
            echo "Optional:"
            echo "  -o, --output NAME    Output filename (default: tectonic-TIMESTAMP.img)"
            echo "  -s, --size SIZE      Image size (default: 8G)"
            echo "  -h, --help           Show this help"
            echo ""
            echo "Example:"
            echo "  $0 -c configs/ollama.conf -o ollama-boot.img -s 16G"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (sudo ./build.sh)"
   exit 1
fi

# Verify config file
if [ -z "$CONFIG_FILE" ]; then
    echo "Error: Configuration file required (-c)"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Source configuration with defaults
APP_COMMAND=""
APP_NAME="Application"
PACKAGES=""
LOCALE="en_US.UTF-8"
TIMEZONE="UTC"
KEYBOARD_LAYOUT="us"
INPUT_METHOD=""
FONTS=""

source "$CONFIG_FILE"

if [ -z "$APP_COMMAND" ]; then
    echo "Error: APP_COMMAND not set in configuration"
    exit 1
fi

echo "=== Tectonic Image Builder v2 ==="
echo "Output: $PROJECT_DIR/images/$OUTPUT_NAME"
echo "Size: $IMAGE_SIZE"
echo "App: $APP_NAME"
echo "Command: $APP_COMMAND"
echo "Locale: $LOCALE"
echo "Input Method: ${INPUT_METHOD:-none}"
echo ""

# Build package list
BASE_PACKAGES="xorg-server xinit xterm rxvt-unicode font-noto"
ALL_PACKAGES="$BASE_PACKAGES $PACKAGES"

# Add input method packages
if [ "$INPUT_METHOD" = "ibus" ]; then
    ALL_PACKAGES="$ALL_PACKAGES ibus ibus-gtk3 ibus-hangul"
elif [ "$INPUT_METHOD" = "fcitx" ]; then
    ALL_PACKAGES="$ALL_PACKAGES fcitx fcitx-hangul fcitx-configtool"
fi

# Add font packages
case "$FONTS" in
    *korean*|*all*)
        ALL_PACKAGES="$ALL_PACKAGES font-noto-cjk"
        ;;
esac
case "$FONTS" in
    *chinese*|*all*)
        ALL_PACKAGES="$ALL_PACKAGES font-wqy-zenhei"
        ;;
esac
case "$FONTS" in
    *japanese*|*all*)
        ALL_PACKAGES="$ALL_PACKAGES font-noto-cjk"
        ;;
esac

echo "Installing packages: $ALL_PACKAGES"
echo ""

# Create Alpine configuration script
cat > "$PROJECT_DIR/build/alpine-config.sh" << 'CONFIGEOF'
#!/bin/sh
set -e

echo "=== Configuring Tectonic Alpine Image ==="

# Set timezone
ln -sf /usr/share/zoneinfo/__TIMEZONE__ /etc/localtime

# Set locale
cat > /etc/profile.d/locale.sh << 'LOCALEEOF'
export LANG=__LOCALE__
export LC_ALL=__LOCALE__
LOCALEEOF

# Configure keyboard
cat > /etc/conf.d/loadkmap << 'KEYMAPEOF'
KEYMAP="__KEYBOARD_LAYOUT__"
KEYMAPEOF

# Setup auto-login
sed -i 's/^tty1::respawn:\/sbin\/getty 38400 tty1$/tty1::respawn:\/sbin\/getty -n -l \/usr\/local\/bin\/auto-login 38400 tty1/' /etc/inittab

cat > /usr/local/bin/auto-login << 'LOGINEOF'
#!/bin/sh
exec /bin/login -f root
LOGINEOF
chmod +x /usr/local/bin/auto-login

# Create .xinitrc
cat > /root/.xinitrc << 'XINIT'
#!/bin/sh

# Set up input method if configured
__INPUT_METHOD_SETUP__

# Launch fullscreen terminal with application
exec xterm -maximized -fa 'Monospace' -fs 14 -e /usr/local/bin/app-launcher
XINIT

# Create application launcher
cat > /usr/local/bin/app-launcher << 'APPLAUNCHER'
#!/bin/sh
echo "Starting __APP_NAME__..."
echo ""
__APP_COMMAND__
echo ""
echo "Application exited. Press Enter to restart or Ctrl+C to exit."
read
exec /usr/local/bin/app-launcher
APPLAUNCHER
chmod +x /usr/local/bin/app-launcher

# Auto-startx on login
cat > /root/.profile << 'PROFILE'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
PROFILE

# Enable services
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwdrivers sysinit
rc-update add udev sysinit

rc-update add bootmisc boot
rc-update add hostname boot
rc-update add sysctl boot
rc-update add syslog boot
rc-update add networking boot

rc-update add mount-ro shutdown
rc-update add killprocs shutdown
rc-update add savecache shutdown

echo "=== Configuration complete ==="
CONFIGEOF

# Substitute variables in config script (using @ as delimiter to avoid issues with / in commands)
sed -i "s@__TIMEZONE__@$TIMEZONE@g" "$PROJECT_DIR/build/alpine-config.sh"
sed -i "s@__LOCALE__@$LOCALE@g" "$PROJECT_DIR/build/alpine-config.sh"
sed -i "s@__KEYBOARD_LAYOUT__@$KEYBOARD_LAYOUT@g" "$PROJECT_DIR/build/alpine-config.sh"
sed -i "s@__APP_NAME__@$APP_NAME@g" "$PROJECT_DIR/build/alpine-config.sh"
sed -i "s@__APP_COMMAND__@$APP_COMMAND@g" "$PROJECT_DIR/build/alpine-config.sh"

# Handle input method setup separately (multiline variable)
echo "$INPUT_SETUP" > "$PROJECT_DIR/build/input_setup.tmp"
sed -i "/__INPUT_METHOD_SETUP__/r $PROJECT_DIR/build/input_setup.tmp" "$PROJECT_DIR/build/alpine-config.sh"
sed -i "/__INPUT_METHOD_SETUP__/d" "$PROJECT_DIR/build/alpine-config.sh"
rm -f "$PROJECT_DIR/build/input_setup.tmp"

chmod +x "$PROJECT_DIR/build/alpine-config.sh"

# Setup input method
if [ "$INPUT_METHOD" = "ibus" ]; then
    INPUT_SETUP='export GTK_IM_MODULE=ibus
export XMODIFIERS=@im=ibus
export QT_IM_MODULE=ibus
ibus-daemon -drx &
sleep 2'
elif [ "$INPUT_METHOD" = "fcitx" ]; then
    INPUT_SETUP='export GTK_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export QT_IM_MODULE=fcitx
fcitx &
sleep 2'
else
    INPUT_SETUP='# No input method configured'
fi

# Build the image
echo "Building Alpine Linux image..."
echo "This may take several minutes..."
echo ""

# Ensure images directory exists
mkdir -p "$PROJECT_DIR/images"

# Change to build directory
cd "$PROJECT_DIR/build"

# Run alpine-make-vm-image with correct argument order
"$PROJECT_DIR/alpine-make-vm-image" \
    --image-format raw \
    --image-size "$IMAGE_SIZE" \
    --serial-console \
    --packages "$ALL_PACKAGES" \
    --script-chroot \
    "$PROJECT_DIR/images/$OUTPUT_NAME" \
    "$PROJECT_DIR/build/alpine-config.sh"

# Cleanup
rm -f "$PROJECT_DIR/build/alpine-config.sh"

echo ""
echo "=== Build Complete ==="
echo "Image: $PROJECT_DIR/images/$OUTPUT_NAME"
echo ""
echo "To write to USB:"
echo "  sudo dd if=$PROJECT_DIR/images/$OUTPUT_NAME of=/dev/sdX bs=4M status=progress"
echo ""
echo "Replace /dev/sdX with your USB device (use 'lsblk' to find it)"
