#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2017-present Team LibreELEC (https://libreelec.tv)

TMPDIR=.unpack.tmp
KERNEL=$1

if [ -z "${KERNEL}" ]; then
  echo "Script to synchronise this repo with the most suitable linux-firmware file for the specified kernel."
  echo
  echo "Run this script in the root of the iwlwifi-firmware repository."
  echo
  echo "Remember to delete ${TMPDIR} before committing changes!"
  echo
  echo "Usage: $0 <kernel version>"
  echo
  echo "  Example: $0 4.10.2"
  echo "  Example: $0 4.11-rc2"
  echo "  Example: DEBUG=y $0 4.11-rc2"
  echo
  echo "  DEBUG=y   - enable debug output"
  echo "  DRYRUN=y  - don't update filesystem"
  echo "  IPV4=y    - use only IPv4 for curl and git clone"
  exit 1
fi

[ -z "${IPV4}" ] && USEIPV4= || USEIPV4="-4"

function get_kernel_max()
{
  local filename device prefix kernel_max api_max
  local driver_path def_device
  
  driver_path=linux-${KERNEL}/drivers/net/wireless/intel/iwlwifi
  [ -d linux-${KERNEL}/drivers/net/wireless/intel/iwlwifi ] || driver_path=linux-${KERNEL}/drivers/net/wireless/iwlwifi

  # Config files moved to cfg subdir in 4.13-rc1
  [ -d ${driver_path}/cfg ] && driver_path+=/cfg

  while read -r filename; do
    def_device="$(basename ${filename} .c | tr '[:lower:]' '[:upper:]')"
    while read -r prefix; do
      device="$(echo "${prefix}" | awk -F- '{ print $2 }')"
      [ -z "${device}" ] && continue

      api_max="$(grep "^MODULE_FIRMWARE(IWL${device}_MODULE_FIRMWARE(.*))" ${filename} | sed 's/[()]/ /g' | awk '$3 ~ /.*_UCODE_API_MAX$/ {print $3}')"

      kernel_max=
      [ -n "${api_max}"    ] && kernel_max="$(grep "#define[[:space:]]*${api_max}" ${filename} | awk '{ print $3 }')"
      [ -z "${kernel_max}" ] && kernel_max="$(grep "#define[[:space:]]*IWL${device}_UCODE_API_MAX" ${filename} | awk '{ print $3 }')"
      [ -z "${kernel_max}" ] && kernel_max="$(grep "#define[[:space:]]*IWL${def_device}_UCODE_API_MAX" ${filename} | awk '{ print $3 }')"
      [ -z "${kernel_max}" ] && kernel_max="$(grep "#define[[:space:]]*IWL_${def_device}_UCODE_API_MAX" ${filename} | awk '{ print $3 }')"
      [ -n "${kernel_max}" ] || continue

      # since linux-6.5 the trailing dash was removed - add it back
      [[ "${prefix}" != *- ]] && prefix="${prefix}-"
      echo "${device} ${prefix} ${kernel_max}"
    done <<< "$(grep "#define[[:space:]]*IWL.*_FW_PRE[[:space:]]*\".*\"$" ${filename} | awk '{ print $3 }' | sed 's/"//g')"
  done <<< "$(ls -1 ${driver_path}/*.c)"
}

function get_firmwares()
{
  local directory="$1" prefix="$2"
  local firmware api

  (
    cd "${directory}"
    while read -r firmware; do
      api="${firmware#${prefix}}"
      api="${api%\.ucode}"
      echo "${api}"
    done <<< "$(ls -1 ${prefix}*.ucode 2>/dev/null)"
  ) | sort -k1nr | tr '\n' ',' | grep -v "^,$"
}

function sync_max_firmware()
{
  local device="$1" prefix="$2" kernel_max="$3"
  local linux_fw="$(get_firmwares linux-firmware "${prefix}")"
  local thisrepo="$(get_firmwares ../firmware "${prefix}")"
  local firmware keepver md5old md5new

  [ -z "${linux_fw}" -a -z "${thisrepo}" ] && return 0

  [ -n "${DEBUG}" ] && printf "DEBUG: %-6s %-15s kernel max=%-2s linux fw=%s this repo=%s\n" "${device}" "${prefix}" "${kernel_max}" "${linux_fw:0:-1}" "${thisrepo:0:-1}" >&2

  printf "%-25s - kernel max is %2d, linux-firmware max is %2d, this repo max is %2d\n" "${prefix:0:-1}" ${kernel_max} ${linux_fw%%,*} ${thisrepo%%,*}

  for firmware in ${linux_fw//,/ }; do
    if [ ${firmware} -le ${kernel_max} ]; then
      keepver=${firmware}
      if [ ! -f ../firmware/${prefix}${firmware}.ucode ]; then
        echo "  Adding new version  : ${prefix}${firmware}.ucode"
        [ -z "${DRYRUN}" ] && cp linux-firmware/${prefix}${firmware}.ucode ../firmware
      else
        md5old="$(md5sum ../firmware/${prefix}${firmware}.ucode | awk '{print $1}')"
        md5new="$(md5sum linux-firmware/${prefix}${firmware}.ucode | awk '{print $1}')"
        if [ "${md5old}" != "${md5new}" ]; then
          echo "  Updating existing version: ${prefix}${firmware}.ucode"
          [ -z "${DRYRUN}" ] && cp linux-firmware/${prefix}${firmware}.ucode ../firmware
        fi
      fi
      break
    fi
  done

  for firmware in ${thisrepo//,/ }; do
    [ "${firmware}" == "${keepver}" ] && continue

    if [ ${firmware} -gt ${kernel_max} ]; then
      echo "  Removing incompatible version: ${prefix}${firmware}.ucode"
      [ -z "${DRYRUN}" ] && rm -f ../firmware/${prefix}${firmware}.ucode
    elif [ -n "${keepver}" ]; then
      echo "  Removing old version: ${prefix}${firmware}.ucode"
      [ -z "${DRYRUN}" ] && rm -f ../firmware/${prefix}${firmware}.ucode
    else
      echo "  Unable to identify suitable max version - keeping existing firmware files"
    fi
  done
}

mkdir -p $TMPDIR || exit
cd $TMPDIR || exit

# unpack kernel
echo "Unpacking kernel ${KERNEL}..."
if [ ! -d linux-${KERNEL} ] ; then
  if [[ ${KERNEL} =~ .*-rc[0-9]* ]]; then
    url="http://www.kernel.org/pub/linux/kernel/v4.x/testing/linux-${KERNEL}.tar.xz"
    if ! curl --fail --head --location ${url} &>/dev/null; then
      url="https://git.kernel.org/torvalds/t/linux-${KERNEL}.tar.gz"
    fi
  else
    url="http://www.kernel.org/pub/linux/kernel/v${KERNEL:0:1}.x/linux-${KERNEL}.tar.xz"
  fi
  if [[ ${url} =~ .*.gz ]]; then
    curl ${USEIPV4} --location --progress-bar "${url}" | tar xzf -
  else
    curl ${USEIPV4} --location --progress-bar "${url}" | tar xJf -
  fi
  [ $? -eq 0 ] || exit 1
fi

# get kernel firmware
echo "Cloning latest linux-firmware from Intel Wireless Group..."
[ -d linux-firmware ] || git clone ${USEIPV4} git://git.kernel.org/pub/scm/linux/kernel/git/iwlwifi/linux-firmware.git --depth=1 || exit 1
[ $? -eq 0 ] || exit 1

echo "Synchronising repo with kernel and firmware..."
echo

while read -r device prefix kernel_max; do
  [ -n "{device}" -a -n "${prefix}" -a -n "${kernel_max}" ] && sync_max_firmware "${device}" "${prefix}" "${kernel_max}"
done <<< "$(get_kernel_max | sort -u | sort -k1n)"
