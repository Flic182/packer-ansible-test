#!/usr/bin/env bash

################################################################################
# This script is a library of common error-related functions for use by other
# scripts.
################################################################################


################################################################################
# Define booleans.
################################################################################
readonly FALSE=0
readonly TRUE=1


################################################################################
# File and command info.
################################################################################
readonly LOG_DATE_FORMAT='+%Y-%m-%d %H:%M:%S'
readonly WORKING_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" > /dev/null && pwd)"
readonly BUILD_DIR="${WORKING_DIR}/build/packer-ansible"
readonly PACKER_COPY="${BUILD_DIR}/packer-project"


################################################################################
# Exit states.
################################################################################
readonly SUCCESS=0
readonly UNDEFINED_ERROR=1
readonly SCRIPT_INTERRUPTED=99


################################################################################
# User info required inside Docker container.
################################################################################
export USER_ID="$(id -u)"
export USER_NAME="$(id -nu)"


################################################################################
# Executes clean up tasks required before exiting - basically writing the
# interrupt signal to stderr.
#
# @param SIGNAL The signal that triggered the cleanup.
#
# Note:  This function is assigned to signal trapping for the script so any
#        unexpected interrupts are handled gracefully.
################################################################################
cleanup() {
  local -r SIGNAL="${1}"

  # Exit and indicate what caused the interrupt
  if [[ "${SIGNAL}" != "EXIT" ]]; then
    write_log "Script interrupted by '${SIGNAL}' signal"

    if [[ "${SIGNAL}" != "INT" ]] && [[ "${SIGNAL}" != "QUIT" ]]; then
      exit ${SCRIPT_INTERRUPTED}
    else
      kill -"${SIGNAL}" "$$"
    fi
  fi
}


#################################################################################
# Checks the supplied return value from a previously executed command and if it
# is non-zero, exits the script with the given value after logging an error
# message (if supplied).
#
# @param RETURN_VAL    The value returned by the previously executed command.
# @param ERROR_EXIT    The value with which to exit if RETURN_VAL was non-zero.
# @param ERROR_MESSAGE The error message to log if an exit is required.
################################################################################
exit_if_error() {
  local -r RETURN_VAL="${1}"
  local -r ERROR_EXIT="${2}"
  local -r ERROR_MESSAGE="${3}"

  if ((RETURN_VAL != SUCCESS)); then
    exit_with_error "${ERROR_EXIT}" "${ERROR_MESSAGE}"
  fi
}


################################################################################
# Exits with the given value after logging an error message (if supplied).
#
# @param ERROR_EXIT    The value with which to exit if RETURN_VAL was non-zero.
# @param ERROR_MESSAGE The error message to log if an exit is required.
################################################################################
exit_with_error() {
  local -r ERROR_EXIT="${1}"
  local -r ERROR_MESSAGE="${2}"

  if [[ "${ERROR_MESSAGE}" != "" ]]; then
    write_log "${ERROR_MESSAGE}"
  fi

  exit ${ERROR_EXIT}
}


################################################################################
# Removes the copy of the Packer directory in the build directory.
################################################################################
remove_copied_packer_dir() {
  rm -rf "${PACKER_COPY}"
}


################################################################################
# Shuts down all containers built from local docker-compose.yml file.
################################################################################
remove_docker_containers() {
  local -r FIRST_SERVICE="$("yq" "r" "${WORKING_DIR}/docker-compose.yml" \
                            "services" | "sed" "-n" "1 s/:$//p")"
  local -r SERVICE_ID="$("docker-compose" "ps" "-q" "${FIRST_SERVICE}")"

  if [[ "${SERVICE_ID}" != "" ]]; then
    docker-compose down
  fi
}


################################################################################
# Sets up a trap to execute the nominated function for passed signals.
#
# @param TRAP_FUNCTION The function to execute when a signal is trapped by the
#                      script.
################################################################################
trap_with_signal() {
  local -r TRAP_FUNCTION="${1}"

  shift
  for trapped_signal; do
    trap "${TRAP_FUNCTION} ${trapped_signal}" "${trapped_signal}"
  done
}


################################################################################
# Writes log messages (for the script) with a date prefix to a known place.  For
# now, stderr will do.
#
# @param LOG_MESSAGE The message to write.
################################################################################
write_log() {
  local -r LOG_MESSAGE="${1}"

  echo "$("date" "${LOG_DATE_FORMAT}") - ${LOG_MESSAGE}" 1>&2;
}
