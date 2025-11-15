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
	rosewater = lipgloss.Color("#f5e0dc")
	flamingo  = lipgloss.Color("#f2cdcd")
	pink      = lipgloss.Color("#f5c2e7")
	mauve     = lipgloss.Color("#cba6f7")
	red       = lipgloss.Color("#f38ba8")
	maroon    = lipgloss.Color("#eba0ac")
	peach     = lipgloss.Color("#fab387")
	yellow    = lipgloss.Color("#f9e2af")
	green     = lipgloss.Color("#a6e3a1")
	teal      = lipgloss.Color("#94e2d5")
	sky       = lipgloss.Color("#89dceb")
	sapphire  = lipgloss.Color("#74c7ec")
	blue      = lipgloss.Color("#89b4fa")
	lavender  = lipgloss.Color("#b4befe")
	text      = lipgloss.Color("#cdd6f4")
	subtext1  = lipgloss.Color("#bac2de")
	subtext0  = lipgloss.Color("#a6adc8")
	overlay2  = lipgloss.Color("#9399b2")
	overlay1  = lipgloss.Color("#7f849c")
	overlay0  = lipgloss.Color("#6c7086")
	surface2  = lipgloss.Color("#585b70")
	surface1  = lipgloss.Color("#45475a")
	surface0  = lipgloss.Color("#313244")
	base      = lipgloss.Color("#1e1e2e")
	mantle    = lipgloss.Color("#181825")
	crust     = lipgloss.Color("#11111b")
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
		// Fallback to scanning directory
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
