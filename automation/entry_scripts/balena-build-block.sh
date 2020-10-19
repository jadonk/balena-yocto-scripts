#!/bin/bash

set -e

script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source "${script_dir}/balena-api.inc"
source "${script_dir}/balena-lib.inc"

# Input checks
[ -z "${APPNAME}" ] && echo "The block's app  name needs to be defined" && exit 1
[ -z "${API_ENV}" ] && echo "Balena's environment needs to be defined" && exit 1
[ -z "${BALENAOS_TOKEN}" ] && echo "Balena's environment token needs to be defined" && exit 1
[ -z "${MACHINE}" ] && echo "Machine needs to be defined" && exit 1
[ -z "${PACKAGES}" ] && echo "list of packages to install without dependencies" && exit 1
[ -z "${RELEASE_VERSION}" ] && echo "A release version needs to be defined" && exit 1
[ -z "${WORKSPACE}" ] && echo "Workspace needs to be defined" && exit 1

[ -z "${PACKAGE_TYPE}" ] && PACKAGE_TYPE="ipk"
[ -z "${BALENAOS_ACCOUNT}" ] && BALENAOS_ACCOUNT="balena_os"

DEVICE_TYPE_JSON="$WORKSPACE/$MACHINE.json"
if [ -e "${DEVICE_TYPE_JSON}" ]; then
	ARCH=$(jq --raw-output '.arch' "$DEVICE_TYPE_JSON")
fi
[ -z "${ARCH}" ] && echo "Device architecture is required" && exit 1

source /balena-docker.inc

finish() {
	balena_docker_stop
	# Dockerd leaves a mount here
	if ! umount "${DOCKER_ROOT}"; then
		umount -l "${DOCKER_ROOT}" || true
	fi
	rm -rf "${TMPDIR}"
}
trap finish EXIT ERR

# Start docker
# Data root needs to be on a non-aufs directory to use balena build
TMPDIR=$(mktemp -d --tmpdir="${WORKSPACE:?}")
DOCKER_ROOT="${TMPDIR}/docker"
balena_docker_start "${DOCKER_ROOT}" "/var/run" "/var/log/docker.log"
balena_docker_wait

# Only support overlay images for the time being. Labels to be parametrized from contract in future.
cat << 'EOF' > ${TMPDIR}/Dockerfile
ARG NAMESPACE=resin
ARG TAG=latest
FROM ${NAMESPACE}/yocto-block-build-env:${TAG} AS builder
ARG PACKAGES="space separated list of packages to force install without dependencies"
ARG ARCH_LIST="space separated list of packages architectures"
ARG FEED_URL="file:/ipk"
COPY feed /
RUN priority=1; for arch in $ARCH_LIST; do echo "arch $arch $priority" >> /etc/opkg/opkg.conf; priority=$(expr $priority + 5); echo "src/gz balena-$arch $FEED_URL/$arch" >> /etc/opkg/opkg.conf; done
RUN mkdir /hostapp
RUN opkg -f /etc/opkg/opkg.conf update && opkg -f /etc/opkg/opkg.conf --nodeps --dest=hostapp install ${PACKAGES} || true
RUN rm -rf /hostapp/var/lib/opkg
FROM scratch
LABEL io.balena.image.class=overlay
LABEL io.balena.image.requires-reboot=1
LABEL io.balena.image.store=data
COPY --from=builder /hostapp /
EOF

# Copy local package feed to context if available from previous build step
if [ -d "${WORKSPACE}/deploy-jenkins/${PACKAGE_TYPE}" ]; then
	ARCH_LIST=""
	mkdir -p "${TMPDIR}/feed"
	cp -r "${WORKSPACE}/deploy-jenkins/${PACKAGE_TYPE}" "${TMPDIR}/feed/"
	# Extract package architecture list from feed
	# Each architecture is one directory
	while IFS=$'\n' read -r dir; do
		if [ -z "${ARCH_LIST}" ]; then
			ARCH_LIST="${dir}"
		else
			ARCH_LIST="${ARCH_LIST} ${dir}"
		fi
	done< <(find "${WORKSPACE}/deploy-jenkins/${PACKAGE_TYPE}" -mindepth 1 -maxdepth 1 -type d | xargs -I{} basename {})
else
	proto=${FEED_URL%:*}
	if [ -z "${FEED_URL}" ] || [ "${proto}" = "file" ]; then
		echo "[ERROR] Local package feed not available"
		exit 1
	fi
fi

BALENAOS_ACCOUNT="${BALENAOS_ACCOUNT:-"balena_os"}"

echo "[INFO] Logging into $API_ENV as ${BALENAOS_ACCOUNT}"
export BALENARC_BALENA_URL=${API_ENV}
balena login --token "${BALENAOS_TOKEN}"

pushd "${TMPDIR}"
balena_api_create_public_app "${APPNAME}" "${API_ENV}" "${MACHINE}" "${balenaCloudEmail}" "${balenaCloudPassword}"

# Clean local docker of labelled hostos images
docker rmi -f $(docker images --filter "label=io.balena.image.class" --format "{{.ID}}" | tr '\n' ' ') 2> /dev/null || true

if balena build --logs --nocache --deviceType "${MACHINE}" --arch "${ARCH}" --buildArg PACKAGES="${PACKAGES}" --buildArg ARCH_LIST="${ARCH_LIST}" --buildArg NAMESPACE="${NAMESPACE:-resin}"; then
	image_id=$(docker images --filter "label=io.balena.image.class" --format "{{.ID}}")
	mkdir -p "${WORKSPACE}/deploy-jenkins"
	docker save "${image_id}" > "${WORKSPACE}/deploy-jenkins/${APPNAME}-${RELEASE_VERSION}.docker"
	_releaseID=$(balena deploy "${BALENAOS_ACCOUNT}/${APPNAME}" "${image_id}" | sed -n 's/.*Release: //p')
	balena_api_set_release_version "${_releaseID}" "${API_ENV}" "${BALENAOS_TOKEN}" "${RELEASE_VERSION}"
else
	echo "[ERROR] Fail to build"
	exit 1
fi

popd

exit 0
