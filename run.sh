#!/bin/bash

set -e

# Default image tag (override with IMAGE_TAG env var)
IMAGE="${IMAGE:-ghcr.io/musclepr/ark_ascended_docker}"
TAG="${TAG:-latest}"

if [ ! -f .env ]; then cp -av default/template.env .env; fi
if [ ! -f .common.env ]; then echo "# override common environment variables here" > .common.env; fi

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
        docker build -t "$IMAGE:$TAG" .
        exit 0
        ;;
    up)
        rm -rf ark_data/.signals/*
        docker compose up -d
        exec docker compose logs -f
        ;;
    push)
        docker build -t "$IMAGE:$TAG" --push .
        ;;
    dev-push)
        docker build -t "$IMAGE:dev" --push .
        ;;
    shellcheck)
        shopt -s globstar
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
        echo "Usage: $(basename $0) {up|down|build|push|shellcheck|exec|backup|restore}"
        exit 1
esac
