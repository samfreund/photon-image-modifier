# Set variables

base_image=$1
script=$2

set -exv

# Install required packages
sudo apt-get update
sudo apt-get install -y qemu-user-static wget xz-utils
# If base_image ends with .yaml, treat it as a manifest and skip download
if [[ "$base_image" == *.yaml ]]; then
 
  # Download and process manifest
  wget -O manifest.yaml "${base_image}"

  echo "=== Manifest contents ==="
  cat manifest.yaml
  echo "========================="

  # Process each component using awk to extract URL and SHA256
  awk '/url:/ {
      sub(/.*url:[[:space:]]*/,"",$0);
      url=$0
       }
       /sha256sum:/ {
      sub(/.*sha256sum:[[:space:]]*/,"",$0);
      print url, $0
       }' manifest.yaml | while read -r url sha; do
    filename=$(basename "$url")
    echo "Downloading: $filename from $url"
    wget -nv -O "$filename" "$url"
    echo "$sha  $filename" | sha256sum -c -
  done

  echo "=== Downloaded files ==="
  ls -lh
  echo "========================"
elif [[ "$base_image" == *.tar.xz ]]; then
  # Directly download the tar.xz file
  wget -nv -O base_image.tar.xz "${base_image}"
  tar -xJvf base_image.tar.xz
else
  echo "Error: base_image must be a .yaml manifest or .tar.xz"
  exit 1
fi
# Find the rootfs image - look for the largest .img.xz file or one with "rootfs" in name
ROOTFS_IMG_XZ=""

# First try to find a file with "rootfs" in the name
for file in **/*.img.xz; do
  if [[ "$file" == *"rootfs"* ]]; then
    ROOTFS_IMG_XZ="$file"
    echo "Found rootfs image by name: $ROOTFS_IMG_XZ"
    break
  fi
done

# If not found, use the largest .img.xz file
if [ -z "$ROOTFS_IMG_XZ" ]; then
  ROOTFS_IMG_XZ=$(ls -S **/*.img.xz 2>/dev/null | head -n1)
  echo "Using largest .img.xz file as rootfs: $ROOTFS_IMG_XZ"
fi

if [ -z "$ROOTFS_IMG_XZ" ] || [ ! -f "$ROOTFS_IMG_XZ" ]; then
  echo "Error: Could not find a suitable rootfs image file"
  echo "Available files:"
  ls -la
  exit 1
fi

ROOTFS_IMG="${ROOTFS_IMG_XZ%.xz}"

echo "Extracting rootfs image: $ROOTFS_IMG_XZ"
xz -d "$ROOTFS_IMG_XZ"

if [ ! -f "$ROOTFS_IMG" ]; then
  echo "Error: Failed to extract $ROOTFS_IMG"
  exit 1
fi

echo "Using rootfs image: $ROOTFS_IMG"

# This uses a fixed offset for Ubuntu preinstalled server images
echo "=== Mounting rootfs with fixed offset (rpiimager method) ==="
mkdir -p ./rootfs

# Calculate offset: 4096 bytes/sector * 139008 sectors = 569,376,768 bytes
OFFSET=$((4096*139008))
echo "Using offset: $OFFSET bytes (sector 139008)"

sudo mount -o rw,loop,offset=$OFFSET "$ROOTFS_IMG" ./rootfs

if [ $? -ne 0 ]; then
  echo "Error: Failed to mount image with fixed offset"
  exit 1
fi

echo "=== Mount successful ==="
ls -la ./rootfs | head -20

# Check if this is a Canonical or Modified image (from rpiimager logic)
if [ -f "rootfs/etc/ImgType" ]; then
  cp rootfs/etc/ImgType ImgType
else
  echo "Canonical" > ImgType
fi
read ImgType < ImgType
echo "Image type: $ImgType"

# Expand image if it's a Canonical image (first time modification)
if [ "$ImgType" == "Canonical" ]; then
  echo "=== Marking image as CustomIDE ==="
  sudo chroot rootfs /bin/bash -c "
    touch /etc/ImgType
    echo 'CustomIDE' > /etc/ImgType
  "

  echo "=== Unmounting for expansion ==="
  sudo umount ./rootfs

  # Expand the image by 4GB (reduced from 10GB to fit GitHub Actions disk space)
  echo "=== Expanding image by 4GB ==="
  dd if=/dev/zero bs=1M count=4096 >> "$ROOTFS_IMG"

  # Remount after expansion
  echo "=== Remounting after expansion ==="
  sudo mount -o rw,loop,offset=$OFFSET "$ROOTFS_IMG" ./rootfs
elif [ "$ImgType" == "CustomIDE" ]; then
  echo "Image already customized, no expansion needed"
fi

rm -f ImgType

echo "=== Filesystem ready ==="

# Setup chroot environment
sudo mount -t proc proc rootfs/proc
sudo mount -t sysfs sysfs rootfs/sys
sudo mount -t tmpfs tmpfs rootfs/run
sudo mount --bind /dev rootfs/dev

# Setup DNS resolution in chroot
echo "=== Setting up DNS in chroot ==="
sudo rm -f rootfs/etc/resolv.conf
sudo cp /etc/resolv.conf rootfs/etc/resolv.conf
sudo cp /etc/hosts rootfs/etc/hosts

# Copy qemu static binaries for ARM emulation
sudo cp /usr/bin/qemu-arm-static rootfs/usr/bin/ || true
sudo cp /usr/bin/qemu-aarch64-static rootfs/usr/bin/ || true

# DEPRECATED: using bind mount instead
# Copy repository into chroot (excluding mounted directories and problematic files)
# sudo mkdir -p rootfs/tmp/build/
# sudo rsync -av --exclude=rootfs --exclude=.git --exclude=*.img --exclude=*.xz . rootfs/tmp/build/

# Mount and bind the current directory into /tmp/build in chroot
sudo mkdir -p rootfs/tmp/build/
sudo mount --bind "$(pwd)" rootfs/tmp/build/

# Install sudo in the chroot environment (needed by install scripts)
echo "=== Installing sudo in chroot ==="
sudo chroot rootfs /usr/bin/qemu-aarch64-static /bin/bash -c "set -exv && DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y sudo"

# Run the installation scripts in chroot with verbose output
echo "=== Running installation scripts in chroot ==="
sudo chroot rootfs /usr/bin/qemu-aarch64-static /bin/bash -c "
  set -exv
  export DEBIAN_FRONTEND=noninteractive
  echo '=== Making script executable ==='
  chmod +x ${script}
  echo '=== Running ${script} with arguments: ${@:3} ==='
  ./${script} ${@:3}
"

# Cleanup mounts
sudo umount rootfs/dev || true
sudo umount rootfs/run || true
sudo umount rootfs/sys || true
sudo umount rootfs/proc || true
sudo umount rootfs/tmp/build/ || true
sudo umount rootfs || true

# More aggressive loop device cleanup
if [ -n "$LOOP_DEV" ]; then
  sudo losetup -d "$LOOP_DEV" || true
fi

# Find and detach any remaining loop devices pointing to our image
sudo losetup -j "$ROOTFS_IMG" | cut -d: -f1 | xargs -r sudo losetup -d

# Ensure all filesystem operations are complete
sync
sleep 3

# Assembly process for remaining files
mkdir -p photonvision_rubikpi3
# Extract .tar.gz archive(s) directly into photonvision_rubikpi3 if they exist
if ls *.tar.gz 1>/dev/null 2>&1; then
  tar -xzf *.tar.gz -C photonvision_rubikpi3
fi
# Move all files (rawprogram, dtb, img) into photonvision_rubikpi3
mv rawprogram*.xml photonvision_rubikpi3/ 2>/dev/null || true
mv dtb.bin photonvision_rubikpi3/ 2>/dev/null || true
mv *.img photonvision_rubikpi3/ 2>/dev/null || true

# Flatten directory structure - move all files from subdirectories to photonvision_rubikpi3 root
find photonvision_rubikpi3 -mindepth 2 -type f -exec mv {} photonvision_rubikpi3/ \;
# Remove empty subdirectories
find photonvision_rubikpi3 -mindepth 1 -type d -empty -delete

# Set output for later steps
# Save the rootfs image path for later steps
echo "rootfs_image=$ROOTFS_IMG" >> $GITHUB_ENV
tar -cJf photonvision_rubikpi3.tar.xz -C . photonvision_rubikpi3
