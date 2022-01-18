#!/bin/bash

## ----------------------------------------------
## Common functions used in Arch_install scripts.
## ----------------------------------------------

## Colors! pretty, pretty colors! = )
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

## Some utility functions
notify () {

    printf ${GREEN}
    printf "\n##############################\n"
    printf "$1\n"
    printf "##############################\n\n"
    printf ${NC}
}

notify_wait () {

    printf ${GREEN}
    printf "\n##############################\n"
    printf "$1\n"
    printf "\nPress any key to continue\n"
    printf "##############################\n\n"
    printf ${NC}
    read -rsn 1
}

warn () {

    printf ${YELLOW}
    printf "\n##############################\n"
    printf "$1\n"
    printf "##############################\n\n"
    printf ${NC}
}

warn_wait () {

    printf ${YELLOW}
    printf "\n##############################\n"
    printf "$1\n"
    printf "\nPress any key to continue\n"
    printf "##############################\n\n"
    printf ${NC}
    read -rsn 1
}

error () {

    printf ${RED}
    printf "\n##############################\n"
    printf "$1\n"
    printf "##############################\n\n"
    printf ${NC}
    exit 1
}

## Ask for input and make user confirm it
## Argument #1 - string to use in prompt ("Please set $ARG", "Wrong $ARG")
get_valid_input (){

	Prompt=$( ${1} | tee /dev/tty)
	Input="?"

	printf ${GREEN} >/dev/tty
	printf "\n##############################\n" >/dev/tty

	while ! [[ $(grep -w ${Input} <<< ${Prompt}) ]]; do
		printf ${GREEN}"Please set ${2}\n"${NC} >/dev/tty
		read Input

		if ! [[ $(grep -w ${Input} <<< ${Prompt}) ]]; then
		    printf ${RED}"Wrong ${2}\n\n"${NC} >/dev/tty
		fi
	done

	printf ${GREEN} >/dev/tty
	printf "##############################\n\n" >/dev/tty
	printf ${NC} >/dev/tty

	echo ${Input}
}

## Ask for input, must be a part of an output of specified command
## Argument #1 - Command to use
## Argument #2 . String to use in prompt ("Please set $ARG")
get_confirmed_input () {

	Confirm=""
	printf ${GREEN} >/dev/tty
	printf "\n##############################\n" >/dev/tty

	while ! [[ ${Confirm} == "y" ]]; do
		printf ${GREEN}"Please set $1:\n"${NC} >/dev/tty
		read Input

		printf ${GREEN}"is \""${YELLOW}"${Input}"${GREEN}"\" correct? y/n \n"${NC} >/dev/tty
		read Confirm
	done

	printf ${GREEN} >/dev/tty
	printf "##############################\n\n" >/dev/tty
	printf ${NC} >/dev/tty

	echo ${Input}
}
