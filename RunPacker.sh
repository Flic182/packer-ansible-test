#!/usr/bin/env bash

################################################################################
# This script runs a Packer script inside a Docker container.  Ansible is
# available in the container, should it be required.
#
# The ancestor path of all Packer components is specified on the command line
# (-p) and is copied to the build directory, where it is mounted as a volume
# into the container.  The script update config file flag (-f) points to a file
# that tells the program what changes should be made to the Packer script (in
# turn passed as an environment variable in docker-compose.yml).  Changes can
# include:
# - Setting the build tag
# - Retention of AMI user settings
# - Which AWS regions should be targeted
# - Which subnets to use in the region(s) (specified per region)
#
# Packer can be run in debug mode, but you must log in to the container and do
# so manually.  If you specify debug mode (-d), the Packer script will not run
# - instead, the required command will be written to
# /opt/packer-project/DebugPacker.sh in the container, made executable for your
# convenience.
#
# If the environment or arguments to Docker need to change substantially,
# use the -b flag to bring the containers down and rebuild them.  The -x flag
# can be used to specify a file that lists filename patterns that should be
# excluded from the Packer directory copy.
################################################################################


# Include error handling functionality.
. ./ErrorHandling.sh


################################################################################
# File and command info.
################################################################################
readonly USAGE="${0} -p <script ancestor> [-b(uild)] [-d(ebug)] [-f <script update config file>] [-x <copy exclusions file>]"
readonly ALLOWED_FLAGS="^-[bdfpx]$"
readonly PACKER_SCRIPT="$("yq" "r" "docker-compose.yml" \
                          "services.packer_ansible.environment" | \
                          "sed" "-n" \
                          's/^\(- \)\{0,1\}PACKER_SCRIPT=\(.*\)$/\2/p')"


################################################################################
# Exit states.
################################################################################
readonly BAD_ARGUMENT_ERROR=90
readonly MISSING_DIR_ERROR=91
readonly MISSING_CONFIG_ERROR=92
readonly MISSING_EXCLUSION_ERROR=93
readonly MISSING_SCRIPT_ERROR=94
readonly COPY_ERROR=95


################################################################################
# Command line switch environment variables.
################################################################################
copy_exclusion_file=""
debug="${FALSE}"
filter_config_file=""
packer_dir=""
rebuild="${FALSE}"


################################################################################
# Config file environment variables.
################################################################################
build_tag=""
increment_tag="${FALSE}"
keep_ami_users="${TRUE}"
region_list=()
subnet_list=()


################################################################################
# Builds the subnet part of the jq filter for the Packer script.
################################################################################
build_subnet_filter() {
  local subnet_regions=("${region_list[@]}")
  local subnet_filter=""

  if [[ ${#subnet_regions[@]} -eq 0 ]]; then
    # Use all regions specified in the Packer script instead.
    while IFS= read -r line; do
      subnet_regions+=( "$line" )
    done < <( jq -r .builders[].region "${PACKER_SCRIPT}" )
  fi

  if [[ ${#subnet_list[@]} -eq ${#subnet_regions[@]} ]]; then
    for ((subnet_index=0; subnet_index < ${#subnet_list[@]}; subnet_index++)); do
      subnet_filter="${subnet_filter} (.builders[] | "
      subnet_filter+="select(.name==\"${subnet_regions[${subnet_index}]}\") "
      subnet_filter+=".subnet_id) |= \"${subnet_list[${subnet_index}]}\" |"
    done
  elif [[ ${#subnet_list[@]} -ne 0 ]]; then
    exit_with_error "${BAD_ARGUMENT_ERROR}" \
                    "Cannot specify a different number of subnet changes to regions!  Usage:  ${USAGE}"
  fi

  if [[ "${subnet_filter}" != "" ]]; then
    # Trim trailing pipe.
    subnet_filter="${subnet_filter%?}"
  fi

  echo "${subnet_filter}"
}


################################################################################
# Checks command line arguments are valid and have valid arguments and the
# PACKER_SCRIPT environment variable points to a real file.
#
# @param $@ All arguments passed on the command line.
################################################################################
check_args() {
  while [[ ${#} -gt 0 ]]; do
    case "${1}" in
      -b)
        if ! [[ "${2}" =~ ${ALLOWED_FLAGS} ]] && [[ ${#} -gt 1 ]]; then
          exit_with_error "${BAD_ARGUMENT_ERROR}" \
                          "Option ${1} does not require an argument.  Usage:  ${USAGE}"
        else
          rebuild="${TRUE}"
        fi
        ;;
      -d)
        if ! [[ "${2}" =~ ${ALLOWED_FLAGS} ]] && [[ ${#} -gt 1 ]]; then
          exit_with_error "${BAD_ARGUMENT_ERROR}" \
                          "Option ${1} does not require an argument.  Usage:  ${USAGE}"
        else
          debug="${TRUE}"
        fi
        ;;
      -f)
        while ! [[ "${2}" =~ ${ALLOWED_FLAGS} ]] && [[ ${#} -gt 1 ]]; do
          filter_config_file="${2}"
          shift
        done

        if [[ "${filter_config_file}" == "" ]]; then
          exit_with_error "${BAD_ARGUMENT_ERROR}" \
                          "Option ${1} requires an argument.  Usage:  ${USAGE}"
        elif [[ ! -f "${filter_config_file}" ]]; then
          exit_with_error "${MISSING_CONFIG_ERROR}" \
                          "No valid config file specified!  Usage:  ${USAGE}"
        fi
        ;;
      -p)
        while ! [[ "${2}" =~ ${ALLOWED_FLAGS} ]] && [[ ${#} -gt 1 ]]; do
          packer_dir="${2}"
          shift
        done

        if [[ "${packer_dir}" == "" ]]; then
          exit_with_error "${BAD_ARGUMENT_ERROR}" \
                          "Option ${1} requires an argument.  Usage:  ${USAGE}"
        elif [[ ! "${packer_dir}" =~ /$ ]]; then
          # Ensure we have trailing '/' so rsync copies content rather than dir.
          packer_dir="${packer_dir}/"
        fi
        ;;
      -x)
        while ! [[ "${2}" =~ ${ALLOWED_FLAGS} ]] && [[ ${#} -gt 1 ]]; do
          copy_exclusion_file="${2}"
          shift
        done

        if [[ "${copy_exclusion_file}" == "" ]]; then
          exit_with_error "${BAD_ARGUMENT_ERROR}" \
                          "Option ${1} requires an argument.  Usage:  ${USAGE}"
        elif [[ ! -f "${copy_exclusion_file}" ]]; then
          exit_with_error "${MISSING_EXCLUSION_ERROR}" \
                          "No valid exclusion file specified!  Usage:  ${USAGE}"
        fi
        ;;
      *)
        exit_with_error "${BAD_ARGUMENT_ERROR}" \
                        "Invalid option: ${1}.  Usage:  ${USAGE}"
        ;;
    esac
    shift
  done

  if [[ "${packer_dir}" == "" ]] || [[ ! -d "${packer_dir}" ]]; then
    exit_with_error "${MISSING_DIR_ERROR}" \
                    "No valid directory specified!  Usage:  ${USAGE}"
  elif [[ "${PACKER_SCRIPT}" == "" ]] || \
       [[ ! -f "${packer_dir}/${PACKER_SCRIPT}" ]]; then
    exit_with_error "${MISSING_SCRIPT_ERROR}" \
                    "No valid Packer script specified!  Usage:  ${USAGE}"
  fi
}


################################################################################
# Runs jq against the Packer script to come up with a sanitised script for
# testing.  Will also increment the build tag if one is present and the filter
# config specifies it should be updated.
################################################################################
filter_script() {
  local filter=""
  local packer_input=""
  local region_filter=""
  local -r SUBNET_FILTER="$("build_subnet_filter")"

  if [[ "${build_tag}" != "" ]]; then
    filter=".variables.build_tag |= \"${build_tag}\" | "
    if ((increment_tag == TRUE)); then
      update_filter_config
    fi
  fi

  if [[ ${#region_list[@]} -ne 0 ]]; then
    region_filter="select([.region] | inside(["
    for next_region in "${region_list[@]}"; do
      region_filter="${region_filter}\"${next_region}\","
    done
    region_filter="${region_filter%?}]) | not)"

    filter+="del(.builders[] | ${region_filter}"
    if ((keep_ami_users == FALSE)); then
      filter+=", .ami_users"
    fi

    if [[ "${SUBNET_FILTER}" != "" ]]; then
      filter+=") | ${SUBNET_FILTER}"
    else
      filter+=")"
    fi
  elif ((keep_ami_users == FALSE)); then
    filter="del(.builders[] | .ami_users)"

    if [[ "${SUBNET_FILTER}" != "" ]]; then
      filter+=" | ${SUBNET_FILTER}"
    fi
  else
    filter="${SUBNET_FILTER}"
  fi

  cd "${PACKER_COPY}" || \
     exit_with_error ${MISSING_DIR_ERROR} \
                     "Could not change to ${PACKER_COPY} dir."

  packer_input="$("jq" "-r" "${filter}" < "${PACKER_SCRIPT}")"
  printf "%s" "${packer_input}" > "${PACKER_SCRIPT}"
}


################################################################################
# Retrieves the Packer parent directory (all elements required by Packer must
# live under this directory).  Any patterns listed in the copy exclusion file
# are excluded.
################################################################################
get_packer_dir() {
  local return_val="${SUCCESS}"

  # Make sure we only have one Packer directory relevant for this script run.
  remove_copied_packer_dir

  mkdir "${PACKER_COPY}"

  if [[ "${copy_exclusion_file}" != "" ]]; then
    rsync -a "${packer_dir}" "${PACKER_COPY}" \
          --exclude-from="${copy_exclusion_file}"
  else
    rsync -a "${packer_dir}" "${PACKER_COPY}"
  fi

  return_val="${?}"
  if ((return_val != SUCCESS)); then
    exit_with_error ${COPY_ERROR} \
                    "Could not copy Packer directory *${packer_dir}*!"
  fi
}


################################################################################
# Reads the filter configuration file into global environment variables.  There
# are two lists in the file and it isn't possible to pass them as two arrays to
# the filter_script() function.  Therefore, all values are stored globally for
# consistency.
################################################################################
read_filter_config() {
  local -r INCREMENT_TAG="$("yq" "r" "${filter_config_file}" "increment_tag")"
  local -r KEEP_AMI_USERS="$("yq" "r" "${filter_config_file}" "keep_ami_users")"

  local temp_list=""

  shopt -s nocasematch
  if [[ "${INCREMENT_TAG}" =~ true ]]; then
    increment_tag="${TRUE}"
  fi
  if [[ "${KEEP_AMI_USERS}" =~ true ]]; then
    keep_ami_users="${TRUE}"
  fi
  shopt -u nocasematch

  # Set the rest of the filter variables
  build_tag="$("yq" "r" "${filter_config_file}" "build_tag")"

  temp_list="$("read_filter_list" "regions")"
  [[ "${temp_list}" != "null" ]] && region_list=( "${temp_list}" )

  temp_list="$("read_filter_list" "subnets")"
  [[ "${temp_list}" != "null" ]] && subnet_list=( "${temp_list}" )
}


################################################################################
# Reads the nominated filter configuration list item, printing an empty string
# if the target item was not found (and subsequently returns null from yq).
################################################################################
read_filter_list() {
  local -r KEY="${1}"
  echo "$("yq" "r" "${filter_config_file}" "${KEY}" | \
          "sed" "-n" 's/^\(- \)\{0,1\}\(..*\)$/\2/p')"
}


################################################################################
# Updates the build tag in the filter configuration file.  This function is only
# called AFTER we have set the ${build_tag} variable because we assume it is
# already set.
#
# Note: Beware, this function will remove any comments in the filter
# configuration file!  This is a limitation of yq.
################################################################################
update_filter_config() {
  local -r UPDATED_BUILD_TAG="$("awk" "-F" "[^0-9]+" \
                                "sub(\$NF\"\$\",sprintf(\"%0*d\",length(\$NF),\$NF+1))" \
                                <<< "${build_tag}")"

  if [[ ! -f "${filter_config_file}.orig" ]]; then
    cp "${filter_config_file}" "${filter_config_file}.orig" ||
       exit_with_error ${COPY_ERROR} \
                       "Could not back up *${filter_config_file}*!"
  fi

  yq w -i "${filter_config_file}" build_tag "${UPDATED_BUILD_TAG}"
}


################################################################################
# Entry point to the program.  Valid command line options are described at the
# top of the script.
#
# @param ARGS Command line flags, including -p <packer path> -f <config file>
#             and the optional -b (build containers), -d (run in debug mode) and
#             -x <copy exclusion file>.
################################################################################
main() {
  local -r ARGS=("${@}")

  check_args "${ARGS[@]}"
  remove_docker_containers
  get_packer_dir
  read_filter_config
  filter_script

  if ((rebuild == TRUE)); then
    docker-compose up --build -d
  else
    docker-compose up -d
  fi
}


################################################################################
# Set up for bomb-proof exit, then run the script
################################################################################
trap_with_signal cleanup HUP INT QUIT ABRT TERM EXIT

main "${@}"
exit ${SUCCESS}
