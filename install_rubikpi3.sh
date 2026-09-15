#!/bin/bash

# Exit on errors, print commands, ignore unset variables
set -ex +u

cd /tmp/build
echo '=== Current directory: $(pwd) ==='
echo '=== Files in current directory: ==='
ls -la

# This fixes log spam from iris_vpu AKA msm_vidc
# See: https://github.com/rubikpi-ai/linux-debian/blob/0f0155ba6d6057a6a86162597f48c24e1a54d1a1/ubuntu/qcom/video/vidc/inc/msm_vidc_debug.h#L101
# and https://github.com/rubikpi-ai/linux-debian/blob/0f0155ba6d6057a6a86162597f48c24e1a54d1a1/ubuntu/qcom/video/vidc/src/msm_vidc_debug.c#L25
echo "options iris_vpu msm_fw_debug=0x18" > /etc/modprobe.d/iris_vpu.conf

ln -sf libOpenCL.so.1 /usr/lib/aarch64-linux-gnu/libOpenCL.so # Fix for snpe-tools

# silence log spam from dpkg
cat > /etc/apt/apt.conf.d/99dpkg.conf << EOF_DPKG
Dpkg::Progress-Fancy "0";
APT::Color "0";
Dpkg::Use-Pty "0";
EOF_DPKG


# Make sure all the sources are available for apt
cat > /etc/apt/sources.list.d/ubuntu.sources << EOF_UBUNTU_SOURCES
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF_UBUNTU_SOURCES

# diff /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources

apt-get -q update

# This needs to run before install.sh to fix some weird dependency issues
apt-get -y --allow-downgrades install libsqlite3-0=3.45.1-1ubuntu2

# Add the GPG key for the RUBIK Pi PPA
wget -qO - https://thundercomm.s3.dualstack.ap-northeast-1.amazonaws.com/uploads/web/rubik-pi-3/tools/key.asc | tee /etc/apt/trusted.gpg.d/rubikpi3.asc

# Remove extra packages to make space
echo "Space available before purging things"
df -h

# get rid of snaps
echo "Purging snaps"
rm -rf /var/lib/snapd/seed/snaps/*
rm -f /var/lib/snapd/seed/seed.yaml
apt-get purge --yes lxd-installer lxd-agent-loader snapd gdb gcc g++ linux-headers* libgcc*-dev perl-modules* git vim-runtime python3-twisted sosreport bluez
apt-get autoremove --yes

rm -rf /var/lib/apt/lists/*
apt-get clean

rm -rf /usr/share/doc
rm -rf /usr/share/locale/

echo "Space available after purging things"
df -h

# Run normal photon installer
chmod +x ./install.sh
./install.sh --control-networking=yes --arch=aarch64 --version="$1"

# Install packages from the RUBIK Pi PPA, we skip calling apt-get update here because install.sh already does that
apt-get -y install libqnn1 libsnpe1 qcom-adreno1 device-tree-compiler

# Enable ssh
systemctl enable ssh

# modify photonvision.service to run on A78 cores
sed -i 's/# AllowedCPUs=4-7/AllowedCPUs=4-7/g' /lib/systemd/system/photonvision.service
cp -f /lib/systemd/system/photonvision.service /etc/systemd/system/photonvision.service
chmod 644 /etc/systemd/system/photonvision.service
cat /etc/systemd/system/photonvision.service

# networkd isn't being used, this causes an unnecessary delay
systemctl disable systemd-networkd-wait-online.service

# set the hostname during cloud-init and disable cloud-init after first boot
cat >> /var/lib/cloud/seed/nocloud/user-data << EOFUSERDATA

hostname: photonvision

runcmd:
- nmcli radio all off
- touch /etc/cloud/cloud-init.disabled
EOFUSERDATA

# The Rubik Pi 3's two dwc3 USB ports enumerate as xhci-hcd.0.auto or
# xhci-hcd.1.auto in racy probe order, so a camera in either port gets a
# different by-path identity on each boot and PhotonVision can't match its
# saved config. These rules pin each physical port (identified by its fixed
# dwc3 MMIO address, not the racy xhci-hcd instance number) to a stable
# synthetic by-path name, and the helper script removes only that device's own
# racy by-path symlinks. Unlike the previous rule, this stays correct when two
# or more cameras are connected.
cat > /etc/udev/rules.d/67-camera-path-fix.rules << 'EOFUDEV'
# USB port on dwc3 @ 8c00000
SUBSYSTEM=="video4linux", KERNELS=="8c00000.usb", \
  SYMLINK+="v4l/by-path/platform-dwc3-8c00000-usb-0:1:1.0-video-index$attr{index}", \
  RUN+="/usr/local/sbin/rubik-camera-path-fix.sh $env{ID_PATH} $env{ID_PATH_WITH_USB_REVISION} $attr{index}"

# USB port on dwc3 @ a600000
SUBSYSTEM=="video4linux", KERNELS=="a600000.usb", \
  SYMLINK+="v4l/by-path/platform-dwc3-a600000-usb-0:1:1.0-video-index$attr{index}", \
  RUN+="/usr/local/sbin/rubik-camera-path-fix.sh $env{ID_PATH} $env{ID_PATH_WITH_USB_REVISION} $attr{index}"
EOFUDEV

cat > /usr/local/sbin/rubik-camera-path-fix.sh << 'EOF_PATH_FIX'
#!/bin/sh
# Called by /etc/udev/rules.d/67-camera-path-fix.rules for cameras on the
# Rubik Pi 3's dwc3 USB ports. Removes only the racy per-boot xhci-hcd.N.auto
# by-path symlinks belonging to the device that triggered this event, so
# cameras on other ports are never touched.
# Args: <ID_PATH> <ID_PATH_WITH_USB_REVISION> <video index>
id_path=${1:-}
id_path_usb_rev=${2:-}
index=${3:-}

[ -n "$id_path" ] || exit 0

case "$id_path" in
    platform-xhci-hcd.*)
        /bin/rm -f "/dev/v4l/by-path/${id_path}-video-index${index}" \
                   "/dev/v4l/by-path/${id_path_usb_rev}-video-index${index}"
        ;;
esac

exit 0
EOF_PATH_FIX
chmod +x /usr/local/sbin/rubik-camera-path-fix.sh

# Override the automatic fan control and set it to run continuously at full speed
# Instructions provided by Rami

# 1. Disable the thermal service
systemctl disable oem-tangshan-rubikpi3-thermal.service

# 2. Create the fan helper script
cat > /usr/local/sbin/rubik-fan-max.sh << EOF_MAX_FAN
#!/bin/sh
hwmon_dir=$(readlink -f /sys/devices/platform/pwm-fan/hwmon/hwmon*)
echo 0 > "$hwmon_dir/pwm1_enable"
echo 255 > "$hwmon_dir/pwm1"
EOF_MAX_FAN

chmod +x /usr/local/sbin/rubik-fan-max.sh

# 3. Add a oneshot systemd unit
cat > /etc/systemd/system/rubik-fan-max.service << EOF_FAN_SERVICE
[Unit]
Description=Force Rubik Pi fan to full speed
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rubik-fan-max.sh

[Install]
WantedBy=multi-user.target
EOF_FAN_SERVICE

# 4. Enable the new service
systemctl enable rubik-fan-max.service

echo "Space available before purging things"
df -h /dev/loop0

rm -rf /var/lib/apt/lists/*
df -h /dev/loop0

apt-get clean
df -h /dev/loop0

rm -rf /usr/share/doc
rm -rf /usr/share/locale/

# remove firmware that (probably) isn't needed
rm -rf /usr/lib/firmware/mrvl
rm -rf /usr/lib/firmware/mellanox
rm -rf /usr/lib/firmware/nvidia
rm -rf /usr/lib/firmware/intel

echo "Space available after purging things"
df -h /dev/loop0
