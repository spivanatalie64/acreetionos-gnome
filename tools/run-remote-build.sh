#!/usr/bin/env bash
# ==============================================================================
#  AcreetionOS Horizon - Remote US SSH Build & Fetch Runner
# ==============================================================================
#  1. Syncs/verifies remote build directory on us.iso.acreetionos.org
#  2. Spawns and streams build execution inside a live interactive gnome-terminal
#  3. Automatically creates local ~/ISO_OUTPUT/Horizon/ directories if missing
#  4. Rotates existing ISOs (.iso -> .iso.1 -> .iso.2 -> .iso.3...)
#  5. Fetches the newly built ISO from the remote build host
# ==============================================================================

set -euo pipefail

LOCAL_DIR="/home/natalie/Projects/acreetionos-gnome"
OUTPUT_BASE="$HOME/ISO_OUTPUT/Horizon"
REMOTE_TARGET_DIR="${1:-/home/natalie/Projects/acreetionos-gnome}"

mkdir -p "$OUTPUT_BASE"

if [[ -z "${US_SSH:-}" || -z "${US_SSH_PASSWORD:-}" ]]; then
    # Source bashrc to obtain credentials if not in environment
    if [[ -f "$HOME/.bashrc" ]]; then
        # shellcheck disable=SC1090
        source <(grep -E '^(export )?US_SSH' "$HOME/.bashrc") || true
    fi
fi

if [[ -z "${US_SSH:-}" || -z "${US_SSH_PASSWORD:-}" ]]; then
    echo "Error: US_SSH and US_SSH_PASSWORD must be defined in environment or ~/.bashrc" >&2
    exit 1
fi

# Split US_SSH into user@host and port
read -r REMOTE_HOST SSH_FLAG REMOTE_PORT <<< "$US_SSH"
PORT_ARG=()
SCP_PORT_ARG=()
if [[ "$SSH_FLAG" == "-p" && -n "$REMOTE_PORT" ]]; then
    PORT_ARG=("-p" "$REMOTE_PORT")
    SCP_PORT_ARG=("-P" "$REMOTE_PORT")
fi

# Function to rotate files: filename.iso -> filename.iso.1 -> filename.iso.2 ...
rotate_iso_if_exists() {
    local base_name="$1"
    local full_path="$OUTPUT_BASE/$base_name"

    if [[ ! -e "$full_path" ]]; then
        return 0
    fi

    # Find highest existing suffix
    local max=0
    for file in "$full_path".*; do
        if [[ -f "$file" ]]; then
            local suffix="${file##*.}"
            if [[ "$suffix" =~ ^[0-9]+$ ]]; then
                if (( suffix > max )); then
                    max=$suffix
                fi
            fi
        fi
    done

    # Shift upward: .N -> .N+1
    for (( i=max; i>=1; i-- )); do
        if [[ -f "$full_path.$i" ]]; then
            mv "$full_path.$i" "$full_path.$((i+1))"
            echo "Rotated: $base_name.$i -> $base_name.$((i+1))"
        fi
    done

    # Move current to .1
    mv "$full_path" "$full_path.1"
    echo "Rotated existing ISO: $base_name -> $base_name.1"
}

echo "===================================================================="
echo "  AcreetionOS Horizon - US SSH Remote Build Launcher"
echo "===================================================================="
echo "  Remote server: $REMOTE_HOST"
echo "  Remote dir:    $REMOTE_TARGET_DIR"
echo "  Output target: $OUTPUT_BASE"
echo "===================================================================="

# Sync the current git branch / changes to the remote build workspace
echo "==> Preparing remote build directory..."
sshpass -p "$US_SSH_PASSWORD" ssh -o StrictHostKeyChecking=accept-new "${PORT_ARG[@]}" "$REMOTE_HOST" "mkdir -p '$REMOTE_TARGET_DIR'"

# Use rsync to upload workspace excluding build artifacts
echo "==> Synchronizing local repository changes to build server..."
sshpass -p "$US_SSH_PASSWORD" rsync -avz --delete \
    -e "ssh ${PORT_ARG[*]}" \
    --exclude '.git/' \
    --exclude 'work/' \
    --exclude 'out/' \
    --exclude '.horizon-build/' \
    --exclude 'chatbot-ui/node_modules/' \
    --exclude 'peertube/docker-volume/' \
    --exclude 'tools/freeman/target/' \
    "$LOCAL_DIR/" "$REMOTE_HOST:$REMOTE_TARGET_DIR/"

# Script to run inside the live gnome-terminal window
BUILD_RUNNER_SCRIPT="/tmp/horizon-remote-runner.sh"
cat <<'EOF' > "$BUILD_RUNNER_SCRIPT"
#!/usr/bin/env bash
set -euo pipefail

REMOTE_DIR="$1"
shift
REMOTE_HOST="$1"
shift
SSH_PASS="$1"
shift
SSH_ARGS=("$@")

echo "===================================================================="
echo "  AcreetionOS Horizon - LIVE REMOTE BUILD STREAM"
echo "===================================================================="
echo "Connecting to remote build server..."

# Connect and run full build with passwordless sudo or prompt
sshpass -p "$SSH_PASS" ssh -t "${SSH_ARGS[@]}" "$REMOTE_HOST" "cd '$REMOTE_DIR' && sudo ./build.sh"
BUILD_STATUS=$?

echo ""
if [[ $BUILD_STATUS -eq 0 ]]; then
    echo "===================================================================="
    echo "  REMOTE BUILD FINISHED SUCCESSFULLY!"
    echo "===================================================================="
else
    echo "===================================================================="
    echo "  REMOTE BUILD FAILED WITH EXIT CODE $BUILD_STATUS"
    echo "===================================================================="
fi

echo "Press Enter or close this terminal to proceed to artifact retrieval."
read -r
exit $BUILD_STATUS
EOF

chmod +x "$BUILD_RUNNER_SCRIPT"

# Launch interactive gnome-terminal and wait for completion
echo "==> Launching build monitoring terminal..."
gnome-terminal --wait --title="AcreetionOS Horizon - Remote Build Stream" -- \
    "$BUILD_RUNNER_SCRIPT" "$REMOTE_TARGET_DIR" "$REMOTE_HOST" "$US_SSH_PASSWORD" "${PORT_ARG[@]}"

rm -f "$BUILD_RUNNER_SCRIPT"

# Now find newly created ISO on the remote server
echo "==> Querying remote server for generated ISO image..."
REMOTE_ISO=$(sshpass -p "$US_SSH_PASSWORD" ssh "${PORT_ARG[@]}" "$REMOTE_HOST" "ls -t '$REMOTE_TARGET_DIR/../ISO'/*.iso '$REMOTE_TARGET_DIR/out'/*.iso 2>/dev/null | head -n1" || true)

if [[ -z "$REMOTE_ISO" ]]; then
    echo "Warning: No ISO found in remote ../ISO or out directories. Check build logs in terminal."
    exit 1
fi

ISO_BASENAME=$(basename "$REMOTE_ISO")
echo "Found remote ISO: $ISO_BASENAME ($REMOTE_ISO)"

# Rotate any existing ISO matching this name in ~/ISO_OUTPUT/Horizon/
rotate_iso_if_exists "$ISO_BASENAME"

# Download the ISO
echo "==> Downloading ISO to $OUTPUT_BASE/$ISO_BASENAME ..."
sshpass -p "$US_SSH_PASSWORD" scp "${SCP_PORT_ARG[@]}" "$REMOTE_HOST:$REMOTE_ISO" "$OUTPUT_BASE/$ISO_BASENAME"

# Download checksums if present
sshpass -p "$US_SSH_PASSWORD" scp "${SCP_PORT_ARG[@]}" "$REMOTE_HOST:$(dirname "$REMOTE_ISO")/*SUMS" "$OUTPUT_BASE/" 2>/dev/null || true

echo "===================================================================="
echo "  ISO Download Complete!"
echo "  Saved to: $OUTPUT_BASE/$ISO_BASENAME"
ls -lh "$OUTPUT_BASE/$ISO_BASENAME"
echo "===================================================================="
