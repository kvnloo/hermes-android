#!/usr/bin/env bash
set -euo pipefail

log=$(mktemp)
trap 'rm -f "$log"' EXIT

if "$@" 2>&1 | tee "$log"; then
    exit 0
else
    status=( "${PIPESTATUS[@]}" )
fi

# A generic Gradle "Could not resolve" can also mean a missing dependency.
# Retry only when the output shows a transport failure or rate limit.
if (( status[0] != 0 && status[1] == 0 )) &&
    grep -Eiq 'status code[[:space:]:]+429\b|HTTP(/[0-9.]+)?[[:space:]]+429\b|429[[:space:]]+Too Many Requests|Could not resolve host|Temporary failure in name resolution|UnknownHostException|Connection reset' "$log"; then
    echo "Network error during Android build; retrying once in 60 seconds." >&2
    sleep 60
    "$@"
else
    # Preserve the build failure, or report the logging failure if it built.
    exit "$((status[0] != 0 ? status[0] : status[1]))"
fi
