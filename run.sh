#!/bin/bash

set -e

if [ ! -f .env ]; then cp .env.sample .env; fi

case "$1" in
    down)
        docker compose down &> /dev/null &
        docker compose logs -f
        exit 0
        ;;
    build)
        docker compose build
        exit 0
        ;;
    up)
        trap 'docker compose stop; exit 1' INT
        docker compose down
        docker compose up -d
        exec docker compose logs -f
        ;;
    *)
        echo "Usage: $(basename $0) {up|down|build}"
        exit 1
esac
