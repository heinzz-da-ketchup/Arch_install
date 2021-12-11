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
##	Different WM and so one
##	Non-UEFI install (don't even try, script wont work!)
##
## Auhtor: Jan Hrubes, 2021
## ----------------------------------------------


## Some control variables
KEYMAP="cz-qwertz" 				## Keymap for ease of data entry
FORCE_IPV6_DISABLE=true				## For those of us who have borked ipv6... (-_-)
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

## Keymap 
loadkeys $KEYMAP

## Check connection, if not online, try to connect to wi-fi.
## (We presume that we have wireless card working)
[[ $FORCE_IPV6_DISABLE ]] && sysctl net.ipv6.conf.all.disable_ipv6=1	## Disable IPv6 on demand before checking and setting internet connection

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

## Set time via ntp
timedatectl set-ntp true

## show lsblk, select where to partition
INSTALL_PARTITION="/dev/"$(get_valid_input "lsblk -d" "block device to install")
CRYPT_PARTITION=${INSTALL_PARTITION}p2
BOOT_PARTITION=${INSTALL_PARTITION}p1

## Partition disk, i dont care about other partitioning schemes, encrypted boot, or swap
parted ${INSTALL_PARTITION} mklabel gpt
##!!!!!!!!!!!!!!!!!!!!!! set EFI flag!!!!
parted ${INSTALL_PARTITION} mkpart EFI fat32 0% 512MB
parted ${INSTALL_PARTITION} mkpart LUKS 512MB 100%

## Prepare LUKS2 encrypted root
cryptsetup luksFormat ${CRYPT_PARTITION}		    ## Enter some easy passphrase, will remove later
cryptsetup open ${CRYPT_PARTITION} cryptroot

## format root partition, prepare btrfs subvolumes
mkfs.btrfs -L root /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@pacman_cache
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

## Install base system + defined utils
# pacstrap /mnt base linux linux-firmware ${INSTALLSW}

## we can create fstab now
#genfstab -U /mnt >> /mnt/etc/fstab

## Chroot to new install

## Enroll fido2 key to cryptsetup
## systemd-cryptenroll --fido2-device=auto ${CRYPT_PARTITION}

## update /etc/mkinitcpio.conf - add hooks
## create /etc/crypttab.initramfs , add cryptrrot by UUID
## mkinitcpio -P

## install grub, config grub

## passwd or new user

## before reboot, make sure to remove old passphrase from cryptroot!
## exit
## cryptsetup luksRemoveKey ${CRYPT_PARTITION}

##reboot! 
