# MikroTik RouterOS CHR Installation Script

This script automates the installation of MikroTik RouterOS CHR (Cloud Hosted Router) on Ubuntu systems. It downloads, configures, and installs RouterOS directly to your system disk, converting your Ubuntu machine into a MikroTik router.

## ⚠️ **CRITICAL WARNING**

**THIS SCRIPT WILL COMPLETELY ERASE YOUR TARGET DISK AND ALL DATA ON IT!**

The installation process will:
- Overwrite the entire target disk
- Remove all existing partitions and data
- Install RouterOS as the primary operating system
- Reboot the system automatically

**Make sure you have backups of any important data before running this script!**

## 🔧 Requirements

### System Requirements
- Ubuntu 18.04 or newer
- Root privileges (sudo access)
- Internet connection for downloading RouterOS
- Minimum 1GB target disk space
- x86_64 architecture

### Dependencies
The script will automatically install these packages:
- `qemu-utils` - For image conversion and NBD support
- `pv` - For progress visualization
- `wget` - For downloading RouterOS image
- `unzip` - For extracting downloaded files
- `e2fsprogs` - For filesystem operations
- `util-linux` - For disk utilities

## 📥 Installation

### Direct Download and Install CHR
```bash
# Download and install MikroTik CHR directly
curl -fsSL https://raw.githubusercontent.com/ariaservice/mikrotik_on_ubuntu/master/install_mikrotik_on_ubuntu.sh | sudo bash -s -- "yourPassword" "Mikrotik CHR"
```

## 📖 Usage

Simply replace `"yourPassword"` with your desired admin password in the installation command above. The script will automatically detect your network configuration and install MikroTik CHR with default settings.

## 🔍 What the Script Does

1. **Validation Phase**
   - Checks root privileges
   - Validates input parameters
   - Detects network interface and target disk
   - Performs safety checks on target disk

2. **Preparation Phase**
   - Downloads RouterOS CHR image
   - Installs required dependencies
   - Extracts and converts image to qcow2 format
   - Resizes image to 1GB

3. **Configuration Phase**
   - Mounts CHR filesystem via NBD
   - Configures network settings (IP, gateway, DNS)
   - Sets admin password
   - Creates autorun script for first boot
   - Extends partition and filesystem

4. **Installation Phase**
   - Creates compressed disk image
   - Writes image to target disk
   - Syncs filesystem
   - Reboots system

## 🛡️ Safety Features

- **Disk Safety Checks**: Prevents installation on mounted disks
- **Size Validation**: Ensures target disk is at least 1GB
- **Network Validation**: Verifies network configuration before proceeding
- **Confirmation Prompts**: Requires explicit "yes" confirmation
- **Automatic Cleanup**: Cleans up temporary files on exit or failure
- **Error Handling**: Comprehensive error checking with colored output

## 🌐 Network Configuration

The script automatically configures RouterOS with:
- **IP Address**: Detected from current Ubuntu network interface
- **Gateway**: Detected from current default route
- **DNS Servers**: Set to 1.1.1.1 and 1.0.0.1 (Cloudflare)
- **Interface**: Configured on ether1 (first Ethernet interface)
- **Services**: Telnet disabled for security

## 🔧 Post-Installation

After installation and reboot:

1. **Access Methods**:
   - Web interface: `http://YOUR_IP_ADDRESS`
   - SSH: `ssh admin@YOUR_IP_ADDRESS`
   - WinBox: Connect to IP address

2. **Default Credentials**:
   - Username: `admin`
   - Password: The password you specified during installation

3. **First Steps**:
   - Change default configuration as needed
   - Update RouterOS: `/system package update install`
   - Configure firewall rules
   - Set up additional network interfaces

## 🐛 Troubleshooting

### Common Issues

**Script fails with "Permission denied"**
- Ensure you have sudo privileges
- Check your internet connection for downloading the script

**"Could not detect network interface"**
- Ensure you have an active network connection
- Check that your network interface is up: `ip link show`

**"Disk is currently mounted"**
- Unmount all partitions on target disk
- Use `lsblk` to check mounted partitions
- Unmount with: `sudo umount /dev/sdXN`

**Download fails**
- Check internet connection
- Verify RouterOS version exists

### Log Files
The script provides colored output:
- 🟢 **[INFO]** - Normal operation messages
- 🟡 **[WARN]** - Warning messages
- 🔴 **[ERROR]** - Error messages

## ⚖️ License & Disclaimer

**Use at your own risk!** This script:
- Will completely erase your target disk
- May cause data loss if used incorrectly
- Is provided as-is without warranty
- Requires MikroTik RouterOS license for commercial use

MikroTik RouterOS is a commercial product. Ensure you have appropriate licensing for your use case.

## 🤝 Contributing

To improve this script:
1. Test thoroughly in virtual machines first
2. Follow bash best practices
3. Add comprehensive error handling
4. Update documentation for any changes

## 📚 Additional Resources

- [MikroTik Official Documentation](https://help.mikrotik.com/)
- [RouterOS CHR Documentation](https://help.mikrotik.com/docs/display/ROS/CHR)
- [MikroTik Community Forum](https://forum.mikrotik.com/)
- [RouterOS Command Reference](https://help.mikrotik.com/docs/display/ROS/Command+Line+Interface)

---

**Remember: Always test in a virtual machine or non-production environment first!**