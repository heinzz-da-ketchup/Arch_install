#!/bin/bash

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

source ${SCRIPT_DIR}/vars.sh
source ${SCRIPT_DIR}/common_functions.sh

trap exit 1 ERR
trap exit 1 SIGINT

CRYPT_PARTITION=${INSTALL_PARTITION}p2
BOOT_PARTITION=${INSTALL_PARTITION}p1

notify ${INSTALL_PARTITION}
notify ${CRYPT_PARTITION}
notify ${BOOT_PARTITION}

INSTALL_PARTITION="/dev/"$(get_valid_input "lsblk -d" "block device to install")

CRYPT_PARTITION=${INSTALL_PARTITION}p2
BOOT_PARTITION=${INSTALL_PARTITION}p1

notify ${INSTALL_PARTITION}
notify ${CRYPT_PARTITION}
notify ${BOOT_PARTITION}

notify "all is well"
