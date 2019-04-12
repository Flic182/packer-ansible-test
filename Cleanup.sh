#!/usr/bin/env bash
################################################################################
# This script removes the Docker container and image(s) created by the
# ./UnpackDeb.sh script.
################################################################################


# Include error handling functionality.
. ./ErrorHandling.sh


################################################################################
# File and command info.
################################################################################
readonly DOCKER_COMPOSE_FILE="${WORKING_DIR}/docker-compose.yml"


################################################################################
# Builds an Awk script for finding the target image's ID from the Docker image
# list (output of docker images -a).  If the image name contains a version tag,
# the script will match both the name and the version.
#
# @param TARGET_IMAGE The name (and optionally, version) of the required image.
################################################################################
build_awk_prog() {
  local -r TARGET_IMAGE="${1}"

cat << EOF
{
  if ("${TARGET_IMAGE}" ~/:/)
  {
    split("${TARGET_IMAGE}", imageArray, ":")
    if (\$1 == imageArray[1] && \$2 == imageArray[2])
      print \$3
  }
  else if (\$1 == "${TARGET_IMAGE}")
    print \$3
}
EOF
}


################################################################################
# Removes the Docker image for the nominated service created from the local
# docker-compose.yml file.
#
# @param SERVICE The name of the service for which the image is to be removed.
################################################################################
remove_docker_image() {
  local -r SERVICE="${1}"

  local -r IMAGE="$("yq" "r" "${DOCKER_COMPOSE_FILE}" \
                    "services.${SERVICE}.image")"

  local base_image="$("yq" "r" "${DOCKER_COMPOSE_FILE}" \
                      "services.${SERVICE}.build.args" | "sed" "-n" \
                      's/^.*BASE_IMAGE=\(..*\)$/\1/p')"
  local build_dir=""

  if [[ "${base_image}" == "" ]]; then
    build_dir="${WORKING_DIR}/$("yq" "r" "${DOCKER_COMPOSE_FILE}" \
                                "services.${SERVICE}.build.context")"
    base_image="$("grep" "ARG BASE_IMAGE=" "${build_dir}/Dockerfile" | \
                  "sed" 's/^[^=][^=]*=\(..*\)$/\1/')"
  fi

  docker rmi $(docker images -a | awk "$("build_awk_prog" "${IMAGE}")")
  docker rmi $(docker images -a | awk "$("build_awk_prog" "${base_image}")")
}


################################################################################
# Removes all Docker images created from the local docker-compose.yml file.
################################################################################
remove_docker_images() {
  local -r SERVICES=($("yq" "r" "${DOCKER_COMPOSE_FILE}" "services" \
                       | "sed" "-n" 's/^\([a-zA-Z0-9][a-zA-Z0-9_.-]*\):$/\1/p'))

  for service in "${SERVICES[@]}"; do
    remove_docker_image "${service}"
  done
}


#################################################################################
# Entry point to the program.  Command line arguments are ignored.
################################################################################
main() {
  remove_copied_packer_dir
  remove_docker_containers "${TRUE}"
  remove_docker_images
}


#################################################################################
# Set up for bomb-proof exit, then run the script
################################################################################
trap_with_signal cleanup HUP INT QUIT ABRT TERM EXIT

main "${@}"
exit ${SUCCESS}
