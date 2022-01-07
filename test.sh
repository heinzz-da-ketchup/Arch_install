#!/bin/bash


source vars.sh
source common_functions.sh

trap exit 1 ERR
trap exit 1 SIGINT

notify "all is well"
