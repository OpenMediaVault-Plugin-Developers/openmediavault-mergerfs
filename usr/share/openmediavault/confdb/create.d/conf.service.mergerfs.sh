#!/bin/bash

set -e

declare -i count=0
declare -i count2=0
declare -i index=0
declare -i index2=0
declare -i import=0

. /usr/share/openmediavault/scripts/helper-functions

if ! omv_config_exists "/config/services/mergerfs"; then
    omv_config_add_node "/config/services" "mergerfs"
    omv_config_add_node "/config/services/mergerfs" "pools"
fi

# convert mergerfsfolder plugin pools
if omv_config_exists "/config/services/mergerfsfolders"; then
  count=$(omv_config_get_count "/config/services/mergerfsfolders/folder");
  index=1;
  while [ ${index} -le ${count} ]; do
    uuid=$(omv_config_get "/config/services/mergerfsfolders/folder[position()=${index}]/uuid")
    name=$(omv_config_get "/config/services/mergerfsfolders/folder[position()=${index}]/name")
    mntentref=$(omv_config_get "/config/services/mergerfsfolders/folder[position()=${index}]/mntentref")
    paths=$(omv_config_get "/config/services/mergerfsfolders/folder[position()=${index}]/paths")
    createpolicy=$(omv_config_get "/config/services/mergerfsfolders/folder[position()=${index}]/create_policy")
    minfreespace=$(omv_config_get "/config/services/mergerfsfolders/folder[position()=${index}]/min_free_space")
    options=$(omv_config_get "/config/services/mergerfsfolders/folder[position()=${index}]/options")
    paths2=""
    for path in ${paths}; do
      if [ -z "${paths2}" ]; then
        paths2="${path}"
      else
        paths2="${paths2}:${path}"
      fi
    done
    # make sure entry does not exist already
    if ! omv_config_exists "/config/services/mergerfs/pools/pool[uuid='${uuid}']"; then
      object="<uuid>${uuid}</uuid>"
      object="${object}<enable>1</enable>"
      object="${object}<name>${name}</name>"
      object="${object}<mntentref>${mntentref}</mntentref>"
      object="${object}<paths>${paths2}</paths>"
      object="${object}<createpolicy>${createpolicy}</createpolicy>"
      object="${object}<minfreespace>${minfreespace//[!0-9]/}</minfreespace>"
      object="${object}<minfreespaceunit>${minfreespace//[!KMGkmg]/}</minfreespaceunit>"
      object="${object}<options>${options}</options>"
      omv_config_add_node_data "/config/services/mergerfs/pools" "pool" "${object}"
    fi
    index=$(( index + 1 ))
  done
  omv_config_delete "/config/services/mergerfsfolders"
  import=1
fi


# convert unionfilesystems plugin pools
if omv_config_exists "/config/services/unionfilesystems"; then
  count=$(omv_config_get_count "/config/services/unionfilesystems/filesystem");
  index=1;
  while [ ${index} -le ${count} ]; do
    uuid=$(omv_config_get "/config/services/unionfilesystems/filesystem[position()=${index}]/uuid")
    name=$(omv_config_get "/config/services/unionfilesystems/filesystem[position()=${index}]/name")
    mntentref=$(omv_config_get "/config/services/unionfilesystems/filesystem[position()=${index}]/self_mntentref")

    count2=$(omv_config_get_count "/config/services/unionfilesystems/filesystem[position()=${index}]/mntentref");
    index2=1;
    paths=""
    while [ ${index2} -le ${count2} ]; do
      mntent=$(omv_config_get "/config/services/unionfilesystems/filesystem[position()=${index}]/mntentref[position()=${index2}]")
      path=$(omv_config_get "/config/system/fstab/mntent[uuid='${mntent}']/dir")
      if [ -d "${path}" ]; then
        if [ -z "${paths}" ]; then
          paths="${path}"
        else
          paths="${paths}:${path}"
        fi
      fi
      index2=$(( index2 + 1 ))
    done
    createpolicy=$(omv_config_get "/config/services/unionfilesystems/filesystem[position()=${index}]/create_policy")
    minfreespace=$(omv_config_get "/config/services/unionfilesystems/filesystem[position()=${index}]/min_free_space")
    options=$(omv_config_get "/config/services/unionfilesystems/filesystem[position()=${index}]/options")
    # make sure entry does not exist already
    if ! omv_config_exists "/config/services/mergerfs/pools/pool[uuid='${uuid}']"; then
      object="<uuid>${uuid}</uuid>"
      object="${object}<enable>1</enable>"
      object="${object}<name>${name}</name>"
      object="${object}<mntentref>${mntentref}</mntentref>"
      object="${object}<paths>${paths}</paths>"
      object="${object}<createpolicy>${createpolicy}</createpolicy>"
      object="${object}<minfreespace>${minfreespace//[!0-9]/}</minfreespace>"
      object="${object}<minfreespaceunit>${minfreespace//[!KMGkmg]/}</minfreespaceunit>"
      object="${object}<options>${options}</options>"
      omv_config_add_node_data "/config/services/mergerfs/pools" "pool" "${object}"
    fi
    index=$(( index + 1 ))
  done
  omv_config_delete "/config/services/unionfilesystems"
  import=1
fi

if [ ${import} -eq 1 ]; then
  # re-write fstab to remove mergerfs pools
  omv-salt deploy run fstab

  # create new mount files from imported pools
  omv-salt deploy run mergerfs
fi

exit 0
