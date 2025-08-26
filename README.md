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

### VPS Users (--force option)

The `--force` option bypasses the mounted disk safety check and implements VPS-specific optimizations, allowing installation on VPS systems where the target disk is the currently running system. **This is extremely dangerous** as it will completely destroy the running operating system.

**VPS-Specific Optimizations in --force mode:**
- Skips filesystem sync operations that can cause segmentation faults on VPS systems
- Uses direct disk write method (dd) for safer overwriting of the root disk
- Implements alternative buffer flushing to avoid system crashes
- Provides enhanced error handling for VPS environments

**Use --force only if:**
- You have console/recovery access to your VPS
- You have backed up all important data
- You understand that the system will be completely replaced
- You are prepared for potential system failure requiring manual recovery
- You have experienced segmentation faults with the standard installation method

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

### For VPS (Replace Ubuntu completely)

```bash
curl -fsSL https://raw.githubusercontent.com/ariaservice/mikrotik_on_ubuntu/master/install_mikrotik_on_ubuntu.sh | sudo bash
```

### For dedicated server with separate disk

```bash
curl -fsSL https://raw.githubusercontent.com/ariaservice/mikrotik_on_ubuntu/master/install_mikrotik_on_ubuntu.sh | sudo bash
```

## 📖 Usage

The script will automatically detect your network configuration and install MikroTik CHR with default settings. RouterOS will be configured with the default admin user and no password.

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
   - Password: No password (empty)

3. **First Steps**:
   - Change default configuration as needed
   - Update RouterOS: `/system package update install`
   - Configure firewall rules
   - Set up additional network interfaces

## 🐛 Troubleshooting

### Segmentation Fault During Installation

If you encounter segmentation faults during the installation process (especially during sync operations), this is typically caused by attempting to sync the filesystem while overwriting the root disk on VPS systems.

**Solution:** Use the `--force` option which implements VPS-specific optimizations:

```bash
curl -fsSL https://raw.githubusercontent.com/ariaservice/mikrotik_on_ubuntu/master/install_mikrotik_on_ubuntu.sh | sudo bash
```

The `--force` mode:
- Skips problematic sync operations
- Uses safer disk writing methods
- Implements alternative buffer management
- Provides better error handling for VPS environments

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
- For VPS installations, use the `--force` option

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