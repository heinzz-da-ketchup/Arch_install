#!/bin/bash

## ----------------------------------------------
## User-configurable variables
## ----------------------------------------------

## Some control variables
FIDO2_DISABLE=false
IPV6_DISABLE=true				## For those of us who have borked ipv6... (-_-)
SKIP_CREATE_FS=false
SKIP_MOUNT_FS=false
SKIP_PACSTRAP=false
SKIP_SWAPFILE=false
SKIP_HIBERNATE=false
SKIP_SECUREBOOT=false
ONLY_MOUNT=false				## DEBUG - Stop script after mounting filesystems

## Must be set here
CHROOT_PREFIX="arch-chroot /mnt"
KEYMAP="cz-qwertz" 				

USERSW="networkmanager vim git openssh"
BASICUTILS="btrfs-progs man-db man-pages texinfo libfido2 grub efibootmgr sudo sbsigntools"

## Script will ask or use defaults if empty
INSTALL_PARTITION=""		## As a full path, eg. "/dev/sdb"
USERNAME=""
HOSTNAME=""
BUILDDIR=""			## Path in install environment, eg "/mnt/path/to/file"
MOKDIR=""			## ---------------------- // ------------------------
SWAPFILE=""			## ---------------------- // ------------------------

## ----------------------------------------------
## Prepare rest of variables, set some sane defaults if needed
## ----------------------------------------------

if [[ -z ${BUILDDIR} ]]; then
	BUILDDIR="/mnt/home/${USERNAME}/builds"
	BUILDDIR_CHROOT="/home/${USERNAME}/builds"
else
	BUILDDIR_CHROOT=$(sed 's|/mnt||' <<< ${BUILDDIR})
fi

if [[ -z ${MOKDIR} ]]; then
	MOKDIR="/mnt/home/${USERNAME}/.mok"
	MOKDIR_CHROOT="/home/${USERNAME}/.mok"
else
	MOKDIR_CHROOT=$(sed 's|/mnt||' <<< ${MOKDIR})
fi

if [[ -z ${SWAPFILE} ]]; then
	SWAPFILE="/mnt/swap/swapfile"
fi

SWAPDIR=$(grep -o '.*/'<<< ${SWAPFILE})
INSTALLSW="${USERSW} ${BASICUTILS}"
