#!/bin/bash

SERVICE="Mikrotik CHR"  # Auto-set to CHR

echo "[INFO] Starting MikroTik CHR installation with force mode..."
echo "[INFO] Service: $SERVICE"
echo "[INFO] RouterOS will use default admin user with no password"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This script must be run as root"
    exit 1
fi

# Force mode warnings
echo "[WARN] FORCE MODE ENABLED - This will completely destroy the current system!"
echo "[WARN] All data will be permanently lost!"
echo "[WARN] Make sure you have console/recovery access!"
echo "[INFO] Starting installation in 5 seconds..."
sleep 5

interface=$(ls /sys/class/net | head -n 1)
DISK=$(lsblk -d -n -o NAME | grep -E '^(sda|vda)$')

echo "[INFO] Detected network interface: $interface"
echo "[INFO] Detected target disk: $DISK"
echo "[WARN] Target disk /dev/$DISK will be completely overwritten!"

echo "[INFO] Downloading MikroTik CHR 7.19.4..."
wget https://download.mikrotik.com/routeros/7.19.4/chr-7.19.4.img.zip -O chr.img.zip  && \
echo "[INFO] Extracting CHR image..." && \
gunzip -c chr.img.zip > chr.img  && \
echo "[INFO] Updating package lists..." && \
apt-get update && \
echo "[INFO] Installing required packages..." && \
DEBIAN_FRONTEND=noninteractive apt install -y qemu-utils pv && \
echo "[INFO] Converting image to qcow2 format..." && \
qemu-img convert chr.img -O qcow2 chr.qcow2 && \
echo "[INFO] Resizing image to 1GB..." && \
qemu-img resize chr.qcow2 1073741824 && \
echo "[INFO] Loading NBD module..." && \
modprobe nbd && \
echo "[INFO] Connecting image via NBD..." && \
qemu-nbd -c /dev/nbd0 chr.qcow2 && \
sleep 2 && \
echo "[INFO] Updating partition table..." && \
partprobe /dev/nbd0 && \
sleep 5 && \
echo "[INFO] Mounting CHR filesystem..." && \
mount /dev/nbd0p2 /mnt && \
echo "[INFO] Detecting network configuration..." && \
ADDRESS=`ip addr show $interface | grep global | cut -d' ' -f 6 | head -n 1` && \
GATEWAY=`ip route list | grep default | cut -d' ' -f 3` && \
echo "[INFO] Network config - IP: $ADDRESS, Gateway: $GATEWAY" && \
echo "/ip address add address=$ADDRESS interface=[/interface ethernet find where name=ether1]
/ip route add gateway=$GATEWAY
/ip service disable telnet
/ip dns set servers=1.1.1.1,1.0.0.1
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

/system package update install
 " > /mnt/rw/autorun.scr && \
echo "[INFO] Created autorun configuration" && \
umount /mnt && \
echo "[INFO] Extending partition..." && \
echo -e 'd\n2\nn\np\n2\n65537\n\nw\n' | fdisk /dev/nbd0 && \
echo "[INFO] Checking filesystem..." && \
e2fsck -f -y /dev/nbd0p2 || true && \
echo "[INFO] Resizing filesystem..." && \
resize2fs /dev/nbd0p2 && \
sleep 1 && \
echo "[INFO] Creating compressed image..." && \
mount -t tmpfs tmpfs /mnt && \
pv /dev/nbd0 | gzip > /mnt/chr-extended.gz && \
sleep 1 && \
echo "[INFO] Disconnecting NBD..." && \
killall qemu-nbd && \
sleep 1 && \
echo "[WARN] Syncing filesystem before disk write..." && \
echo u > /proc/sysrq-trigger && \
sleep 1 && \
echo "[INFO] Writing CHR image to /dev/$DISK (this will destroy the system)..." && \
zcat /mnt/chr-extended.gz | pv > /dev/$DISK && \
sleep 5 || true && \
echo "[INFO] Final sync and reboot..." && \
echo s > /proc/sysrq-trigger && \
echo b > /proc/sysrq-trigger