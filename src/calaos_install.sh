#!/bin/bash
# shellcheck disable=SC2034,SC2086

# Usage : install.sh [destination_disk]
set -e

NOCOLOR='\033[0m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LIGHTGRAY='\033[0;37m'
DARKGRAY='\033[1;30m'
LIGHTRED='\033[1;31m'
LIGHTGREEN='\033[1;32m'
YELLOW='\033[1;33m'
LIGHTBLUE='\033[1;34m'
LIGHTPURPLE='\033[1;35m'
LIGHTCYAN='\033[1;36m'
WHITE='\033[1;37m'

info()
{
    echo -e "${CYAN}$*${NOCOLOR}"
}

green()
{
    echo -e "${GREEN}$*${NOCOLOR}"
}

err()
{
    echo -e "${RED}$*${NOCOLOR}"
}

parse_cmdline()
{
    # Parse command line and LABEL variable
    set -- $(cat /proc/cmdline)
    for x in "$@"; do
        case "$x" in
            LABEL=*)
                eval "${x}"
            ;;
        esac
    done
}

#args: /dev/sda
get_dev_part_count()
{
    lsblk --json $1 | jq -r ".blockdevices[0].children | length"
}

#args: /dev/sda <partnum>
get_dev_part()
{
    part=$2
    lsblk --json $1 | jq -r ".blockdevices[0].children[$((part - 1))].name"
}

err_report() {
    err "Error on line $1"
}

trap 'err_report $LINENO' ERR

parse_cmdline

if [ $LABEL == "live-efi" ]; then
    info "--> Install in UEFI mode"
else
    info "--> Install in BIOS mode"
fi

info "--> Installing $2 on destination $1"

destination=$1
origin_rootfs=$(mount | grep "on \/ " | cut -d ' ' -f1)

# Deleting partition table
info "--> Deleting partition table on ${destination}"
dd if=/dev/zero of=${destination} bs=512 count=35 > /dev/null


if [ $LABEL == "live-efi" ]; then
    info "--> Creating GPT partition table"
    parted -s ${destination} mklabel gpt > /dev/null
    parted -s ${destination} mkpart "efi" fat32 1MiB 513MiB > /dev/null
    parted -s ${destination} mkpart "swap" linux-swap 513MiB 2.5GiB > /dev/null
    parted -s ${destination} mkpart "calaos" ext4 2.5GiB 100% > /dev/null
    parted -s ${destination} set 1 esp on > /dev/null
    parted -s ${destination} set 2 boot on > /dev/null
    parted -s ${destination} print

    destination_esp="/dev/$(get_dev_part ${destination} 1)"
    destination_swap="/dev/$(get_dev_part ${destination} 2)"
    destination_rootfs="/dev/$(get_dev_part ${destination} 3)"

    info "--> Formating partitions"
    mkfs.vfat -F32 ${destination_esp} > /dev/null
    mkswap ${destination_swap}
    mkfs.ext4 -F ${destination_rootfs}
else
    info "--> Creating Bios partition table"
    parted -s ${destination} mklabel msdos  > /dev/null
    parted -s ${destination} mkpart primary linux-swap 1MiB 2049MiB > /dev/null
    parted -s ${destination} mkpart primary ext4 2049MiB 100% > /dev/null
    parted -s ${destination} set 2 boot on > /dev/null
    parted -s ${destination} print

    destination_esp="/dev/$(get_dev_part ${destination} 2)"
    destination_swap="/dev/$(get_dev_part ${destination} 1)"
    destination_rootfs="/dev/$(get_dev_part ${destination} 2)"

    info "--> Formating partitions"
    mkswap ${destination_swap}
    mkfs.ext4 -F ${destination_rootfs}
fi

uuid_rootfs=$(blkid -s UUID -o value ${destination_rootfs})

info "--> Copy rootfs from live usb"
mkdir -p /mnt/origin_rootfs /mnt/destination_rootfs
mount ${origin_rootfs} /mnt/origin_rootfs
mount ${destination_rootfs} /mnt/destination_rootfs
rsync -ah --info=progress2 /mnt/origin_rootfs/ /mnt/destination_rootfs
rm -rf /mnt/destination_rootfs/.calaos-live
genfstab -U /mnt/destination_rootfs >> /mnt/destination_rootfs/etc/fstab



if [ $LABEL == "live-efi" ]; then
    info "--> Creating EFI partition"
    mkdir -p /mnt/destination_esp
    mount ${destination_esp} /mnt/destination_esp

    info "--> Copy Kernel and Initramfs"
    cp /boot/initramfs-linux.img  /mnt/destination_esp
    cp /boot/vmlinuz-linux /mnt/destination_esp
    bootctl --path /mnt/destination_esp install
    cat << EOF > /mnt/destination_esp/loader/loader.conf
default calaos.conf
timeout 1
console-mode max
editor yes
EOF

    cat << EOF > /mnt/destination_esp/loader/entries/calaos.conf
title   Calaos
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root="UUID=${uuid_rootfs}" rw
EOF
    umount /mnt/destination_esp
else
    info "--> Creating Boot partition"
    mkdir -p /mnt/destination_rootfs/syslinux
    cp /usr/lib/syslinux/bios/*.c32 /mnt/destination_rootfs/syslinux/
    extlinux --install /mnt/destination_rootfs/syslinux
    dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/bios/mbr.bin of=$destination
    info "--> Copy Kernel and Initramfs"
    # cp /boot/initramfs-linux.img /mnt/destination_rootfs/boot
    # cp /boot/vmlinuz-linux /mnt/destiation_rootfs/boot

    cat << EOF > /mnt/destination_rootfs/syslinux/syslinux.cfg
ALLOWOPTIONS 1
DEFAULT boot
TIMEOUT 10
PROMPT 0
ui vesamenu.c32
menu title Select kernel options and boot kernel
menu tabmsg Press [Tab] to edit, [Return] to select
menu background splash.lss

LABEL start
    MENU LABEL Start Calaos OS
    LINUX ../boot/vmlinuz-linux
    APPEND root="UUID=${uuid_rootfs}" rootwait rw quiet
    INITRD ../boot/initramfs-linux.img

LABEL hdt
	MENU LABEL Hardware Info
	COM32 hdt.c32

LABEL reboot
	MENU LABEL Reboot
	COM32 reboot.c32

LABEL poweroff
	MENU LABEL Power Off
	COM32 poweroff.c32
EOF

    cp /boot/syslinux/splash.lss /mnt/destination_rootfs/syslinux/
fi

info "--> Unmouting all partitions"
umount /mnt/destination_rootfs
umount /mnt/origin_rootfs

info "--> Check destination rootfs"
e2fsck -f ${destination_rootfs} -y

green "--> Installation successful, you can now reboot"
