#!/bin/bash

set -e

# Default image tag (override with IMAGE_TAG env var)
TAG="${IMAGE_TAG:-ghcr.io/musclepr/ark_ascended_docker:latest}"

if [ ! -f .env ]; then cp template.env .env; fi
if [ ! -f .common.env ]; then cp default.common.env .common.env; fi

function init_docker_buildx() {
    if ! docker buildx inspect multi-builder >/dev/null 2>&1; then
        docker buildx create --name multi-builder --driver docker-container --use
    fi
    docker buildx inspect --bootstrap > /dev/null 2>&1

    if ! docker run --rm --privileged tonistiigi/binfmt --display 2>/dev/null | grep -qi qemu; then
        docker run --privileged --rm tonistiigi/binfmt --install all >/dev/null 2>&1
    fi
}

function clean_docker_buildx() {
    docker buildx rm multi-builder >/dev/null 2>&1 || true
}

case "$1" in
    down)
        docker compose stop 2>/dev/null &
        docker compose logs -f
        docker compose logs > .last.log
        if [ -f .last.log ] && [ -z "$(cat .last.log)" ]; then
            rm -f .last.log
        fi
        docker compose down
        exit 0
        ;;
    build)
        init_docker_buildx
        arch=$(uname -m)
        case "$arch" in
            x86_64) platform=linux/amd64 ;;
            aarch64|arm64) platform=linux/arm64 ;;
            armv7l) platform=linux/arm/v7 ;;
            *) platform=linux/amd64 ;;
        esac
        echo "Building for $platform and loading into local docker (using --load)"
        docker buildx build --platform "$platform" -t "$TAG" --load .
        clean_docker_buildx
        exit 0
        ;;
    up)
        docker compose up -d
        exec docker compose logs -f
        ;;
    push)
        init_docker_buildx
        echo "Building multi-platform and pushing to registry (requires ghcr.io login)"
        docker buildx build --platform linux/amd64,linux/arm64 -t "$TAG" --push .
        clean_docker_buildx
        ;;
    shellcheck)
        shellcheck -x ./scripts/**/*.sh
        ;;
    exec)
        shift
        docker exec -itu arkuser "$@"
        ;;
    backup)
        docker exec -itu arkuser asa0 manager backup
        ;;
    restore)
        docker exec -itu arkuser asa0 manager restore "$2"
        ;;
    *)
        echo "Usage: $(basename $0) {up|down|build|push|shellcheck}"
        exit 1
esac
