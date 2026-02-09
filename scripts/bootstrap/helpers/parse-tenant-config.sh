#!/bin/bash
# Parse tenant configuration and export variables
#
# Usage:
#   source ./helpers/parse-tenant-config.sh <ENV>
#   # Sets: SERVER_IP, ROOT_PASSWORD, WORKER_NODES, WORKER_PASSWORD

set -e

ENV="$1"

# If ENV not provided, read from bootstrap config
if [[ -z "$ENV" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    source "$REPO_ROOT/scripts/bootstrap/helpers/bootstrap-config.sh"
    ENV=$(read_bootstrap_env)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to read environment from bootstrap config" >&2
        exit 1
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fetch tenant config only if not already set
if [[ -z "${TENANT_CONFIG_FILE:-}" ]] || [[ ! -f "$TENANT_CONFIG_FILE" ]]; then
    source "$SCRIPT_DIR/fetch-tenant-config.sh" "$ENV" --use-cache
fi

# Parse values using Python
TENANT_VALUES=$(python3 - <<EOF
import yaml
with open('$TENANT_CONFIG_FILE', 'r') as f:
    data = yaml.safe_load(f)

cp = data['controlplane']
print(f"{cp['ip']}")
print(f"{cp['rescue_password']}")

workers = data.get('workers', [])
if workers:
    for w in workers:
        print(f"{w['name']}:{w['ip']}:{w['rescue_password']}")
EOF
)

# Parse the output
IFS=$'\n' read -d '' -r -a lines <<< "$TENANT_VALUES" || true
export SERVER_IP="${lines[0]}"
export ROOT_PASSWORD="${lines[1]}"

# Build worker nodes string if workers exist
if [ ${#lines[@]} -gt 2 ]; then
    export WORKER_NODES=""
    WORKER_PASSWORDS=()
    for ((i=2; i<${#lines[@]}; i++)); do
        IFS=':' read -r name ip pwd <<< "${lines[$i]}"
        if [ -n "$WORKER_NODES" ]; then
            WORKER_NODES="$WORKER_NODES,"
        fi
        WORKER_NODES="$WORKER_NODES$name:$ip"
        WORKER_PASSWORDS+=("$pwd")
    done
    # Use first worker password (assuming all same for now)
    export WORKER_PASSWORD="${WORKER_PASSWORDS[0]}"
else
    export WORKER_NODES=""
    export WORKER_PASSWORD=""
fi

echo "✓ Configuration parsed from tenant repo" >&2
echo "  Control Plane: $SERVER_IP" >&2
[ -n "$WORKER_NODES" ] && echo "  Workers: $WORKER_NODES" >&2
