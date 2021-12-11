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
USERSW="networkmanager vim"
BASICUTILS="btrfs-progs man-db man-pages texinfo"
INSTALLSW="${USERSW} ${BASICUTILS}"

## Keymap (Do we need it? for install via script?)

## Check connection, if not online, try to connect to wi-fi.
## (We presume that we have wireless card working)
## Handling of empty input is slightly borked, I DONT CARE ANYMORE
get_wifi()

## Set time via ntp
timedatectl set-ntp true

## show lsblk, select where to partition
##### TODO #####

## Partition disk, i dont care about other partitioning schemes, encrypted boot, or swap
##### TODO: hibernate to locked swap file? how, dammit? #####
parted ${INSTALL_PARTITION} mklabel gpt
parted ${INSTALL_PARTITION} mkpart EFI fat32 0% 512MB
parted ${INSTALL_PARTITION} mkpart LUKS 512MB 100%

## Prepare LUKS2 encrypted root
cryptsetup luksFormat ${INSTALL_PARTITION}p2		    ## Enter some easy passphrase, will remove later
## Not yet? do this in chroot?  systemd-cryptenroll --fido2-devica=auto ${INSTALL_PARTITION}p2
cryptsetup open ${INSTALL_PARTITION}p2 cryptroot

## format root partition, prepare btrfs subvolumes
mkfs.btrfs -L root /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@pacman_cache
umount /mnt

## Format /boot partition
mkfs fat -F 32 /dev/${INSTALL_PARTITION}p1

## Mount all prepared partitions
mkdir /mnt/boot
mount /dev/${INSTALL_PARTITION}p1 /mnt/boot
mount -o subvol=@ /dev/mapper/cryptroot /mnt
mkdir /mnt/home
mount -o subvol=@home /dev/mapper/cryptroot /mnt/home
mkdir /mnt/.snapshots
mount -o subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mkdir -p /mnt/var/cache/pacman/pkg
mount -o subvol=@pacman_cache /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg

## we can create fstab now
genfstab -U /mnt >> /mnt/etc/fstab

## Install base system + defined utils
pacstrap /mnt base linux linux-firmware ${INSTALLSW}


get_wifi () {
Tries=0
while ! [[ $(ping c2 -q archlinux.org 2>/dev/null) ]]; do
    echo "Internet connection not available, trying to connect to wi-fi"
    if [[ $(iwctl device list | grep wlan0) ]]; then
	Wlan="wlan0"
    else
	Wlan="?"
	Devices=$(iwctl device list | tee /dev/tty )
	while ! [[ $(grep ${Wlan} <<< ${Devices}) ]]; do
	    echo "Please set wlan device name"
	    read Wlan
	    [[ $(grep ${Wlan} <<< ${Devices}) ]] || echo "Wrong device name!\n"
	done
    fi

    SSID="?"
    SSIDS=$(iwctl station ${Wlan} get-networks | tee /dev/tty )
    while ! [[ $(grep ${SSID} <<< ${SSIDs}) ]]; do
	echo "Specify SSID to connect to"
	read SSID
	[[ $(grep ${SSID} <<< ${SSIDs}) ]] || echo "Wrong SSID!"
    done

    iwctl station ${Wlan} connect ${SSID}
    sleep 1

    let "Tries++"
    if [[ $Tries -gt 3 ]]; then
	echo "Cannot connect, please fix internet connection and run script again."
	exit 1
    fi
done
}
