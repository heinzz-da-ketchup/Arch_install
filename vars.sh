#!/bin/bash

## ----------------------------------------------
## User-configurable variables
## ----------------------------------------------

## Some control variables
FIDO2_DISABLE=true
IPV6_DISABLE=true				## For those of us who have borked ipv6... (-_-)
SKIP_CREATE_FS=false
SKIP_MOUNT_FS=false
SKIP_PACSTRAP=false
SKIP_SWAPFILE=false
SKIP_HIBERNATE=false
SKIP_UCODE=false
SKIP_SECUREBOOT=false
SKIP_FIREWALL=false
ONLY_MOUNT=false				## DEBUG - Stop script after mounting filesystems

## Must be set here
CHROOT_PREFIX="arch-chroot /mnt"
KEYMAP="cz-qwertz" 				

USERSW="networkmanager vim git openssh sway"
BASICUTILS="btrfs-progs man-db man-pages texinfo grub efibootmgr sudo sbsigntools polkit tlp tlp-rdw"

## Script will ask or use defaults if empty
INSTALL_PARTITION=""		## As a full path, eg. "/dev/sdb"
USERNAME=""
HOSTNAME=""
SSID=""
PSK=""
BUILDDIR=""			## Path in install environment, eg "/mnt/path/to/file"
MOKDIR=""			## ---------------------- // ------------------------
SWAPFILE=""			## ---------------------- // ------------------------

## Optional config
SAMBA_SHARES=""			## Space separated list of samba shares to add to fstab
SAMBA_USER=""			## If $SAMBA_SHARES are not empty, script will ask for username and PW
SAMBA_PW=""

## ----------------------------------------------
## Prepare rest of variables, set some sane defaults if needed - only if we are running the install script
## ----------------------------------------------

if [[ $0 =~ "install_arch_secure.sh" ]]; then
    ## Ask for user input if we need to
    if [[ -z ${INSTALL_PARTITION} ]]; then
	INSTALL_PARTITION="/dev/"$(get_valid_input "lsblk -d" "block device to install")   
    fi

    if [[ -z ${USERNAME} ]]; then 
	USERNAME=$(get_confirmed_input "username") 
    fi

    if [[ -z ${HOSTNAME} ]]; then 
	HOSTNAME=$(get_confirmed_input "hostname")
    fi

    if [[ -n ${SAMBA_SHARES} ]]; then
	[[ -z ${SAMBA_USER} ]] && SAMBA_USER=$(get_confirmed_input "Samba user")
	[[ -z ${SAMBA_PW} ]] && SAMBA_PW=$(get_confirmed_input "Password for samba user ${SAMBA_USER}")
    fi
fi

if [[ $0 =~ "config_archiso.sh" ]]; then
    ## Ask for user input if we need to

    if [[ -z ${USERNAME} ]]; then 
	USERNAME=$(get_confirmed_input "username") 
    fi
fi

## For others, we have sane defaults
if [[ -z ${BUILDDIR} ]]; then
	BUILDDIR="/mnt/home/${USERNAME}/builds"
fi

if [[ -z ${MOKDIR} ]]; then
	MOKDIR="/mnt/home/${USERNAME}/.mok"
fi

if [[ -z ${SWAPFILE} ]]; then
	SWAPFILE="/mnt/swap/swapfile"
fi

## Add needed packages if we are using FIDO2 token
if ! [[ ${FIDO2_DISABLE} == ture ]]; then
    BASICUTILS="${BASICUTILS} libfido2 pam-u2f"
fi

## Add needed packages if we are using samba shares
if [[ -n ${SAMBA_SHARES} ]]; then
    BASICUTILS="${BASICUTILS} cifs-utils"
fi

CRYPT_PARTITION=${INSTALL_PARTITION}p2
BOOT_PARTITION=${INSTALL_PARTITION}p1
SWAPDIR=$(grep -o '.*/'<<< ${SWAPFILE})
INSTALLSW="${USERSW} ${BASICUTILS}"
BUILDDIR_CHROOT=$(sed 's|/mnt||' <<< ${BUILDDIR})
MOKDIR_CHROOT=$(sed 's|/mnt||' <<< ${MOKDIR})
