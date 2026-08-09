#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2017-present Team LibreELEC (https://libreelec.tv)

TMPDIR=.unpack.tmp
KERNEL=$1
CHANGED_FILES=()   # linux-firmware-relative paths, used for "Upstream commits" lookup
REPO_CHANGES=()    # "A:"/"M:"/"D:" + repo-relative path, used for git add/commit

# How much linux-firmware history to keep locally. This is re-fetched fresh
# each run (git fetch --depth=N), not accumulated, so repo size stays bounded
# regardless of how often you run this script. It needs to be deep enough to
# find the commit that last touched an infrequently-changed file; if it's
# not deep enough the commit-message lookup falls back to "unknown" rather
# than failing.
HISTDEPTH=${HISTDEPTH:-500}

# API numbering is Core+3.
#
# Standalone PNVM files are no longer required for the BZ and GL firmware
# families from Core 97 (API 100) onwards, as PNVM data is embedded in the
# firmware image. Documented upstream in:
#
#   b5b78dda06f9 ("iwlwifi: add Bz/gl FW for core97-84 release")
#   9440754a997a ("iwlwifi: add Bz/Fm and gl FW for core98-161 release")
#
# Both state: "Since core 97, pnvm files are no longer needed for those
# devices." This applies only to BZ/GL - other Intel firmware families
# (TY, SO, MA, etc.) still require standalone PNVM files.
PNVM_EMBED_API_MIN=100

function pnvm_embedded()
{
  local prefix="$1" api="$2"

  case "${prefix}" in
    iwlwifi-bz-*|iwlwifi-gl-*)
      [ "${api}" -ge "${PNVM_EMBED_API_MIN}" ]
      ;;
    *)
      return 1
      ;;
  esac
}

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
  echo "  DEBUG=y        - enable debug output"
  echo "  DRYRUN=y       - don't update filesystem, don't stage or commit"
  echo "  NOCOMMIT=y     - update filesystem but leave changes for manual add/commit"
  echo "  IPV4=y         - use only IPv4 for curl and git clone"
  echo "  HISTDEPTH=N    - linux-firmware history depth to fetch (default 500)"
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
    [ -n "${DEBUG}" ] && printf "DEBUG: reading filename %s\n" "${filename}" >&2
    def_device="$(basename ${filename} .c | sed 's/rf-//' | tr '[:lower:]' '[:upper:]')"
    while read -r prefix; do
      device="$(echo "${prefix}" | awk -F- '{ print $2 }')"
      [ -n "${DEBUG}" ] && printf "DEBUG: filename %s def_device %s prefix %s device %s\n" "${filename}" "${def_device}" "${prefix}" "${device}" >&2
      [ -z "${device}" ] && continue

      api_max="$(grep "^MODULE_FIRMWARE(IWL${device}_MODULE_FIRMWARE(.*))" ${filename} | sed 's/[()]/ /g' | awk '$3 ~ /.*_UCODE_API_MAX$/ {print $3}')"

      [ -n "${DEBUG}" ] && printf "DEBUG: filename %s def_device %s prefix %s device %s api_max %s\n" "${filename}" "${def_device}" "${prefix}" "${device}" "${api_max}" >&2
      kernel_max=
      [ -n "${api_max}"    ] && kernel_max="$(grep "#define[[:space:]]*${api_max}" ${filename} | awk '{ print $3 }')"
      [ -n "${DEBUG}" ] && printf "DEBUG: filename %s def_device %s prefix %s device %s api_max %s kernel_max %s\n" "${filename}" "${def_device}" "${prefix}" "${device}" "${api_max}" "${kernel_max}" >&2
      [ -z "${kernel_max}" ] && kernel_max="$(grep "#define[[:space:]]*IWL${device}_UCODE_API_MAX" ${filename} | awk '{ print $3 }')"
      [ -n "${DEBUG}" ] && printf "DEBUG: filename %s def_device %s prefix %s device %s api_max %s kernel_max %s\n" "${filename}" "${def_device}" "${prefix}" "${device}" "${api_max}" "${kernel_max}" >&2
      [ -z "${kernel_max}" ] && kernel_max="$(grep "#define[[:space:]]*IWL${def_device}_UCODE_API_MAX" ${filename} | awk '{ print $3 }')"
      [ -n "${DEBUG}" ] && printf "DEBUG: filename %s def_device %s prefix %s device %s api_max %s kernel_max %s\n" "${filename}" "${def_device}" "${prefix}" "${device}" "${api_max}" "${kernel_max}" >&2
      [ -z "${kernel_max}" ] && kernel_max="$(grep "#define[[:space:]]*IWL_${def_device}_UCODE_API_MAX" ${filename} | awk '{ print $3 }')"
      [ -n "${DEBUG}" ] && printf "DEBUG: filename %s def_device %s prefix %s device %s api_max %s kernel_max %s\n" "${filename}" "${def_device}" "${prefix}" "${device}" "${api_max}" "${kernel_max}" >&2
      # required to add 3 to CORE_MAX since linux-6.18
      [ -z "${kernel_max}" ] && kernel_max="$(grep "#define[[:space:]]*IWL_${def_device}_UCODE_CORE_MAX" ${filename} | awk '{ print $3 + 3 }')"
      [ -n "${DEBUG}" ] && printf "DEBUG: filename %s def_device %s prefix %s device %s api_max %s kernel_max %s\n" "${filename}" "${def_device}" "${prefix}" "${device}" "${api_max}" "${kernel_max}" >&2
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
      [[ ${api} =~ ^c[0-9]+ ]] && api=$((${api#c} + 3))
      echo "${api}"
    done <<< "$(ls -1 ${prefix}*.ucode 2>/dev/null)"
  ) | sort -k1nr | tr '\n' ',' | grep -v "^,$"
}

function sync_pnvm()
{
  local prefix="$1" keepver="$2"
  local pnvm_name="${prefix%-}.pnvm"
  local have="../firmware/${pnvm_name}"
  local src="linux-firmware/intel/iwlwifi/${pnvm_name}"
  local md5old md5new

  if [ -n "${keepver}" ] && ! pnvm_embedded "${prefix%-}" "${keepver}"; then
    # Standalone PNVM required - keep it in sync.
    if [ -f "${src}" ]; then
      if [ ! -f "${have}" ]; then
        echo "  Adding new PNVM file: ${pnvm_name}"
        [ -z "${DRYRUN}" ] && cp "${src}" "${have}"
        CHANGED_FILES+=("intel/iwlwifi/${pnvm_name}")
        REPO_CHANGES+=("A:firmware/${pnvm_name}")
      else
        md5old="$(md5sum "${have}" | awk '{print $1}')"
        md5new="$(md5sum "${src}" | awk '{print $1}')"
        if [ "${md5old}" != "${md5new}" ]; then
          echo "  Updating existing PNVM file: ${pnvm_name}"
          [ -z "${DRYRUN}" ] && cp "${src}" "${have}"
          CHANGED_FILES+=("intel/iwlwifi/${pnvm_name}")
          REPO_CHANGES+=("M:firmware/${pnvm_name}")
        fi
      fi
    fi
  else
    # PNVM is embedded in the firmware image.
    if [ -f "${have}" ]; then
      echo "  Removing obsolete PNVM file (embedded in firmware): ${pnvm_name}"
      [ -z "${DRYRUN}" ] && rm -f "${have}"
      REPO_CHANGES+=("D:firmware/${pnvm_name}")
    fi
  fi
}

function sync_max_firmware()
{
  local device="$1" prefix="$2" kernel_max="$3"
  local linux_fw="$(get_firmwares linux-firmware/intel/iwlwifi "${prefix}")"
  local thisrepo="$(get_firmwares ../firmware "${prefix}")"
  local firmware keepver md5old md5new

  [ -z "${linux_fw}" -a -z "${thisrepo}" ] && return 0

  [ -n "${DEBUG}" ] && printf "DEBUG: %-6s %-15s kernel max=%-2s linux fw=%s this repo=%s\n" "${device}" "${prefix}" "${kernel_max}" "${linux_fw:0:-1}" "${thisrepo:0:-1}" >&2

  printf "%-25s - kernel max is %2d, linux-firmware max is %2d, this repo max is %2d\n" "${prefix:0:-1}" ${kernel_max} ${linux_fw%%,*} ${thisrepo%%,*}

  for firmware in ${linux_fw//,/ }; do
    if [ ${firmware} -le ${kernel_max} ]; then
      keepver=${firmware}
      coreversion="c$((${firmware}-3))"
      if [ ! -f ../firmware/${prefix}${coreversion}.ucode ] &&
         [ ! -f ../firmware/${prefix}${firmware}.ucode ]; then
         if [ -f linux-firmware/intel/iwlwifi/${prefix}${coreversion}.ucode ]; then
            echo "  Adding new version  : ${prefix}${coreversion}.ucode"
            [ -z "${DRYRUN}" ] && cp linux-firmware/intel/iwlwifi/${prefix}${coreversion}.ucode ../firmware
            CHANGED_FILES+=("intel/iwlwifi/${prefix}${coreversion}.ucode")
            REPO_CHANGES+=("A:firmware/${prefix}${coreversion}.ucode")
         else
            echo "  Adding new version  : ${prefix}${firmware}.ucode"
            [ -z "${DRYRUN}" ] && cp linux-firmware/intel/iwlwifi/${prefix}${firmware}.ucode ../firmware
            CHANGED_FILES+=("intel/iwlwifi/${prefix}${firmware}.ucode")
            REPO_CHANGES+=("A:firmware/${prefix}${firmware}.ucode")
         fi
      elif [ -f ../firmware/${prefix}${coreversion}.ucode ]; then
        md5old="$(md5sum ../firmware/${prefix}${coreversion}.ucode | awk '{print $1}')"
        md5new="$(md5sum linux-firmware/intel/iwlwifi/${prefix}${coreversion}.ucode | awk '{print $1}')"
        if [ "${md5old}" != "${md5new}" ]; then
          echo "  Updating existing version: ${prefix}${coreversion}.ucode"
          [ -z "${DRYRUN}" ] && cp linux-firmware/intel/iwlwifi/${prefix}${coreversion}.ucode ../firmware
          CHANGED_FILES+=("intel/iwlwifi/${prefix}${coreversion}.ucode")
          REPO_CHANGES+=("M:firmware/${prefix}${coreversion}.ucode")
        fi
      else
        md5old="$(md5sum ../firmware/${prefix}${firmware}.ucode | awk '{print $1}')"
        md5new="$(md5sum linux-firmware/intel/iwlwifi/${prefix}${firmware}.ucode | awk '{print $1}')"
        if [ "${md5old}" != "${md5new}" ]; then
          echo "  Updating existing version: ${prefix}${firmware}.ucode"
          [ -z "${DRYRUN}" ] && cp linux-firmware/intel/iwlwifi/${prefix}${firmware}.ucode ../firmware
          CHANGED_FILES+=("intel/iwlwifi/${prefix}${firmware}.ucode")
          REPO_CHANGES+=("M:firmware/${prefix}${firmware}.ucode")
        fi
      fi
      break
    fi
  done

  for firmware in ${thisrepo//,/ }; do
    [ "${firmware}" == "${keepver}" ] && continue

    coreversion="c$((${firmware}-3))"
    if [ ${firmware} -gt ${kernel_max} ]; then
      if [ -f ../firmware/${prefix}${coreversion}.ucode ]; then
        echo "  Removing incompatible version: ${prefix}${coreversion}.ucode"
        [ -z "${DRYRUN}" ] && rm -f ../firmware/${prefix}${coreversion}.ucode
        REPO_CHANGES+=("D:firmware/${prefix}${coreversion}.ucode")
      else
        echo "  Removing incompatible version: ${prefix}${firmware}.ucode"
        [ -z "${DRYRUN}" ] && rm -f ../firmware/${prefix}${firmware}.ucode
        REPO_CHANGES+=("D:firmware/${prefix}${firmware}.ucode")
      fi
    elif [ -n "${keepver}" ]; then
      if [ -f ../firmware/${prefix}${coreversion}.ucode ]; then
        echo "  Removing old version: ${prefix}${coreversion}.ucode"
        [ -z "${DRYRUN}" ] && rm -f ../firmware/${prefix}${coreversion}.ucode
        REPO_CHANGES+=("D:firmware/${prefix}${coreversion}.ucode")
      else
        echo "  Removing old version: ${prefix}${firmware}.ucode"
        [ -z "${DRYRUN}" ] && rm -f ../firmware/${prefix}${firmware}.ucode
        REPO_CHANGES+=("D:firmware/${prefix}${firmware}.ucode")
      fi
    else
      echo "  Unable to identify suitable max version - keeping existing firmware files"
    fi
  done

  sync_pnvm "${prefix}" "${keepver}"
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

# clone/update linux-firmware
# Re-fetch a bounded window of history each run (--depth=N re-shallows to
# the latest N commits from the new tip) rather than deepening cumulatively,
# so the checkout size stays roughly constant no matter how often this runs.
if [ -d linux-firmware ]; then
  echo "Updating linux-firmware repository (last ${HISTDEPTH} commits)..."
  (
    cd linux-firmware &&
    git fetch ${USEIPV4} --depth="${HISTDEPTH}" origin &&
    git reset --hard origin/HEAD
  ) || exit 1
else
  echo "Cloning linux-firmware repository (last ${HISTDEPTH} commits)..."
  git clone ${USEIPV4} --depth="${HISTDEPTH}" \
    https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git \
    linux-firmware || exit 1
fi

echo "Synchronising repo with kernel and firmware..."
echo "Firmware versions are shown as API (not CORE), firmware files since API 104 are in the firmware as c101."
echo "  API = CORE+3. e.g. 104 = c101 + 3"
echo

while read -r device prefix kernel_max; do
  [ -n "{device}" -a -n "${prefix}" -a -n "${kernel_max}" ] && sync_max_firmware "${device}" "${prefix}" "${kernel_max}"
done <<< "$(get_kernel_max | sed -e 's/bz-a0/bz-b0/' -e 's/wh-a0/wh-b0/' | sort -u | sort -k1n)"

commit_body=""
if [ ${#CHANGED_FILES[@]} -gt 0 ]; then
  commit_body=$(
    printf '%s\n' "${CHANGED_FILES[@]}" | sort -u | while read -r file; do
      log_line="$(git -C linux-firmware log --no-merges -1 --format='%H|%h %s' -- "${file}")"
      if [ -z "${log_line}" ]; then
        echo "unknown|unknown (older than ${HISTDEPTH}-commit history window)|$(basename "${file}")"
      else
        awk -F'|' -v file="$(basename "${file}")" '{ print $1 "|" $2 "|" file }' <<< "${log_line}"
      fi
    done | sort | awk -F'|' '
      $1 != last {
        if (NR > 1)
          print ""
        print $2
        last = $1
      }
      {
        print "    " $3
      }
    '
  )
  echo
  echo "Upstream linux-firmware commits:"
  echo
  echo "${commit_body}"
fi

if [ ${#REPO_CHANGES[@]} -gt 0 ]; then
  added="$(printf '%s\n' "${REPO_CHANGES[@]}" | grep -c '^A:')"
  modified="$(printf '%s\n' "${REPO_CHANGES[@]}" | grep -c '^M:')"
  removed="$(printf '%s\n' "${REPO_CHANGES[@]}" | grep -c '^D:')"

  if [ -n "${DRYRUN}" ]; then
    echo
    echo "DRYRUN set - not staging or committing changes."
  elif [ -n "${NOCOMMIT}" ]; then
    echo
    echo "NOCOMMIT set - changes left in the working tree for manual add/commit."
  else
    echo
    echo "Staging changes for commit (added ${added}, updated ${modified}, removed ${removed})..."
    for entry in "${REPO_CHANGES[@]}"; do
      git -C .. add -- "${entry#*:}"
    done

    fw_commit="$(git -C linux-firmware rev-parse --short HEAD)"
    subject="iwlwifi-firmware: sync with linux ${KERNEL} / linux-firmware ${fw_commit}"

    if [ -n "${commit_body}" ]; then
      git -C .. commit -m "${subject}" -m "${commit_body}"
    else
      git -C .. commit -m "${subject}"
    fi
    echo "Committed as $(git -C .. rev-parse --short HEAD)."
  fi
fi
