#!/usr/bin/env bash
# Build and run the Hermes-on-Render image locally with Docker.
#
# This mirrors what Render does (build this repo's Dockerfile, run the
# container) so you can try the image, debug the config patcher, or run
# Hermes on your own hardware.
#
# AWS Bedrock credentials, if you want them, are pulled automatically from
# your AWS CLI config via `aws configure export-credentials` — no copying
# and pasting keys. That command resolves static keys, SSO sessions,
# assumed roles, and temporary/STS credentials (session token included),
# using whatever AWS_PROFILE / AWS_REGION your shell already points at.
#
# Configuration is read from a gitignored `.env.local` at the repo root
# (copy `.env.local.example` to `.env.local` and fill it in). Values
# already set in your shell environment win over the file, so you can
# still do a one-off override like `USE_BEDROCK=1 scripts/run-local.sh`.
#
# Usage:
#   cp .env.local.example .env.local && $EDITOR .env.local   # first-time setup
#   scripts/run-local.sh                   # run (build if image missing)
#   BUILD=1 scripts/run-local.sh           # force a rebuild first
#   USE_BEDROCK=1 scripts/run-local.sh     # inject AWS creds for Bedrock
#
# Env vars honored (in `.env.local` or the shell):
#   IMAGE                image tag to build/run    (default: hermes-render)
#   PORT                 host port for dashboard    (default: 10000)
#   DATA_DIR             host dir mounted at /opt/data (default: ./hermes-data)
#   RENDER_MCP_API_KEY   optional; enables Render MCP tools
#   USE_BEDROCK          "1" to pull + inject AWS creds for Bedrock
#   AWS_PROFILE          optional; which AWS CLI profile to read
#   AWS_REGION           optional; overrides the profile's region
#   BUILD                "1" to force `docker build` before running
#   ENV_FILE             path to the env file to load (default: ./.env.local)

set -euo pipefail

# Resolve the repo root from this script's location so it works from anywhere.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env.local}"

# Load the .env file if present. Shell-exported vars take precedence: we
# only set a key from the file when it isn't already in the environment.
if [ -f "${ENV_FILE}" ]; then
  echo ">>> Loading config from ${ENV_FILE}"
  while IFS= read -r line || [ -n "${line}" ]; do
    # Skip blank lines and comments.
    case "${line}" in ''|'#'*) continue ;; esac
    line="${line#export }"          # tolerate `export KEY=value`
    key="${line%%=*}"
    val="${line#*=}"
    # Only assign well-formed KEY=value lines with a shell-safe name.
    case "${key}" in
      ''|*[!A-Za-z0-9_]*) continue ;;
    esac
    # Strip one layer of surrounding quotes from the value, if present.
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    # Don't clobber a value already set in the shell environment.
    if [ -z "${!key:-}" ]; then
      export "${key}=${val}"
    fi
  done < "${ENV_FILE}"
fi

IMAGE="${IMAGE:-hermes-render}"
PORT="${PORT:-10000}"
DATA_DIR="${DATA_DIR:-$PWD/hermes-data}"

# Build if asked, or if the image doesn't exist yet.
if [ "${BUILD:-0}" = "1" ] || ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo ">>> Building ${IMAGE} (first build pulls the ~2.6 GB upstream base)..."
  docker build -t "${IMAGE}" .
fi

# Base run args: dashboard env from render.yaml + the persistent-disk mount.
args=(
  --rm -it
  -p "${PORT}:10000"
  -v "${DATA_DIR}:/opt/data"
  -e HERMES_DASHBOARD=1
  -e HERMES_DASHBOARD_HOST=0.0.0.0
  -e HERMES_DASHBOARD_PORT=10000
  -e HERMES_DASHBOARD_TUI=1
)

# Render MCP key: only inject if it's set in the environment.
if [ -n "${RENDER_MCP_API_KEY:-}" ]; then
  args+=(-e "RENDER_MCP_API_KEY=${RENDER_MCP_API_KEY}")
fi

# AWS Bedrock: pull resolved credentials from the AWS CLI and inject them.
if [ "${USE_BEDROCK:-0}" = "1" ]; then
  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: USE_BEDROCK=1 but the 'aws' CLI is not on PATH." >&2
    exit 1
  fi
  echo ">>> Pulling AWS credentials via 'aws configure export-credentials'..."
  # --format env-no-export prints KEY=VALUE lines (AWS_ACCESS_KEY_ID,
  # AWS_SECRET_ACCESS_KEY, and AWS_SESSION_TOKEN when present). Write them
  # to a temp env-file and hand it to docker so keys never hit argv/ps.
  creds_file="$(mktemp)"
  trap 'rm -f "${creds_file}"' EXIT
  aws configure export-credentials --format env-no-export > "${creds_file}"
  # Region isn't part of exported credentials; resolve it separately.
  region="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
  if [ -n "${region}" ]; then
    echo "AWS_REGION=${region}" >> "${creds_file}"
  else
    echo "WARNING: no AWS region found; set AWS_REGION or 'aws configure set region ...'." >&2
  fi
  args+=(--env-file "${creds_file}")
fi

echo ">>> Starting ${IMAGE}; dashboard will be at http://localhost:${PORT}"
docker run "${args[@]}" "${IMAGE}"
