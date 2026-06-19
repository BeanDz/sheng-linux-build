#!/bin/bash
set -e
IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"
LINUX_FIRMWARE_QCOM_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/qcom"

if [ $# -lt 2 ]; then exit 1; fi
if [ "$(id -u)" -ne 0 ]; then exit 1; fi

DISTRO=$1
KERNEL=$2
TARGET_MODE=${3:-all}
TARGET_FLAVOUR=${4:-all} 
CUSTOM_USER=${5:-xiaomi}
CUSTOM_PASS=${6:-123456}

distro_version="trixie"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

BOOTMODES=("$TARGET_MODE")
FLAVOURS=("$TARGET_FLAVOUR")

normalize_driver_layout() {
    local fw_base="rootdir/lib/firmware"
    local fw_dir src dst

    mkdir -p "$fw_base"
    for fw_dir in ath12k cirrus nanosic novatek qca qcom; do
        src="rootdir/usr/lib/$fw_dir"
        dst="$fw_base/$fw_dir"
        if [ -d "$src" ]; then
            mkdir -p "$dst"
            cp -a "$src/." "$dst/"
            rm -rf "$src"
        fi
    done

    local ath12k_dir="$fw_base/ath12k/WCN7850/hw2.0"
    if [ -f "$ath12k_dir/board-2.bin" ] && [ ! -f "$ath12k_dir/board.bin" ]; then
        cp "$ath12k_dir/board-2.bin" "$ath12k_dir/board.bin"
    fi
}

install_gpu_firmware() {
    local fw_dir="rootdir/lib/firmware/qcom"
    local fw_name fw_file

    mkdir -p "$fw_dir"
    for fw_name in a740_sqe.fw gmu_gen70200.bin; do
        fw_file="$fw_dir/$fw_name"
        if [ ! -s "$fw_file" ]; then
            curl -L --fail -o "$fw_file" "$LINUX_FIRMWARE_QCOM_URL/$fw_name"
        fi
    done
}

enable_driver_services() {
    if [ -f rootdir/usr/lib/systemd/system/adsprpcd-sensorspd.service ]; then
        chroot rootdir systemctl enable adsprpcd-sensorspd.service || true
    fi
    if [ -f rootdir/usr/lib/systemd/system/iio-sensor-proxy.service ]; then
        mkdir -p rootdir/etc/systemd/system/multi-user.target.wants
        ln -sf /usr/lib/systemd/system/iio-sensor-proxy.service \
            rootdir/etc/systemd/system/multi-user.target.wants/iio-sensor-proxy.service
    fi
}

repack_firmware_deb() {
    local pkg="firmware-xiaomi-sheng.deb"
    local workdir fw_dir src dst

    [ -f "$pkg" ] || return 0
    command -v dpkg-deb >/dev/null 2>&1 || return 0

    workdir=$(mktemp -d)
    dpkg-deb -R "$pkg" "$workdir/pkg"
    mkdir -p "$workdir/pkg/lib/firmware"
    for fw_dir in ath12k cirrus nanosic novatek qca qcom; do
        src="$workdir/pkg/usr/lib/$fw_dir"
        dst="$workdir/pkg/lib/firmware/$fw_dir"
        if [ -d "$src" ]; then
            mkdir -p "$dst"
            cp -a "$src/." "$dst/"
            rm -rf "$src"
        fi
    done
    find "$workdir/pkg/usr/lib" -depth -type d -empty -delete 2>/dev/null || true
    dpkg-deb -b "$workdir/pkg" "$pkg"
    rm -rf "$workdir"
}

repack_alsa_deb() {
    local pkg="alsa-xiaomi-sheng.deb"
    local workdir pkgdir savedir

    [ -f "$pkg" ] || return 0
    command -v dpkg-deb >/dev/null 2>&1 || return 0

    workdir=$(mktemp -d)
    pkgdir="$workdir/pkg"
    savedir="$workdir/ucm2"
    dpkg-deb -R "$pkg" "$pkgdir"

    mkdir -p "$savedir/Xiaomi" "$savedir/conf.d/sm8550"
    cp -a "$pkgdir/usr/share/alsa/ucm2/Xiaomi/sheng" "$savedir/Xiaomi/"
    cp -a "$pkgdir/usr/share/alsa/ucm2/conf.d/sm8550/Xiaomi-Pad6SPro.conf" "$savedir/conf.d/sm8550/"

    rm -rf "$pkgdir/usr/share/alsa/ucm2"
    mkdir -p "$pkgdir/usr/share/alsa/ucm2"
    cp -a "$savedir/." "$pkgdir/usr/share/alsa/ucm2/"

    dpkg-deb -b "$pkgdir" "$pkg"
    rm -rf "$workdir"
}

cleanup_mounts() {
    fuser -k -9 -m rootdir 2>/dev/null || true
    sleep 2; umount -l rootdir/dev/pts 2>/dev/null || true
    umount -l rootdir/dev 2>/dev/null || true
    umount -l rootdir/proc 2>/dev/null || true
    umount -l rootdir/sys 2>/dev/null || true
    umount -l rootdir 2>/dev/null || true
    rm -rf rootdir
}
trap cleanup_mounts EXIT ERR INT TERM

for FLAVOUR in "${FLAVOURS[@]}"; do
    for MODE in "${BOOTMODES[@]}"; do
        ROOTFS_IMG="debian_${distro_version}_${FLAVOUR}_${MODE}_${TIMESTAMP}.img"
        cleanup_mounts; mkdir -p rootdir
        truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
        mkfs.ext4 -O ^metadata_csum "$ROOTFS_IMG"
        mount -o loop "$ROOTFS_IMG" rootdir

        debootstrap --arch=arm64 "$distro_version" rootdir http://deb.debian.org/debian/
        mount --bind /dev rootdir/dev; mount --bind /dev/pts rootdir/dev/pts
        mount -t proc proc rootdir/proc; mount -t sysfs sys rootdir/sys

        echo "nameserver 8.8.8.8" > rootdir/etc/resolv.conf
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y --no-install-recommends systemd sudo vim wget curl network-manager openssh-server wpasupplicant dbus locales dialog"

        sed -i 's/^# *\(en_US.UTF-8\)/\1/' rootdir/etc/locale.gen
        sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' rootdir/etc/locale.gen
        chroot rootdir locale-gen
        echo "LANG=zh_CN.UTF-8" > rootdir/etc/default/locale
        echo "LANG=zh_CN.UTF-8" > rootdir/etc/locale.conf
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y fonts-noto-cjk fonts-wqy-microhei fcitx5 fcitx5-chinese-addons"

        if ls *.deb 1> /dev/null 2>&1; then
            repack_alsa_deb
            repack_firmware_deb
            cp *.deb rootdir/tmp/
            chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y libglib2.0-0 libprotobuf-c1 libqmi-glib5 libmbim-glib4 initramfs-tools kmod qrtr-tools"
            chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y /tmp/*.deb"
            normalize_driver_layout
            install_gpu_firmware
            enable_driver_services
            KERNEL_MODULE_DIR=$(find rootdir/lib/modules rootdir/usr/lib/modules -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | head -n 1)
            KERNEL_MODULE_DIR=${KERNEL_MODULE_DIR##*/}
            if [ -n "$KERNEL_MODULE_DIR" ]; then
                chroot rootdir /sbin/depmod -a "$KERNEL_MODULE_DIR"
            fi
        fi
        
        chroot rootdir bash -c "echo 'root:$CUSTOM_PASS' | chpasswd"
        echo "debian-$FLAVOUR-$MODE" > rootdir/etc/hostname

        chroot rootdir useradd -m -s /bin/bash "$CUSTOM_USER" || true
        chroot rootdir bash -c "echo '$CUSTOM_USER:$CUSTOM_PASS' | chpasswd"
        chroot rootdir groupadd -f render
        chroot rootdir usermod -aG sudo,audio,video,render,input "$CUSTOM_USER"

        if [ "$FLAVOUR" = "gnome" ]; then
            chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y gnome-shell gnome-session gnome-terminal gdm3"
            mkdir -p rootdir/etc/gdm3
            printf "[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=$CUSTOM_USER\n" > rootdir/etc/gdm3/daemon.conf
            chroot rootdir systemctl enable gdm3
        elif [ "$FLAVOUR" = "kde" ]; then
            chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y kde-standard sddm"
            mkdir -p rootdir/etc/sddm.conf.d
            printf "[Autologin]\nUser=$CUSTOM_USER\nSession=plasma\n" > rootdir/etc/sddm.conf.d/autologin.conf
            chroot rootdir systemctl enable sddm
        fi
        chroot rootdir systemctl enable NetworkManager qrtr-ns || true
        chroot rootdir systemctl set-default graphical.target

        [ "$MODE" = "dual" ] && echo "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1" > rootdir/etc/fstab || echo "PARTLABEL=userdata / ext4 defaults,noatime,errors=remount-ro 0 1" > rootdir/etc/fstab

        chroot rootdir apt-get clean; rm -f rootdir/tmp/*.deb
        cleanup_mounts; tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
        img2simg "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
        7z a "${ROOTFS_IMG%.img}.7z" "sparse_${ROOTFS_IMG}"
        rm -f "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
    done
done
trap - EXIT ERR INT TERM
