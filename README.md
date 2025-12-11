# D2D Demo

Phoenix LiveView web dashboard for D2D (Device-to-Device) communication testing. Provides a tabbed interface for testing LoRa, WiFi ad-hoc, and Bluetooth PAN connections with ping and throughput measurements.

## Setup

### Dependencies

```bash
# Install system dependencies (Manjaro/Arch)
sudo pacman -S iperf3 iw

# Install Elixir dependencies
mix setup
```

### Sudoers Configuration

The network scripts require sudo access without password prompts. Run:

```bash
sudo visudo -f /etc/sudoers.d/d2d
```

Add these lines (adjust username and path as needed):

```
dori ALL=(ALL) NOPASSWD: /home/dori/git/d2d/d2d_demo/priv/scripts/*.sh
dori ALL=(ALL) NOPASSWD: /home/dori/git/d2d/d2d_demo/_build/dev/lib/d2d_demo/priv/scripts/*.sh
dori ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart NetworkManager
```

## Usage

Start the Phoenix server:

```bash
mix phx.server
```

Open http://localhost:4000 in your browser.

### Dashboard Tabs

- **LoRa**: Connect to RN2903 module, configure radio settings, send/receive messages
- **WiFi**: Connect to Pi via WiFi ad-hoc, run ping and throughput tests
- **Bluetooth**: Connect to Pi via Bluetooth PAN, run ping and throughput tests

### Test Labels

Use the "Test Label" input at the top to name your tests (e.g., "20ft_test1", "indoor_close"). Labels are saved in the log files for later analysis.

### Log Files

Test results are saved to `logs/d2d_demo_YYYYMMDD_HHMMSS.log`

## IP Addresses

| Technology | Laptop (this device) | Pi |
|------------|----------------------|-----|
| WiFi Ad-hoc | 192.168.12.2 | 192.168.12.1 |
| Bluetooth PAN | 192.168.44.2 | 192.168.44.1 |

Pi Bluetooth MAC: `B8:27:EB:D6:9C:95` (update in Bluetooth tab if different)
