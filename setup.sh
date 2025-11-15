#!/bin/bash
set -e

echo "=== Tectonic Development Environment Setup ==="
echo "Setting up Alpine Linux image building tools on Raspbian"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
   echo "Please run as root (sudo ./setup.sh)"
   exit 1
fi

# Update system
echo "[1/5] Updating system packages..."
apt-get update
apt-get upgrade -y

# Install required packages
echo "[2/5] Installing dependencies..."
apt-get install -y \
    wget \
    curl \
    git \
    qemu-utils \
    qemu-system-x86 \
    e2fsprogs \
    dosfstools \
    parted \
    syslinux \
    extlinux \
    python3 \
    python3-pip \
    golang-go

# Create tectonic project directory
echo "[3/5] Creating project structure..."
PROJECT_DIR="/opt/tectonic"
mkdir -p "$PROJECT_DIR"/{build,images,vms,scripts}

cd "$PROJECT_DIR"

# Download alpine-make-vm-image
echo "[4/5] Downloading alpine-make-vm-image..."
wget https://raw.githubusercontent.com/alpinelinux/alpine-make-vm-image/master/alpine-make-vm-image -O scripts/alpine-make-vm-image
chmod +x scripts/alpine-make-vm-image

# Create a basic example configuration script
echo "[5/5] Creating example build configuration..."
cat > scripts/example-config.sh << 'EOF'
#!/bin/sh
# This script runs inside the Alpine image during build
# Customize this for your VM picker use case

# Install packages
apk add --no-cache \
    qemu-system-x86_64 \
    tmux \
    bash \
    ncurses

# Create directories
mkdir -p /opt/vms
mkdir -p /usr/local/bin

echo "Example configuration complete"
EOF

chmod +x scripts/example-config.sh

# Create vm-picker source directory structure
echo "Creating vm-picker application structure..."
mkdir -p scripts/vm-picker-src

cat > scripts/vm-picker-src/go.mod << 'GOMOD'
module tectonic/vm-picker

go 1.21

require (
	github.com/charmbracelet/bubbles v0.18.0
	github.com/charmbracelet/bubbletea v0.25.0
	github.com/charmbracelet/lipgloss v0.9.1
)
GOMOD

cat > scripts/vm-picker-src/main.go << 'GOMAIN'
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// Catppuccin Mocha colors
var (
	mauve     = lipgloss.Color("#cba6f7")
	base      = lipgloss.Color("#1e1e2e")
	overlay2  = lipgloss.Color("#9399b2")
	overlay1  = lipgloss.Color("#7f849c")
)

var (
	titleStyle = lipgloss.NewStyle().
			Foreground(mauve).
			Bold(true).
			Padding(1, 0)

	selectedStyle = lipgloss.NewStyle().
			Foreground(base).
			Background(mauve).
			Padding(0, 1)

	descStyle = lipgloss.NewStyle().
			Foreground(overlay2)

	helpStyle = lipgloss.NewStyle().
			Foreground(overlay1).
			Padding(1, 0)
)

type vm struct {
	name        string
	path        string
	memory      string
	description string
}

func (v vm) Title() string       { return v.name }
func (v vm) Description() string { return v.description }
func (v vm) FilterValue() string { return v.name }

type model struct {
	list     list.Model
	vms      []vm
	quitting bool
	selected *vm
}

func loadVMs() []vm {
	vms := []vm{}
	
	file, err := os.Open("/etc/tectonic/vms.conf")
	if err != nil {
		entries, err := os.ReadDir("/opt/vms")
		if err != nil {
			return vms
		}
		for _, entry := range entries {
			if !entry.IsDir() {
				vms = append(vms, vm{
					name:        entry.Name(),
					path:        "/opt/vms/" + entry.Name(),
					memory:      "2048",
					description: "VM Image",
				})
			}
		}
		return vms
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "#") || len(strings.TrimSpace(line)) == 0 {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) >= 4 {
			vms = append(vms, vm{
				name:        parts[0],
				path:        parts[1],
				memory:      parts[2],
				description: parts[3],
			})
		}
	}

	return vms
}

func initialModel() model {
	vms := loadVMs()
	
	items := make([]list.Item, len(vms))
	for i, v := range vms {
		items[i] = v
	}

	delegate := list.NewDefaultDelegate()
	delegate.Styles.SelectedTitle = selectedStyle
	delegate.Styles.SelectedDesc = descStyle

	l := list.New(items, delegate, 0, 0)
	l.Title = "Tectonic VM Picker"
	l.Styles.Title = titleStyle
	l.SetShowStatusBar(false)
	l.SetFilteringEnabled(false)

	return model{
		list: l,
		vms:  vms,
	}
}

func (m model) Init() tea.Cmd {
	return nil
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.list.SetWidth(msg.Width)
		m.list.SetHeight(msg.Height - 4)
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			m.quitting = true
			return m, tea.Quit

		case "enter":
			if selected, ok := m.list.SelectedItem().(vm); ok {
				m.selected = &selected
				m.quitting = true
				return m, tea.Quit
			}
		}
	}

	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return m, cmd
}

func (m model) View() string {
	if m.quitting {
		return ""
	}

	help := helpStyle.Render("↑/↓: navigate • enter: select • q: quit")
	return lipgloss.JoinVertical(lipgloss.Left,
		m.list.View(),
		help,
	)
}

func launchVM(v vm) error {
	fmt.Printf("\nLaunching %s...\n", v.name)
	fmt.Printf("Memory: %s MB\n", v.memory)
	fmt.Printf("Path: %s\n\n", v.path)

	cmd := exec.Command("qemu-system-x86_64",
		"-enable-kvm",
		"-m", v.memory,
		"-drive", "file="+v.path+",format=qcow2",
		"-nographic",
		"-serial", "mon:stdio",
	)

	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	return cmd.Run()
}

func main() {
	m := initialModel()

	if len(m.vms) == 0 {
		fmt.Println("No VMs found in /opt/vms/")
		fmt.Println("Please add VM images to /opt/vms/")
		os.Exit(1)
	}

	p := tea.NewProgram(m, tea.WithAltScreen())
	finalModel, err := p.Run()
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		os.Exit(1)
	}

	if m := finalModel.(model); m.selected != nil {
		if err := launchVM(*m.selected); err != nil {
			fmt.Printf("Error launching VM: %v\n", err)
			os.Exit(1)
		}
	}
}
GOMAIN

echo "Building vm-picker application..."
cd scripts/vm-picker-src
go mod download
go build -o ../vm-picker .
cd "$PROJECT_DIR"

if [ ! -f scripts/vm-picker ]; then
    echo "Error: Failed to build vm-picker"
    exit 1
fi

echo "vm-picker built successfully"

# Create README
cat > README.md << 'EOF'
# Tectonic

Custom Alpine Linux image builder for bootable VM picker system.

## Directory Structure

- `build/` - Temporary build artifacts
- `images/` - Generated bootable images
- `vms/` - VM images to include
- `scripts/` - Build scripts and configurations

## Usage

1. Create your custom configuration script in `scripts/`
2. Add any VM images to `vms/`
3. Run the build script (coming next)

## Requirements

- Root access
- At least 2GB free disk space
- Internet connection for downloading Alpine packages
EOF

echo ""
echo "=== Setup Complete ==="
echo "Project directory: $PROJECT_DIR"
echo ""
echo "Next steps:"
echo "1. Create your custom VM picker application"
echo "2. Create VM images in $PROJECT_DIR/vms/"
echo "3. Customize the configuration in $PROJECT_DIR/scripts/"
echo ""
echo "Run 'cd $PROJECT_DIR' to get started"
