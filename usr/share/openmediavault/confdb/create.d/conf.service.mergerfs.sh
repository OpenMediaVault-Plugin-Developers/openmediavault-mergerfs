#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/mergerfs"; then
    omv_config_add_node "/config/services" "mergerfs"
    omv_config_add_node "/config/services/mergerfs" "pools"
fi
