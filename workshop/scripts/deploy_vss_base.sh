#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# One supported deployment for this workshop:
#   GPU 0  nvidia/nvidia-nemotron-nano-9b-v2
#   GPU 1  nvidia/cosmos3-nano-reasoner (Nano)
#
# Usage: workshop/scripts/deploy_vss_base.sh check|deploy|status|stop

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
RUNTIME_DIR="${REPO_ROOT}/workshop/runtime"
COMPOSE_FILE="${RUNTIME_DIR}/compose.yml"
DEFAULT_ENV_FILE="${RUNTIME_DIR}/developer-profiles/dev-profile-base/.env"
STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/vss-workshop"
PRIVATE_ENV_FILE="${STATE_ROOT}/base.env"
DEPLOY_LOG="${STATE_ROOT}/deploy.log"

readonly REQUIRED_GPUS=2
readonly MIN_GPU_MEMORY_MIB=90000
readonly MIN_DOCKER_FREE_GIB=350
readonly MIN_DRIVER_VERSION=580.65.06
readonly MIN_DOCKER_VERSION=28.3.3
readonly MAX_DOCKER_VERSION_EXCLUSIVE=29.5.0
readonly MIN_COMPOSE_VERSION=2.39.1

# `check` reports an incompatible Docker engine but does not prevent attendees
# from reaching the deployment step. On a clean Brev VM, `deploy` safely pins
# Docker CE to the newest supported 28.x package before starting VSS.
DOCKER_REQUIRES_PIN=0

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

version_at_least() {
  local actual="$1" minimum="$2"
  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" == "$minimum" ]]
}

version_before() {
  local actual="$1" maximum="$2"
  [[ "$actual" != "$maximum" ]] && [[ "$(printf '%s\n%s\n' "$actual" "$maximum" | sort -V | head -n1)" == "$actual" ]]
}

free_gib() {
  df -Pk "$1" | awk 'NR == 2 { printf "%d", $4 / 1024 / 1024 }'
}

host_ip() {
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

brev_url() {
  local env_id="${BREV_ENV_ID:-${BREV_INSTANCE_ID:-}}"
  local domain="${BREV_LINK_DOMAIN:-apps.run.brev.nvidia.com}"
  if [[ -n "$env_id" ]]; then
    printf 'https://7777-%s.%s' "$env_id" "$domain"
  else
    printf 'http://%s:7777' "$(host_ip)"
  fi
}

find_ephemeral_mount() {
  local candidate
  for candidate in /opt/dlami/nvme /ephemeral /data /mnt; do
    if [[ -d "$candidate" ]] && mountpoint -q "$candidate" && (( $(free_gib "$candidate") >= MIN_DOCKER_FREE_GIB )); then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

check_gpu_hardware() {
  require_command nvidia-smi

  local driver gpu_line gpu_name gpu_memory
  driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d '[:space:]')"
  version_at_least "$driver" "$MIN_DRIVER_VERSION" || die "NVIDIA driver ${driver} is older than the supported minimum ${MIN_DRIVER_VERSION}."

  local -a gpus=()
  mapfile -t gpus < <(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits)
  (( ${#gpus[@]} == REQUIRED_GPUS )) || die "This workshop requires exactly ${REQUIRED_GPUS} GPUs; found ${#gpus[@]}."

  for gpu_line in "${gpus[@]}"; do
    gpu_name="${gpu_line%,*}"
    gpu_memory="${gpu_line##*, }"
    [[ "$gpu_name" == *"RTX PRO 6000"* ]] || die "Expected RTX PRO 6000 GPUs; found: ${gpu_name}."
    [[ "$gpu_memory" =~ ^[0-9]+$ ]] && (( gpu_memory >= MIN_GPU_MEMORY_MIB )) || die "Expected at least ${MIN_GPU_MEMORY_MIB} MiB per GPU; found ${gpu_memory} MiB."
  done

  note "GPU check passed: 2 × RTX PRO 6000 (driver ${driver})."
}

check_docker() {
  require_command docker
  docker info >/dev/null 2>&1 || die "Docker is not running or your user cannot access it."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

  local docker_version compose_version
  docker_version="$(docker version --format '{{.Server.Version}}' | sed 's/[^0-9.].*$//')"
  compose_version="$(docker compose version --short | sed 's/[^0-9.].*$//')"
  version_at_least "$compose_version" "$MIN_COMPOSE_VERSION" || die "Docker Compose ${compose_version} is older than the required minimum ${MIN_COMPOSE_VERSION}."

  if ! version_at_least "$docker_version" "$MIN_DOCKER_VERSION" || ! version_before "$docker_version" "$MAX_DOCKER_VERSION_EXCLUSIVE"; then
    DOCKER_REQUIRES_PIN=1
    note "WARNING: Docker ${docker_version} is outside VSS's supported range (${MIN_DOCKER_VERSION} <= version < ${MAX_DOCKER_VERSION_EXCLUSIVE})."
    note "On this clean Brev VM, the deploy step will pin Docker CE to the newest compatible 28.x release and restart Docker."
    return 0
  fi

  DOCKER_REQUIRES_PIN=0
  note "Docker check passed: Docker ${docker_version} with Compose v2."
}

latest_supported_docker_ce_package() {
  local package_version engine_version
  apt-cache madison docker-ce | awk '{print $3}' | while IFS= read -r package_version; do
    engine_version="${package_version#*:}"
    engine_version="${engine_version%%-*}"
    if version_at_least "$engine_version" "$MIN_DOCKER_VERSION" && version_before "$engine_version" "$MAX_DOCKER_VERSION_EXCLUSIVE"; then
      printf '%s\n' "$package_version"
    fi
  done | sort -V | tail -n1
}

pin_docker_to_supported_version() {
  local package_version
  (( DOCKER_REQUIRES_PIN == 1 )) || return 0

  [[ "$(uname -s)" == Linux ]] || die "Docker ${MAX_DOCKER_VERSION_EXCLUSIVE}+ must be replaced with a supported version on Linux. Use the target Brev Ubuntu VM."
  require_command apt-cache
  require_command apt-get
  require_command dpkg-query
  [[ -z "$(docker ps -q)" ]] || die "Docker needs to be pinned, but containers are already running. Use a clean workshop VM before deploying."

  note "Refreshing Docker CE package metadata to select a VSS-supported engine."
  sudo apt-get update
  package_version="$(latest_supported_docker_ce_package)"
  [[ -n "$package_version" ]] || die "No compatible Docker CE package was found. Recreate the Brev VM with a VSS-compatible image or install Docker CE ${MIN_DOCKER_VERSION} through 28.x from Docker's apt repository."

  note "Installing Docker CE ${package_version}; Docker will restart."
  sudo apt-get install -y --allow-downgrades "docker-ce=${package_version}" "docker-ce-cli=${package_version}"
  sudo apt-mark hold docker-ce docker-ce-cli
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl restart docker
  else
    sudo service docker restart
  fi

  DOCKER_REQUIRES_PIN=0
  check_docker
  (( DOCKER_REQUIRES_PIN == 0 )) || die "Docker is still outside VSS's supported range after pinning."
  note "Docker has been pinned for this workshop. Run 'sudo apt-mark unhold docker-ce docker-ce-cli' after the event if this VM will be reused."
}

check_storage() {
  local docker_root docker_free ephemeral_mount
  docker_root="$(docker info --format '{{.DockerRootDir}}')"
  docker_free="$(free_gib "$docker_root")"
  ephemeral_mount="$(find_ephemeral_mount || true)"

  if (( docker_free < MIN_DOCKER_FREE_GIB )) && [[ -z "$ephemeral_mount" ]]; then
    die "Docker has ${docker_free} GiB free and no mounted ephemeral disk with ${MIN_DOCKER_FREE_GIB} GiB free was found. Attach or mount storage before deploying."
  fi

  note "Storage check passed: Docker has ${docker_free} GiB free; ephemeral mount: ${ephemeral_mount:-not detected}."
}

check_compose_graph() {
  VSS_APPS_DIR="$RUNTIME_DIR" \
  VSS_DATA_DIR="${VSS_WORKSHOP_DATA_DIR:-/tmp/vss-workshop-data}" \
  HOST_IP="${HOST_IP:-127.0.0.1}" \
  EXTERNAL_IP="${EXTERNAL_IP:-127.0.0.1}" \
  VSS_PUBLIC_HOST="${VSS_PUBLIC_HOST:-127.0.0.1}" \
  NGC_CLI_API_KEY="not-used-for-rendering" \
    docker compose --env-file "$DEFAULT_ENV_FILE" -f "$COMPOSE_FILE" config -q
  note "Base Compose graph passed validation."
}

run_check() {
  [[ -f "$COMPOSE_FILE" && -f "$DEFAULT_ENV_FILE" ]] || die "Workshop runtime is incomplete. Re-clone the workshop repository."
  check_gpu_hardware
  check_docker
  check_storage
  check_compose_graph
  if (( DOCKER_REQUIRES_PIN == 1 )); then
    note "Preflight complete with a managed Docker repair pending. GPU 0 is reserved for Nemotron Nano 9B v2; GPU 1 is reserved for Cosmos3 Nano Reasoner."
  else
    note "Preflight complete. GPU 0 is reserved for Nemotron Nano 9B v2; GPU 1 is reserved for Cosmos3 Nano Reasoner."
  fi
}

configure_docker_storage_if_needed() {
  local docker_root docker_free ephemeral_mount daemon_file new_root temporary_json
  docker_root="$(docker info --format '{{.DockerRootDir}}')"
  docker_free="$(free_gib "$docker_root")"
  (( docker_free >= MIN_DOCKER_FREE_GIB )) && return 0

  ephemeral_mount="$(find_ephemeral_mount)"
  new_root="${ephemeral_mount}/vss-workshop-docker"
  daemon_file=/etc/docker/daemon.json

  if [[ -f "$daemon_file" ]] && sudo grep -q '"data-root"' "$daemon_file"; then
    die "Docker needs more storage, but ${daemon_file} already sets data-root. Set VSS_WORKSHOP_DATA_DIR and have the instance owner move Docker storage before continuing."
  fi
  if [[ -n "$(docker ps -q)" ]]; then
    die "Docker needs to move its data-root, but containers are already running. Use a clean workshop instance or free Docker storage first."
  fi

  note "Moving Docker storage to ${new_root}; Docker will restart."
  sudo mkdir -p "$new_root" /etc/docker
  temporary_json="$(mktemp)"
  if [[ -f "$daemon_file" ]]; then
    sudo cp "$daemon_file" "$temporary_json"
  else
    printf '{}\n' > "$temporary_json"
  fi
  python3 - "$temporary_json" "$new_root" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["data-root"] = sys.argv[2]
path.write_text(json.dumps(data, indent=2) + "\n")
PY
  sudo install -m 0644 "$temporary_json" "$daemon_file"
  rm -f "$temporary_json"
  sudo systemctl restart docker
  docker info >/dev/null 2>&1 || die "Docker did not come back after moving its data-root."
}

make_private_environment() {
  local api_key host public_url public_host public_protocol public_ws_protocol public_port data_root
  api_key="${NGC_API_KEY:-}"
  if [[ -z "$api_key" ]]; then
    read -r -s -p 'Paste your NGC API key (input is hidden): ' api_key
    printf '\n'
  fi
  [[ -n "$api_key" ]] || die "An NGC API key is required to pull the NVIDIA containers and models."
  [[ "$api_key" != *$'\n'* && "$api_key" != *$'\r'* ]] || die "NGC_API_KEY must be a single line."

  host="$(host_ip)"
  [[ -n "$host" ]] || host=127.0.0.1
  public_url="$(brev_url)"
  public_protocol="${public_url%%://*}"
  public_host="${public_url#*://}"
  public_ws_protocol=ws
  public_port=7777
  [[ "$public_protocol" == https ]] && public_ws_protocol=wss
  [[ "$public_protocol" == https ]] && public_port=443
  data_root="${VSS_WORKSHOP_DATA_DIR:-}"
  if [[ -z "$data_root" ]]; then
    data_root="$(find_ephemeral_mount || true)"
    data_root="${data_root:-${HOME}/vss-workshop-data}"
  fi
  [[ "$data_root" == */vss-workshop-data ]] || data_root="${data_root}/vss-workshop-data"

  umask 077
  mkdir -p "$STATE_ROOT" "$data_root"
  cp "$DEFAULT_ENV_FILE" "$PRIVATE_ENV_FILE"
  cat >> "$PRIVATE_ENV_FILE" <<EOF

# Machine-local values written by deploy_vss_base.sh. Do not copy this file into Git.
VSS_APPS_DIR=${RUNTIME_DIR}
VSS_DATA_DIR=${data_root}
HOST_IP=${host}
EXTERNAL_IP=${host}
VSS_PUBLIC_HOST=${public_host}
VSS_PUBLIC_HTTP_PROTOCOL=${public_protocol}
VSS_PUBLIC_WS_PROTOCOL=${public_ws_protocol}
VSS_PUBLIC_PORT=${public_port}
VST_EXTERNAL_URL=${public_url}
VST_INTERNAL_URL=http://${host}:30888
VSS_AGENT_REPORTS_BASE_URL=${public_url}/static/
VSS_AGENT_EXTERNAL_URL=${public_url}
VST_CONFIG_PATH=${RUNTIME_DIR}/services/vios/configs
NGC_CLI_API_KEY=${api_key}
UID=$(id -u)
GID=$(id -g)
EOF
  chmod 600 "$PRIVATE_ENV_FILE"
}

compose() {
  docker compose --env-file "$PRIVATE_ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

pull_images_to_log() {
  note "Downloading VSS container images. The detailed layer progress is recorded in ${DEPLOY_LOG}."
  note "This can take several minutes; open a terminal and run 'tail -f ${DEPLOY_LOG}' only if you want the live pull detail."
  if ! compose pull >>"$DEPLOY_LOG" 2>&1; then
    note "Image download failed. The last 50 deployment-log lines follow:"
    tail -n 50 "$DEPLOY_LOG" >&2 || true
    die "Unable to download one or more VSS container images."
  fi
  note "Container images are ready. Starting Base services."
}

wait_for_service() {
  local service="$1" timeout_seconds="$2" elapsed=0 status
  while (( elapsed < timeout_seconds )); do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$service" 2>/dev/null || true)"
    if [[ "$status" == healthy || "$status" == running ]]; then
      return 0
    fi
    if [[ "$status" == unhealthy || "$status" == exited || "$status" == dead ]]; then
      docker logs --tail 50 "$service" >&2 || true
      return 1
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  return 1
}

run_deploy() {
  run_check
  pin_docker_to_supported_version
  configure_docker_storage_if_needed
  make_private_environment

  printf '%s' "${NGC_API_KEY:-$(sed -n 's/^NGC_CLI_API_KEY=//p' "$PRIVATE_ENV_FILE")}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
  compose config -q
  pull_images_to_log
  if ! compose up -d --pull never >>"$DEPLOY_LOG" 2>&1; then
    note "Service startup failed. The last 50 deployment-log lines follow:"
    tail -n 50 "$DEPLOY_LOG" >&2 || true
    die "Unable to start the VSS Base services."
  fi
  note "Base services started. The first model initialization can take 15–25 minutes."

  wait_for_service nvidia-nemotron-nano-9b-v2 1500 || die "Nemotron did not become healthy. Run '$0 status' and inspect ${DEPLOY_LOG}."
  wait_for_service nvidia-cosmos3-reasoner 1500 || die "Cosmos3 Reasoner did not become healthy. Run '$0 status' and inspect ${DEPLOY_LOG}."
  wait_for_service vss-agent 420 || die "VSS Agent did not become healthy. Run '$0 status'."
  wait_for_service vss-agent-ui 180 || die "VSS UI did not become healthy. Run '$0 status'."

  note "VSS is ready: $(brev_url)"
  note "In Brev, open or create a secure link for port 7777 only, then use that URL if it differs from the one above."
}

run_status() {
  if [[ ! -f "$PRIVATE_ENV_FILE" ]]; then
    note "No local workshop deployment state found at ${PRIVATE_ENV_FILE}. Run deploy first."
    return 0
  fi
  compose ps
  if curl --fail --silent --max-time 5 http://127.0.0.1:7777/ >/dev/null; then
    note "UI endpoint responds locally. Brev UI: $(brev_url)"
  else
    note "UI endpoint is not responding yet. Model initialization can take 15–25 minutes on first run."
  fi
}

run_stop() {
  if [[ ! -f "$PRIVATE_ENV_FILE" ]]; then
    note "No local workshop deployment state found; nothing to stop."
    return 0
  fi
  compose stop
  note "Services stopped. Videos, model caches, Docker volumes, and ${PRIVATE_ENV_FILE} were preserved."
}

usage() {
  cat <<'EOF'
Usage: workshop/scripts/deploy_vss_base.sh check|deploy|status|stop

check   Verify two RTX PRO 6000 GPUs, driver, Docker, storage, and the Base Compose graph.
deploy  Configure storage if required, authenticate to NVCR, start VSS, and wait for the UI.
status  Show Compose health and the local/Brev UI endpoint.
stop    Stop services without deleting videos, caches, Docker volumes, or deployment state.
EOF
}

case "${1:-}" in
  check) run_check ;;
  deploy) run_deploy ;;
  status) run_status ;;
  stop) run_stop ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
