#!/bin/bash

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

source ${SCRIPT_DIR}/common_functions.sh
source ${SCRIPT_DIR}/vars.sh

trap exit 1 ERR
trap exit 1 SIGINT

notify "all is well"
