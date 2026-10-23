#!/usr/bin/env bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/crossplane/crossplane}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gardenlinux/gardenlinux/fips:1877.22}"
WORKDIR="${WORKDIR:-./.build/crossplane-fips-build}"
IMAGE_NAME="${IMAGE_NAME:-gl-fips-crossplane}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
VERSION="${VERSION:-2.4.2}"
UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA:-bf8ffd4048a0bb1b408b8b745e31960c717009cb}"
GO_IMAGE="${GO_IMAGE:-golang:1.26.7-bookworm}"

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
ARG GO_IMAGE=golang:1.26.7-bookworm
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
