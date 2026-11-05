#!/usr/bin/env bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/crossplane/crossplane}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gardenlinux/gardenlinux/fips:1877.22}"
WORKDIR="${WORKDIR:-./.build/crossplane-fips-build}"
IMAGE_NAME="${IMAGE_NAME:-gl-fips-crossplane}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
VERSION="${VERSION:-2.4.3}"
UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA:-49fcf89e5b683771211c0321005a2a26029e0666}"
GO_IMAGE="${GO_IMAGE:-golang:1.26.10-bookworm}"

# --- prerequisites -----------------------------------------------------------

check_tool() { command -v "$1" &>/dev/null || { echo "error: $1 not found" >&2; exit 1; }; }
check_tool git
check_tool docker
docker buildx version &>/dev/null || { echo "error: docker buildx not available" >&2; exit 1; }

# --- buildx driver -----------------------------------------------------------

if ! docker buildx inspect fips-builder &>/dev/null; then
    docker buildx create --name fips-builder --driver docker-container
fi
docker buildx use fips-builder

# --- prepare working directory -----------------------------------------------

mkdir -p "${WORKDIR}"
CLONE_DIR="./.build/fips-port-crossplane"

if [ ! -d "${CLONE_DIR}" ]; then
    git clone "${REPO_URL}" "${CLONE_DIR}"
fi

git -C "${CLONE_DIR}" checkout "v${VERSION}"

# --- generate Dockerfile.fips ------------------------------------------------

cat > "${WORKDIR}/Dockerfile.fips" <<'EOF'
ARG GO_IMAGE=golang:1.26.10-bookworm
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS builder
ARG TARGETARCH
ARG VERSION
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOARCH=${TARGETARCH} go build \
    -ldflags "-s -w -X=github.com/crossplane/crossplane-runtime/v2/pkg/version.version=${VERSION}" \
    -o /crossplane ./cmd/crossplane

FROM ghcr.io/gardenlinux/gardenlinux/fips:1877.22
ARG UPSTREAM_GIT_SHA
LABEL org.opencontainers.image.description="A FIPS-enabled Crossplane image"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="${UPSTREAM_GIT_SHA}"

RUN groupadd -g 65532 nonroot \
    && useradd -u 65532 -g 65532 -s /sbin/nologin -d /home/nonroot nonroot \
    && mkdir -p /tmp /home/nonroot /crds /webhookconfigurations \
    && chmod 1777 /tmp \
    && chown 65532:65532 /home/nonroot

COPY cluster/crds/ /crds/
COPY cluster/webhookconfigurations/ /webhookconfigurations/

COPY --from=builder /crossplane /bin/crossplane

ENV GODEBUG=fips140=only
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

EXPOSE 8080/tcp
USER 65532
ENTRYPOINT ["/bin/crossplane"]
EOF

# --- build -------------------------------------------------------------------

docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg GO_IMAGE="${GO_IMAGE}" \
    --build-arg VERSION="${VERSION}" \
    --build-arg UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA}" \
    --file "${WORKDIR}/Dockerfile.fips" \
    --load \
    --tag "${IMAGE_NAME}:${VERSION}-${ARCH}" \
    "${CLONE_DIR}"

# --- report ------------------------------------------------------------------

echo "Built: ${IMAGE_NAME}:${VERSION}-${ARCH}"

# --- SBOM --------------------------------------------------------------------
# Syft version is pinned; update SYFT_VERSION to pick up a newer release.
SYFT_VERSION="${SYFT_VERSION:-1.56.0}"
SYFT_BIN="${WORKDIR}/syft"

install_syft() {
    local arch_syft
    arch_syft=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local tarball="syft_${SYFT_VERSION}_linux_${arch_syft}.tar.gz"
    local checksum_file="syft_${SYFT_VERSION}_checksums.txt"
    local base_url="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}"

    curl -sSfL "${base_url}/${tarball}"       -o "/tmp/${tarball}"
    curl -sSfL "${base_url}/${checksum_file}" -o "/tmp/${checksum_file}"
    grep "${tarball}" "/tmp/${checksum_file}" | (cd /tmp && sha256sum -c)
    tar -xzf "/tmp/${tarball}" -C "${WORKDIR}" syft
    chmod +x "${SYFT_BIN}"
}

{ [ -x "${SYFT_BIN}" ] && "${SYFT_BIN}" version 2>/dev/null | grep -q "${SYFT_VERSION}"; } || install_syft

# Phase 2: scan the final image for OS packages + language packages.
# Catalogers are driven by syft.yaml (catalogers.default).
IMAGE_NAME_BASE=$(basename "${IMAGE_NAME}")
SBOM_TMP="${WORKDIR}/${IMAGE_NAME_BASE}-${VERSION}-${ARCH}.raw.cdx.json"
SBOM_OUT="${WORKDIR}/${IMAGE_NAME_BASE}-${VERSION}-${ARCH}.cdx.json"

"${SYFT_BIN}" "${IMAGE_NAME}:${VERSION}-${ARCH}" \
    --output "cyclonedx-json=${SBOM_TMP}"

jq \
    --arg name "crossplane" \
    --arg version "${VERSION}" \
    --arg purl "pkg:oci/gl-fips-crossplane@${VERSION}?arch=${ARCH}" \
    --arg revision "${UPSTREAM_GIT_SHA}" \
    --arg arch "${ARCH}" \
    '.metadata.lifecycles = [{"phase": "post-build"}] |
     .metadata.component = {
       "type": "application",
       "name": $name,
       "version": $version,
       "purl": $purl,
       "properties": [
         {"name": "org.opencontainers.image.revision", "value": $revision},
         {"name": "arch", "value": $arch}
       ]
     }' \
    "${SBOM_TMP}" > "${SBOM_OUT}"

rm "${SBOM_TMP}"
echo "SBOM: ${SBOM_OUT}"
