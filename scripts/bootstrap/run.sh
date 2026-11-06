#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
task_token="$$-$RANDOM-$RANDOM"
task_image="native-artifact-p0-bootstrap:run-$task_token"
task_volume=""
task_online="native-artifact-p0-bootstrap-online-$task_token"
task_offline="native-artifact-p0-bootstrap-offline-$task_token"
task_image_created=false

cleanup() {
  task_status=$?
  trap - EXIT
  for task_container in "$task_online" "$task_offline"; do
    if docker container inspect "$task_container" >/dev/null 2>&1; then
      docker container rm --force "$task_container" >/dev/null || task_status=1
    fi
  done
  if [[ -n "$task_volume" ]]; then
    docker volume rm "$task_volume" >/dev/null || task_status=1
  fi
  if [[ "$task_image_created" == true ]]; then
    docker image rm "$task_image" >/dev/null || task_status=1
  fi
  exit "$task_status"
}

command -v docker >/dev/null
if ! docker buildx version >/dev/null 2>&1; then
  echo "Docker Buildx is required for the isolated bootstrap build." >&2
  exit 1
fi
docker info >/dev/null
test -f "$task_root/mix.lock"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Honors DOCKER_HOST/DOCKER_CONTEXT; never starts a daemon or changes its context.
docker buildx build --load --progress plain --file "$task_root/scripts/bootstrap/Dockerfile" \
  --tag "$task_image" "$task_root"
task_image_created=true
docker image inspect "$task_image" --format 'bootstrap_image={{.Id}}'
task_volume="$(docker volume create --label native-artifact.task=p0-bootstrap \
  "native-artifact-p0-bootstrap-$task_token")"

docker run --name "$task_online" --network bridge \
  --mount "type=volume,src=$task_volume,dst=/evidence" \
  "$task_image" online /evidence

# This process has no network route and starts no HTTP application.
docker run --name "$task_offline" --network none \
  --mount "type=volume,src=$task_volume,dst=/evidence,readonly" \
  "$task_image" offline /evidence
