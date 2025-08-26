#!/bin/bash

# MikroTik RouterOS CHR Installation Script for Ubuntu
# This script installs MikroTik RouterOS CHR on Ubuntu systems
# WARNING: This will overwrite the target disk completely!

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
ROUTEROS_VERSION="7.19.4"
CHR_IMAGE_URL="https://download.mikrotik.com/routeros/${ROUTEROS_VERSION}/chr-${ROUTEROS_VERSION}.img.zip"
TEMP_DIR="/tmp/mikrotik_install"
NBD_DEVICE="/dev/nbd0"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 <PASSWORD> <SERVICE> [OPTIONS]

Arguments:
  PASSWORD    Admin password for MikroTik RouterOS
  SERVICE     Service type (must be one of: Mikrotik, mikrotik, "Mikrotik CHR")

Options:
  -v VERSION  RouterOS version (default: ${ROUTEROS_VERSION})
  -d DISK     Target disk (auto-detected if not specified)
  -y          Skip confirmation prompts (dangerous!)
  -h          Show this help

Example:
  $0 "mypassword" "Mikrotik"
  $0 "mypassword" "Mikrotik CHR" -v 7.20.1 -d sda

WARNING: This script will completely overwrite the target disk!
EOF
}

# Function to cleanup on exit
cleanup() {
    local exit_code=$?
    print_info "Cleaning up..."
    
    # Unmount if mounted
    if mountpoint -q /mnt 2>/dev/null; then
        umount /mnt 2>/dev/null || true
    fi
    
    # Disconnect NBD
    if [ -b "$NBD_DEVICE" ]; then
        qemu-nbd -d "$NBD_DEVICE" 2>/dev/null || true
    fi
    
    # Remove temp directory
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
    
    if [ $exit_code -ne 0 ]; then
        print_error "Script failed with exit code $exit_code"
    fi
    
    exit $exit_code
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Function to validate service type
validate_service() {
    local service="$1"
    local valid_services=("Mikrotik" "mikrotik" "Mikrotik CHR")
    
    for valid in "${valid_services[@]}"; do
        if [ "$service" = "$valid" ]; then
            return 0
        fi
    done
    
    print_error "Invalid service type: $service"
    print_error "Valid options: ${valid_services[*]}"
    exit 1
}

# Function to detect network interface
detect_network_interface() {
    local interface
    
    # Try to find the default route interface
    interface=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    
    if [ -z "$interface" ]; then
        # Fallback to first non-loopback interface
        interface=$(ip link show | awk -F': ' '/^[0-9]+: [^lo]/ {print $2}' | head -n1)
    fi
    
    if [ -z "$interface" ]; then
        print_error "Could not detect network interface"
        exit 1
    fi
    
    echo "$interface"
}

# Function to detect target disk
detect_target_disk() {
    local disk
    disk=$(lsblk -d -n -o NAME | grep -E '^(sda|vda|nvme0n1)$' | head -n1)
    
    if [ -z "$disk" ]; then
        print_error "Could not detect target disk"
        print_error "Available disks:"
        lsblk -d -n -o NAME,SIZE,TYPE
        exit 1
    fi
    
    echo "$disk"
}

# Function to check disk safety
check_disk_safety() {
    local disk="$1"
    local disk_path="/dev/$disk"
    
    if [ ! -b "$disk_path" ]; then
        print_error "Disk $disk_path does not exist"
        exit 1
    fi
    
    # Check if disk is mounted
    if mount | grep -q "^$disk_path"; then
        print_error "Disk $disk_path is currently mounted"
        print_error "Mounted partitions:"
        mount | grep "^$disk_path"
        exit 1
    fi
    
    # Check disk size (should be at least 1GB)
    local size_bytes
    size_bytes=$(lsblk -b -d -n -o SIZE "$disk_path")
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))
    
    if [ "$size_gb" -lt 1 ]; then
        print_error "Disk $disk_path is too small (${size_gb}GB). Minimum 1GB required."
        exit 1
    fi
    
    print_info "Target disk: $disk_path (${size_gb}GB)"
}

# Function to install required packages
install_dependencies() {
    print_info "Installing required packages..."
    
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        qemu-utils \
        pv \
        wget \
        unzip \
        e2fsprogs \
        util-linux
}

# Function to download and prepare CHR image
prepare_chr_image() {
    print_info "Downloading RouterOS CHR v${ROUTEROS_VERSION}..."
    
    mkdir -p "$TEMP_DIR"
    cd "$TEMP_DIR"
    
    # Download CHR image
    if ! wget -q --show-progress "$CHR_IMAGE_URL" -O chr.img.zip; then
        print_error "Failed to download CHR image"
        exit 1
    fi
    
    # Extract image
    print_info "Extracting CHR image..."
    if ! unzip -q chr.img.zip; then
        print_error "Failed to extract CHR image"
        exit 1
    fi
    
    # Convert to qcow2 and resize
    print_info "Converting and resizing image..."
    qemu-img convert "chr-${ROUTEROS_VERSION}.img" -O qcow2 chr.qcow2
    qemu-img resize chr.qcow2 1G
}

# Function to configure CHR
configure_chr() {
    local password="$1"
    local interface="$2"
    
    print_info "Configuring CHR with network settings..."
    
    # Load NBD module
    modprobe nbd max_part=8
    
    # Connect qcow2 image via NBD
    qemu-nbd -c "$NBD_DEVICE" chr.qcow2
    sleep 2
    
    # Update partition table
    partprobe "$NBD_DEVICE"
    sleep 2
    
    # Mount CHR filesystem
    mkdir -p /mnt
    mount "${NBD_DEVICE}p2" /mnt
    
    # Get network configuration
    local address gateway
    address=$(ip addr show "$interface" | grep 'inet ' | awk '{print $2}' | head -n1)
    gateway=$(ip route show default | awk '{print $3}' | head -n1)
    
    if [ -z "$address" ] || [ -z "$gateway" ]; then
        print_error "Could not determine network configuration"
        exit 1
    fi
    
    print_info "Network config: IP=$address, Gateway=$gateway"
    
    # Create autorun script
    cat > /mnt/rw/autorun.scr << EOF
/ip address add address=$address interface=[/interface ethernet find where name=ether1]
/ip route add gateway=$gateway
/ip service disable telnet
/user set 0 name=admin password=$password
/ip dns set servers=1.1.1.1,1.0.0.1
/system package update install
EOF
    
    # Unmount
    umount /mnt
    
    # Extend partition
    print_info "Extending partition..."
    echo -e 'd\n2\nn\np\n2\n65537\n\nw\n' | fdisk "$NBD_DEVICE"
    
    # Check and resize filesystem
    e2fsck -f -y "${NBD_DEVICE}p2" || true
    resize2fs "${NBD_DEVICE}p2"
}

# Function to write image to disk
write_to_disk() {
    local target_disk="$1"
    local target_path="/dev/$target_disk"
    
    print_info "Writing CHR image to $target_path..."
    
    # Create compressed image
    mount -t tmpfs tmpfs /mnt
    pv "$NBD_DEVICE" | gzip > /mnt/chr-extended.gz
    
    # Disconnect NBD
    qemu-nbd -d "$NBD_DEVICE"
    sleep 1
    
    # Sync filesystem
    sync
    
    # Write to target disk
    print_info "Writing to disk (this may take several minutes)..."
    zcat /mnt/chr-extended.gz | pv > "$target_path"
    
    # Final sync
    sync
    sleep 2
    
    print_info "Installation completed successfully!"
    print_warn "System will reboot in 10 seconds..."
    
    # Countdown
    for i in {10..1}; do
        echo -n "$i "
        sleep 1
    done
    echo
    
    # Clean reboot
    print_info "Rebooting system..."
    /sbin/reboot
}

# Main function
main() {
    local password="$1"
    local service="$2"
    local target_disk="$3"
    local skip_confirm="$4"
    
    print_info "MikroTik RouterOS CHR Installation Script"
    print_info "Version: $ROUTEROS_VERSION"
    
    # Validate inputs
    validate_service "$service"
    
    # Detect network interface
    local interface
    interface=$(detect_network_interface)
    print_info "Detected network interface: $interface"
    
    # Detect or validate target disk
    if [ -z "$target_disk" ]; then
        target_disk=$(detect_target_disk)
        print_info "Auto-detected target disk: $target_disk"
    fi
    
    # Safety checks
    check_disk_safety "$target_disk"
    
    # Confirmation prompt
    if [ "$skip_confirm" != "yes" ]; then
        print_warn "WARNING: This will completely erase disk /dev/$target_disk!"
        print_warn "All data on this disk will be permanently lost!"
        echo -n "Are you sure you want to continue? (type 'yes' to confirm): "
        read -r confirm
        if [ "$confirm" != "yes" ]; then
            print_info "Installation cancelled by user"
            exit 0
        fi
    fi
    
    # Execute installation steps
    install_dependencies
    prepare_chr_image
    configure_chr "$password" "$interface"
    write_to_disk "$target_disk"
}

# Parse command line arguments
PASSWORD=""
SERVICE=""
TARGET_DISK=""
SKIP_CONFIRM="no"

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
        -y|--yes)
            SKIP_CONFIRM="yes"
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
            if [ -z "$PASSWORD" ]; then
                PASSWORD="$1"
            elif [ -z "$SERVICE" ]; then
                SERVICE="$1"
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
if [ -z "$PASSWORD" ] || [ -z "$SERVICE" ]; then
    print_error "Missing required arguments"
    show_usage
    exit 1
fi

# Check if running as root
check_root

# Run main function
main "$PASSWORD" "$SERVICE" "$TARGET_DISK" "$SKIP_CONFIRM"