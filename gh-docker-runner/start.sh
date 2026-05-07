#!/bin/bash
set -euo pipefail

# Fetch registration token via PAT if RUNNER_TOKEN not provided
if [ -z "${RUNNER_TOKEN:-}" ] && [ -n "${GITHUB_PAT:-}" ]; then
    if [ -n "${RUNNER_ORG:-}" ]; then
        RUNNER_TOKEN=$(curl -fsSX POST \
            -H "Authorization: token ${GITHUB_PAT}" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/orgs/${RUNNER_ORG}/actions/runners/registration-token" \
            | jq -r .token)
    elif [ -n "${RUNNER_REPO:-}" ]; then
        RUNNER_TOKEN=$(curl -fsSX POST \
            -H "Authorization: token ${GITHUB_PAT}" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/${RUNNER_REPO}/actions/runners/registration-token" \
            | jq -r .token)
    else
        echo "ERROR: set RUNNER_ORG or RUNNER_REPO when using GITHUB_PAT" >&2
        exit 1
    fi
fi

if [ -z "${RUNNER_TOKEN:-}" ]; then
    echo "ERROR: RUNNER_TOKEN or GITHUB_PAT required" >&2
    exit 1
fi

if [ -z "${RUNNER_URL:-}" ]; then
    echo "ERROR: RUNNER_URL required (e.g. https://github.com/myorg or https://github.com/myorg/myrepo)" >&2
    exit 1
fi

/home/runner/config.sh \
    --url "${RUNNER_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME:-$(hostname)}" \
    --labels "${RUNNER_LABELS:-self-hosted}" \
    --runnergroup "${RUNNER_GROUP:-Default}" \
    --work "_work" \
    --unattended \
    --replace

cleanup() {
    echo "Removing runner..."
    /home/runner/config.sh remove --unattended --token "${RUNNER_TOKEN}" || true
}
trap cleanup EXIT INT TERM

/home/runner/run.sh
