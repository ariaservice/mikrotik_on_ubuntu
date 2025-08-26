#!/bin/bash

# MikroTik RouterOS CHR Auto Installation Script
# This script automatically installs MikroTik RouterOS CHR, replacing the current OS
# WARNING: This will completely destroy the current operating system!

set -euo pipefail

# Configuration
ROUTEROS_VERSION="7.19.4"
CHR_IMAGE_URL="https://download.mikrotik.com/routeros/${ROUTEROS_VERSION}/chr-${ROUTEROS_VERSION}.img.zip"
TEMP_DIR="/tmp/mikrotik_install"
NBD_DEVICE="/dev/nbd0"
INSTALL_LOG="/tmp/mikrotik_install.log"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$INSTALL_LOG"
}

print_info() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$INSTALL_LOG"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$INSTALL_LOG"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$INSTALL_LOG"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1" | tee -a "$INSTALL_LOG"; }

show_usage() {
    cat << EOF
Usage: $0 <PASSWORD> [OPTIONS]

Arguments:
  PASSWORD    Admin password for MikroTik RouterOS (required)

Options:
  -v VERSION  RouterOS version (default: ${ROUTEROS_VERSION})
  -d DISK     Target disk (auto-detected if not specified)
  -i IP/MASK  Static IP address (CIDR format, e.g., 192.168.1.100/24)
  -g GATEWAY  Gateway IP address
  -n DNS      DNS servers (comma-separated, default: 1.1.1.1,1.0.0.1)
  --dhcp      Use DHCP instead of static IP (default: use current config)
  --force     Force installation (skip all confirmations)
  --dry-run   Show what would be done without executing
  -h          Show this help

Examples:
  $0 "mypassword123" --force
  $0 "mypassword123" -i 192.168.1.100/24 -g 192.168.1.1 --force
  $0 "mypassword123" -v 7.20.1 -d sda --dhcp --force
  $0 "mypassword123" --dry-run

WARNING: This will completely replace your current operating system!
Use --force to skip all confirmations (recommended for automation).
EOF
}

cleanup() {
    local exit_code=$?
    print_info "Performing cleanup..."
    
    # Kill any background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # Unmount filesystems
    for mount_point in /mnt/mikrotik /mnt; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            umount -l "$mount_point" 2>/dev/null || true
        fi
    done
    
    # Disconnect NBD
    if [ -b "$NBD_DEVICE" ]; then
        qemu-nbd -d "$NBD_DEVICE" 2>/dev/null || true
    fi
    
    # Remove temp directory
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    
    if [ $exit_code -ne 0 ]; then
        print_error "Installation failed with exit code $exit_code"
        print_error "Log file: $INSTALL_LOG"
    fi
    
    exit $exit_code
}

trap cleanup EXIT INT TERM

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

check_environment() {
    print_step "Checking system environment..."
    
    # Check if we're in a container
    if [ -f /.dockerenv ] || grep -q container=lxc /proc/1/environ 2>/dev/null; then
        print_error "Cannot install RouterOS CHR in a container environment"
        exit 1
    fi
    
    # Check system architecture
    local arch=$(uname -m)
    if [ "$arch" != "x86_64" ]; then
        print_error "RouterOS CHR requires x86_64 architecture, found: $arch"
        exit 1
    fi
    
    # Check available memory
    local mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local mem_mb=$((mem_kb / 1024))
    if [ "$mem_mb" -lt 256 ]; then
        print_error "RouterOS CHR requires at least 256MB RAM, found: ${mem_mb}MB"
        exit 1
    fi
    
    print_info "Environment check passed"
}

detect_network_config() {
    print_step "Detecting current network configuration..."
    
    # Find primary interface
    local interface=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    if [ -z "$interface" ]; then
        interface=$(ip -o link show | awk -F': ' '$2 !~ /lo|docker|br-|veth/ {print $2; exit}')
    fi
    
    if [ -z "$interface" ]; then
        print_error "Could not detect network interface"
        exit 1
    fi
    
    # Get current IP configuration
    local current_ip=$(ip addr show "$interface" | grep 'inet ' | awk '{print $2}' | head -n1)
    local current_gw=$(ip route show default | awk '{print $3}' | head -n1)
    local current_dns=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    
    print_info "Primary interface: $interface"
    print_info "Current IP: ${current_ip:-DHCP}"
    print_info "Current Gateway: ${current_gw:-auto}"
    print_info "Current DNS: ${current_dns:-system}"
    
    echo "$interface|$current_ip|$current_gw|$current_dns"
}

detect_target_disk() {
    print_step "Detecting target disk..."
    
    # Find the disk containing the root filesystem
    local root_disk=$(lsblk -no PKNAME $(findmnt -no SOURCE /) | head -n1)
    
    if [ -z "$root_disk" ]; then
        # Fallback detection
        root_disk=$(lsblk -d -n -o NAME | grep -E '^(sda|vda|nvme0n1)$' | head -n1)
    fi
    
    if [ -z "$root_disk" ]; then
        print_error "Could not detect target disk"
        print_error "Available disks:"
        lsblk -d -o NAME,SIZE,TYPE
        exit 1
    fi
    
    local disk_size=$(lsblk -b -d -n -o SIZE "/dev/$root_disk")
    local size_gb=$((disk_size / 1024 / 1024 / 1024))
    
    if [ "$size_gb" -lt 1 ]; then
        print_error "Target disk is too small: ${size_gb}GB (minimum 1GB required)"
        exit 1
    fi
    
    print_info "Target disk: /dev/$root_disk (${size_gb}GB)"
    echo "$root_disk"
}

install_dependencies() {
    print_step "Installing required packages..."
    
    # Update package list
    export DEBIAN_FRONTEND=noninteractive
    
    # Detect package manager
    if command -v apt-get >/dev/null; then
        apt-get update -qq
        apt-get install -y qemu-utils pv wget unzip e2fsprogs util-linux parted
    elif command -v yum >/dev/null; then
        yum install -y qemu-img pv wget unzip e2fsprogs util-linux parted
    elif command -v dnf >/dev/null; then
        dnf install -y qemu-img pv wget unzip e2fsprogs util-linux parted
    else
        print_error "Unsupported package manager. Please install manually: qemu-utils, pv, wget, unzip, e2fsprogs, util-linux, parted"
        exit 1
    fi
    
    # Load NBD module
    modprobe nbd max_part=8 || {
        print_error "Failed to load NBD module. Kernel may not support NBD."
        exit 1
    }
}

download_chr_image() {
    print_step "Downloading RouterOS CHR v${ROUTEROS_VERSION}..."
    
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR"
    
    # Check if already downloaded
    if [ -f "chr-${ROUTEROS_VERSION}.img" ]; then
        print_info "CHR image already exists, skipping download"
        return 0
    fi
    
    # Download with retry
    local attempts=3
    while [ $attempts -gt 0 ]; do
        if wget --timeout=30 --tries=3 -q --show-progress "$CHR_IMAGE_URL" -O chr.img.zip; then
            break
        fi
        attempts=$((attempts - 1))
        if [ $attempts -eq 0 ]; then
            print_error "Failed to download CHR image after multiple attempts"
            exit 1
        fi
        print_warn "Download failed, retrying... ($attempts attempts left)"
        sleep 5
    done
    
    # Extract and verify
    print_info "Extracting CHR image..."
    if ! unzip -q chr.img.zip; then
        print_error "Failed to extract CHR image"
        exit 1
    fi
    
    if [ ! -f "chr-${ROUTEROS_VERSION}.img" ]; then
        print_error "CHR image file not found after extraction"
        ls -la
        exit 1
    fi
    
    print_info "CHR image ready: $(ls -lh chr-${ROUTEROS_VERSION}.img | awk '{print $5}')"
}

prepare_chr_image() {
    print_step "Preparing CHR image..."
    
    cd "$TEMP_DIR"
    
    # Convert to qcow2 for easier handling
    print_info "Converting image format..."
    qemu-img convert "chr-${ROUTEROS_VERSION}.img" -O qcow2 chr.qcow2
    
    # Resize image to ensure enough space
    print_info "Resizing image..."
    qemu-img resize chr.qcow2 2G
    
    # Connect via NBD
    qemu-nbd -c "$NBD_DEVICE" chr.qcow2
    sleep 3
    
    # Ensure partition table is readable
    partprobe "$NBD_DEVICE" 2>/dev/null || true
    sleep 2
    
    # Verify partitions
    if [ ! -b "${NBD_DEVICE}p1" ] || [ ! -b "${NBD_DEVICE}p2" ]; then
        print_error "CHR partitions not detected"
        qemu-nbd -d "$NBD_DEVICE"
        exit 1
    fi
    
    print_info "CHR image prepared successfully"
}

configure_chr_network() {
    local password="$1"
    local static_ip="$2"
    local gateway="$3"
    local dns_servers="$4"
    local use_dhcp="$5"
    local interface="$6"
    
    print_step "Configuring CHR network settings..."
    
    # Mount CHR filesystem
    mkdir -p /mnt/mikrotik
    if ! mount "${NBD_DEVICE}p2" /mnt/mikrotik; then
        print_error "Failed to mount CHR filesystem"
        exit 1
    fi
    
    # Create autorun configuration script
    local autorun_script="/mnt/mikrotik/rw/autorun.scr"
    
    cat > "$autorun_script" << 'EOF'
# MikroTik RouterOS CHR Auto-Configuration Script
# This script runs automatically on first boot

# Set system identity
/system identity set name="MikroTik-CHR"

# Configure admin user with password
EOF
    
    echo "/user set 0 name=admin password=\"$password\"" >> "$autorun_script"
    
    # Network configuration
    if [ "$use_dhcp" = "yes" ]; then
        cat >> "$autorun_script" << 'EOF'

# Configure DHCP client
/ip dhcp-client add interface=ether1 disabled=no

EOF
    else
        if [ -n "$static_ip" ] && [ -n "$gateway" ]; then
            cat >> "$autorun_script" << EOF

# Configure static IP
/ip address add address=$static_ip interface=ether1
/ip route add gateway=$gateway

EOF
        else
            print_warn "No static IP configuration provided, using DHCP as fallback"
            echo "/ip dhcp-client add interface=ether1 disabled=no" >> "$autorun_script"
        fi
    fi
    
    # DNS configuration
    if [ -n "$dns_servers" ]; then
        echo "/ip dns set servers=$dns_servers allow-remote-requests=yes" >> "$autorun_script"
    else
        echo "/ip dns set servers=1.1.1.1,1.0.0.1 allow-remote-requests=yes" >> "$autorun_script"
    fi
    
    # Security hardening
    cat >> "$autorun_script" << 'EOF'

# Disable unnecessary services
/ip service disable telnet
/ip service disable ftp
/ip service disable www
/tool mac-server set allowed-interface-list=none
/tool mac-server mac-winbox set allowed-interface-list=none
/tool mac-server ping set enabled=no

# Enable only secure services
/ip service set ssh port=22 disabled=no
/ip service set winbox port=8291 disabled=no
/ip service set api port=8728 disabled=no

# Configure firewall
/ip firewall filter add chain=input action=accept connection-state=established,related
/ip firewall filter add chain=input action=accept protocol=icmp
/ip firewall filter add chain=input action=accept src-address=10.0.0.0/8
/ip firewall filter add chain=input action=accept src-address=172.16.0.0/12
/ip firewall filter add chain=input action=accept src-address=192.168.0.0/16
/ip firewall filter add chain=input action=drop

# Update system packages
/system package update check-for-updates
/system package update download

# Log successful configuration
/log info "CHR auto-configuration completed successfully"

EOF
    
    # Make sure the script is executable and properly formatted
    chmod +x "$autorun_script"
    
    # Unmount
    umount /mnt/mikrotik
    
    print_info "CHR configuration completed"
}

extend_chr_filesystem() {
    print_step "Extending CHR filesystem..."
    
    # Extend the partition to use available space
    print_info "Extending partition table..."
    
    # Use parted for reliable partition extension
    parted -s "$NBD_DEVICE" resizepart 2 100% || {
        print_warn "Parted resize failed, trying fdisk method..."
        
        # Fallback to fdisk method
        echo -e 'd\n2\nn\np\n2\n65537\n\nw\n' | fdisk "$NBD_DEVICE" 2>/dev/null || true
    }
    
    # Force kernel to re-read partition table
    partprobe "$NBD_DEVICE" 2>/dev/null || true
    sleep 2
    
    # Check and resize filesystem
    print_info "Checking and resizing filesystem..."
    e2fsck -f -y "${NBD_DEVICE}p2" 2>/dev/null || {
        print_warn "Filesystem check failed, continuing anyway..."
    }
    
    if ! resize2fs "${NBD_DEVICE}p2" 2>/dev/null; then
        print_warn "Filesystem resize failed, but installation can continue"
    fi
    
    print_info "Filesystem extension completed"
}

write_chr_to_disk() {
    local target_disk="$1"
    local target_path="/dev/$target_disk"
    
    print_step "Writing CHR image to target disk: $target_path"
    
    # Create a compressed image in memory for faster writing
    print_info "Preparing compressed image..."
    
    # Use tmpfs for faster operations
    mount -t tmpfs tmpfs /mnt -o size=1G
    
    # Create compressed backup
    print_info "Creating compressed image (this may take a few minutes)..."
    pv "$NBD_DEVICE" | gzip -1 > /mnt/chr-ready.gz
    
    # Disconnect NBD before writing
    qemu-nbd -d "$NBD_DEVICE"
    sleep 2
    
    # Show final warning
    print_warn "FINAL WARNING: About to overwrite $target_path"
    print_warn "This will completely destroy the current operating system!"
    print_warn "The system will reboot automatically after installation."
    
    if [ "$FORCE_INSTALL" != "yes" ]; then
        echo -n "Type 'DESTROY' to confirm: "
        read -r final_confirm
        if [ "$final_confirm" != "DESTROY" ]; then
            print_info "Installation cancelled"
            exit 0
        fi
    fi
    
    # Point of no return - disable all possible interrupts
    trap '' INT TERM
    
    print_info "STARTING DISK WRITE - DO NOT INTERRUPT!"
    print_info "Writing compressed image to $target_path..."
    
    # Write to disk with progress
    zcat /mnt/chr-ready.gz | pv -s $(gzip -l /mnt/chr-ready.gz | tail -n1 | awk '{print $2}') | dd of="$target_path" bs=1M conv=fdatasync 2>/dev/null
    
    # Force filesystem sync
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    
    print_info "Installation completed successfully!"
    print_info "RouterOS CHR has been installed on $target_path"
    
    # Clean up
    umount /mnt
    
    print_warn "System will reboot in 10 seconds to boot into RouterOS CHR..."
    
    # Countdown
    for i in {10..1}; do
        echo -n "$i "
        sleep 1
    done
    echo
    
    # Final log
    log "MikroTik CHR installation completed successfully on $target_path"
    
    # Reboot
    print_info "Rebooting to RouterOS CHR..."
    exec /sbin/reboot -f
}

show_dry_run() {
    local password="$1"
    local target_disk="$2"
    local network_config="$3"
    
    IFS='|' read -r interface current_ip current_gw current_dns <<< "$network_config"
    
    cat << EOF

=== DRY RUN - MIKROTIK CHR INSTALLATION PLAN ===

System Information:
  - Architecture: $(uname -m)
  - Memory: $(awk '/MemTotal/ {printf "%.1fGB", $2/1024/1024}' /proc/meminfo)
  - Current OS: $([ -f /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME" || uname -s)

Installation Configuration:
  - RouterOS Version: $ROUTEROS_VERSION
  - Target Disk: /dev/$target_disk
  - Admin Password: [SET]
  - Network Interface: $interface

Network Configuration:
EOF

    if [ "$USE_DHCP" = "yes" ]; then
        echo "  - IP Configuration: DHCP"
    else
        echo "  - Current IP: ${current_ip:-DHCP}"
        echo "  - Current Gateway: ${current_gw:-auto}"
        if [ -n "$STATIC_IP" ]; then
            echo "  - New IP: $STATIC_IP"
            echo "  - New Gateway: $GATEWAY"
        else
            echo "  - IP Mode: Keep current static config"
        fi
    fi
    
    echo "  - DNS Servers: ${DNS_SERVERS:-1.1.1.1,1.0.0.1}"
    
    cat << EOF

Installation Steps:
  1. Install required packages (qemu-utils, pv, wget, unzip, etc.)
  2. Download RouterOS CHR v${ROUTEROS_VERSION}
  3. Convert and prepare CHR image
  4. Configure network settings and admin password
  5. Extend filesystem to use full disk
  6. Write CHR image to /dev/$target_disk
  7. Reboot system into RouterOS CHR

WARNING: This will completely destroy the current operating system!
Use --force to execute the installation without confirmation prompts.

EOF
}

# Parse command line arguments
ADMIN_PASSWORD=""
ROUTEROS_VERSION="7.19.4"
TARGET_DISK=""
STATIC_IP=""
GATEWAY=""
DNS_SERVERS=""
USE_DHCP="no"
FORCE_INSTALL="no"
DRY_RUN="no"

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version)
            ROUTEROS_VERSION="$2"
            CHR_IMAGE_URL="https://download.mikrotik.com/routeros/${ROUTEROS_VERSION}/chr-${ROUTEROS_VERSION}.img.zip"
            shift 2
            ;;
        -d|--disk)
            TARGET_DISK="$2"
            shift 2
            ;;
        -i|--ip)
            STATIC_IP="$2"
            shift 2
            ;;
        -g|--gateway)
            GATEWAY="$2"
            shift 2
            ;;
        -n|--dns)
            DNS_SERVERS="$2"
            shift 2
            ;;
        --dhcp)
            USE_DHCP="yes"
            shift
            ;;
        --force)
            FORCE_INSTALL="yes"
            shift
            ;;
        --dry-run)
            DRY_RUN="yes"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [ -z "$ADMIN_PASSWORD" ]; then
                ADMIN_PASSWORD="$1"
            else
                print_error "Too many arguments"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$ADMIN_PASSWORD" ]; then
    print_error "Admin password is required"
    show_usage
    exit 1
fi

# Validate password strength
if [ ${#ADMIN_PASSWORD} -lt 6 ]; then
    print_error "Password must be at least 6 characters long"
    exit 1
fi

# Main execution
main() {
    print_info "MikroTik RouterOS CHR Auto-Installer"
    log "Installation started by user: $(whoami)"
    
    # Pre-flight checks
    check_root
    check_environment
    
    # Detect system configuration
    local network_config=$(detect_network_config)
    IFS='|' read -r interface current_ip current_gw current_dns <<< "$network_config"
    
    if [ -z "$TARGET_DISK" ]; then
        TARGET_DISK=$(detect_target_disk)
    fi
    
    # Validate network configuration
    if [ "$USE_DHCP" != "yes" ] && [ -n "$STATIC_IP" ]; then
        if [ -z "$GATEWAY" ]; then
            print_error "Gateway is required when using static IP"
            exit 1
        fi
    fi
    
    # Show dry run if requested
    if [ "$DRY_RUN" = "yes" ]; then
        show_dry_run "$ADMIN_PASSWORD" "$TARGET_DISK" "$network_config"
        exit 0
    fi
    
    # Final confirmation
    if [ "$FORCE_INSTALL" != "yes" ]; then
        cat << EOF

=== FINAL CONFIRMATION ===
This will install MikroTik RouterOS CHR v${ROUTEROS_VERSION}
Target disk: /dev/$TARGET_DISK
Network interface: $interface

WARNING: This will COMPLETELY DESTROY your current operating system!
All data on /dev/$TARGET_DISK will be permanently lost!

EOF
        echo -n "Are you absolutely sure? Type 'yes' to continue: "
        read -r confirm
        if [ "$confirm" != "yes" ]; then
            print_info "Installation cancelled"
            exit 0
        fi
    fi
    
    # Execute installation
    log "Starting automated MikroTik CHR installation"
    
    install_dependencies
    download_chr_image
    prepare_chr_image
    configure_chr_network "$ADMIN_PASSWORD" "$STATIC_IP" "$GATEWAY" "$DNS_SERVERS" "$USE_DHCP" "$interface"
    extend_chr_filesystem
    write_chr_to_disk "$TARGET_DISK"
}

# Run main function
main