## ---------------------------------------------
## Scritp to install arch-linux on LUKS encrypted btrfs drive
## Features (hopefully): 
##	FIDO2 LUKS unlock
##	FIDO2 PAM for paswordless sudo
##	Install fully configured system with Sway and dotfiles
##
## TODO:
##	Everything, man!
##	Configurable via cmdline options?
## WONTDO:
##	Different partitioning schemes
##	Different WM and so on
##	Non-UEFI install (don't even try, script wont work!)
##
## Auhtor: Jan Hrubes, 2021
## ----------------------------------------------


## Some control variables
FIDO2_DISABLE=false
IPV6_DISABLE=true				## For those of us who have borked ipv6... (-_-)

KEYMAP="cz-qwertz" 				## Keymap for passphrases
USERSW="networkmanager vim git openssh"
BASICUTILS="btrfs-progs man-db man-pages texinfo libfido2"
INSTALLSW="${USERSW} ${BASICUTILS}"
## ----------------------------------------------

## Trap on fail and clean after ourselves
clean_on_fail () {
	umount -A --recursive /mnt/*
	umount /mnt
	umount /mnt/boot
	cryptsetup close /dev/mapper/cryptroot
	exit 1
}

trap clean_on_fail ERR
trap clean_on_fail SIGINT

## Some utility functions
get_valid_input(){

	echo ${1} ${2} >&2
	Prompt=$( ${1} | tee /dev/tty)
	Input="?"

	while ! [[ $(grep ${Input} <<< ${Prompt} 2>/dev/null) ]]; do
		echo "Please set "${2} >&2
		read Input
		[[ $(grep ${Input} <<< ${Prompt} 2>/dev/null) ]] || echo "Wrong "${2} >&2
	done

	echo ${Input}
}
## ----------------------------------------------

## Main functions

## Check connection, if not online, try to connect to wi-fi.
## (We presume that we have wireless card working)
net_connect () {
    [[ $IPV6_DISABLE ]] && sysctl net.ipv6.conf.all.disable_ipv6=1	## Disable IPv6 on demand before checking and setting internet connection

    Tries=0
    while ! [[ $(ping -c2 -q archlinux.org 2>/dev/null) ]]; do
	    echo "Internet connection not available, trying to connect to wi-fi"

	    WLAN=$(get_valid_input "iwctl device list" "wlan device name")

	    SSID=$(get_valid_input "iwctl station $WLAN get-networks" "SSID")

	    iwctl station ${WLAN} connect ${SSID}
	    sleep 1

	    let "Tries++"
	    if [[ $Tries -gt 3 ]]; then
	    echo "Cannot connect, please fix internet connection and run script again."
	    exit 1
	    fi
    done
}

## Prepare filesystems - partition disk, create cryptroot, format EFI partition
## and prepare btrfs with subvolumes. Then mount all.
prepare_filesystem () {
    ## show lsblk, select where to partition
    INSTALL_PARTITION="/dev/"$(get_valid_input "lsblk -d" "block device to install")
    CRYPT_PARTITION=${INSTALL_PARTITION}p2
    BOOT_PARTITION=${INSTALL_PARTITION}p1

    ## Partition disk, i dont care about other partitioning schemes or encrypted boot. Swapping to a swapfile.
    parted ${INSTALL_PARTITION} mklabel gpt
    parted ${INSTALL_PARTITION} mkpart EFI fat32 0% 512MB
    parted ${INSTALL_PARTITION} set 1 esp
    parted ${INSTALL_PARTITION} mkpart LUKS 512MB 100%

    ## Prepare LUKS2 encrypted root
    echo "Preparing encrypted volume"
    [[ ${FIDO2_DISABLE} ]] || echo "No need to set strong passphrase, it will later be replaced by FIDO2 token and recovery key"
    cryptsetup luksFormat ${CRYPT_PARTITION}
    cryptsetup open ${CRYPT_PARTITION} cryptroot

    ## format root partition, prepare btrfs subvolumes
    mkfs.btrfs -L root /dev/mapper/cryptroot
    mount /dev/mapper/cryptroot /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@pacman_cache
    btrfs subvolume create /mnt/@swap
    umount /mnt

    ## Format /boot partition
    mkfs.fat -F 32 ${BOOT_PARTITION}

    ## Mount all prepared partitions
    mkdir -p /mnt/boot
    mount ${BOOT_PARTITION} /mnt/boot
    mount -o subvol=@ /dev/mapper/cryptroot /mnt
    mkdir -p /mnt/home
    mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
    mkdir -p /mnt/.snapshots
    mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
    mkdir -p /mnt/var/cache/pacman/pkg
    mount -o subvol=@pacman_cache /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
    mkdir -p /mnt/swap
    mount -o subvol=@swap /dev/mapper/cryptroot /mnt/swap
}

## Create user - ask for username (if not provided in variable) and password
create_user () {
	echo "We need to create non-root user."
	if [[ -z ${USERNAME} ]]; then
		Confirm=""
		while ! [[ ${Confirm} == "y" ]]; do
			echo "Please set username:"
			read USERNAME
			echo "is "${USERNAME}" correct? y/n"
			read Confirm
		done
	fi
	useradd -m -s /bin/bash ${USERNAME}
	echo "Set password for "${USERNAME}
	passwd ${USERNAME}
}
## ----------------------------------------------

## Main script flow

## Keymap 
loadkeys ${KEYMAP}

net_connect

## Set time via ntp
timedatectl set-ntp true

prepare_filesystem

## Install base system + defined utils
pacstrap /mnt base linux linux-firmware ${INSTALLSW}

## we can create fstab now
genfstab -U /mnt >> /mnt/etc/fstab

## Chroot to new install
arch-chroot /mnt

## Enroll fido2 key to cryptsetup (if we are using one)
[[ ${FIDO2_DISABLE} ]] || systemd-cryptenroll --fido2-device=auto ${CRYPT_PARTITION}
## and generate recovery key
[[ ${FIDO2_DISABLE} ]] || systemd-cryptenroll --recovery-key ${CRYPT_PARTITION}

## update /etc/mkinitcpio.conf - add hooks
## create /etc/crypttab.initramfs , add cryptrrot by UUID
## mkinitcpio -P

## install grub, config grub

create_user

exit

## before reboot, make sure to remove old passphrase from cryptroot if using FIDO2 token.
[[ ${FIDO2_DISABLE} ]] || cryptsetup luksRemoveKey ${CRYPT_PARTITION}

## We should have working system, lets try to go for it. = D
# reboot 
