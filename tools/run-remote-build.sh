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
    --exclude 'build-metrics/' \
    --exclude 'chatbot-ui/node_modules/' \
    --exclude 'peertube/docker-volume/' \
    --exclude 'tools/freeman/target/' \
    --exclude '*.log' \
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

# Connect and run the full build with passwordless sudo or prompt. Keep logs
# outside the synced workspace so the build cannot overwrite or transfer them.
set +e
sshpass -p "$SSH_PASS" ssh -t "${SSH_ARGS[@]}" "$REMOTE_HOST" "bash -s -- '$REMOTE_DIR'" <<'REMOTE_BUILD_SCRIPT'
set -uo pipefail

REMOTE_DIR="$1"
LOG_DIR="/.log"

sudo mkdir -p "$LOG_DIR"
sudo chown "$(id -un):$(id -gn)" "$LOG_DIR"

log_number=1
while :; do
    log_file="$LOG_DIR/${log_number}.log"
    if (set -o noclobber; : > "$log_file") 2>/dev/null; then
        break
    fi
    ((log_number += 1))
done

printf 'Remote build log: %s\n' "$log_file"
cd "$REMOTE_DIR" || exit 1

set +e
sudo ./build.sh 2>&1 | tee "$log_file"
pipeline_status=(${PIPESTATUS[@]})
set -e

exit "${pipeline_status[0]}"
REMOTE_BUILD_SCRIPT
BUILD_STATUS=$?
set -e

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

# Launch interactive gnome-terminal and wait for completion. Fall back to
# running the build stream in the current terminal when no display is usable.
display_ok() {
    [[ -n "${DISPLAY:-}" ]] || return 1
    if command -v xdpyinfo >/dev/null 2>&1; then
        timeout 5 xdpyinfo >/dev/null 2>&1
    elif command -v xset >/dev/null 2>&1; then
        xset -q >/dev/null 2>&1
    else
        return 0
    fi
}

echo "==> Launching build monitoring terminal..."
if display_ok; then
    gnome-terminal --wait --title="AcreetionOS Horizon - Remote Build Stream" -- \
        "$BUILD_RUNNER_SCRIPT" "$REMOTE_TARGET_DIR" "$REMOTE_HOST" "$US_SSH_PASSWORD" "${PORT_ARG[@]}"
else
    printf 'No usable display for GNOME Terminal; streaming remote build here.\n'
    "$BUILD_RUNNER_SCRIPT" "$REMOTE_TARGET_DIR" "$REMOTE_HOST" "$US_SSH_PASSWORD" "${PORT_ARG[@]}"
fi

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

# ---------------------------------------------------------------------------
# Publish the ISO to the Community Edition folder on the remote server.
# /drive1/community is exposed publicly via nginx at
# https://us.iso.acreetionos.org:8448/community/
# ---------------------------------------------------------------------------
COMMUNITY_DIR="/drive1/community/Horizon"
echo "==> Publishing ISO to Community Edition folder on server..."
sshpass -p "$US_SSH_PASSWORD" ssh "${PORT_ARG[@]}" "$REMOTE_HOST" "mkdir -p /drive1/community/Horizon"

# Rotate existing copies on the server (.iso -> .iso.1 -> .iso.2 ...)
sshpass -p "$US_SSH_PASSWORD" ssh "${PORT_ARG[@]}" "$REMOTE_HOST" "
set -e
BASE=/drive1/community/Horizon/$ISO_BASENAME
if [ -e \"\$BASE\" ]; then
    MAX=0
    for FILE in "\$BASE".*; do
        [ -f "\$FILE" ] || continue
        SUFFIX=\${FILE##*.}
        case "\$SUFFIX" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "\$SUFFIX" -gt "\$MAX" ] && MAX=\$SUFFIX
    done
    for (( i=MAX; i>=1; i-- )); do
        [ -f \"\$BASE.\$i\" ] && mv \"\$BASE.\$i\" \"\$BASE.\$((i+1))\"
    done
    mv \"\$BASE\" \"\$BASE.1\"
fi
"

sshpass -p "$US_SSH_PASSWORD" ssh "${PORT_ARG[@]}" "$REMOTE_HOST" "cp -f '$REMOTE_ISO' /drive1/community/Horizon/$ISO_BASENAME && chmod 644 /drive1/community/Horizon/$ISO_BASENAME"
# Publish SHA256SUMS for the Horizon folder (overwrite with the current build's sums)
sshpass -p "$US_SSH_PASSWORD" ssh "${PORT_ARG[@]}" "$REMOTE_HOST" "cd \$(dirname '$REMOTE_ISO') && sha256sum \$(basename '$REMOTE_ISO') > /drive1/community/Horizon/SHA256SUMS && chmod 644 /drive1/community/Horizon/SHA256SUMS" 2>/dev/null || true
# Refresh the -latest symlink for Horizon
sshpass -p "$US_SSH_PASSWORD" ssh "${PORT_ARG[@]}" "$REMOTE_HOST" "ln -sf '$ISO_BASENAME' /drive1/community/Horizon/AcreetionOS-Horizon-latest.iso"

DOWNLOAD_URL="https://us.iso.acreetionos.org:8448/community/Horizon/$ISO_BASENAME"
LATEST_URL="https://us.iso.acreetionos.org:8448/community/Horizon/AcreetionOS-Horizon-latest.iso"

# Verify the public URL responds
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 -I "$DOWNLOAD_URL" 2>/dev/null || echo "000")

echo "===================================================================="
echo "  ISO Published to Community Edition"
echo "  Saved locally to: $OUTPUT_BASE/$ISO_BASENAME"
echo "  Download URL:     $DOWNLOAD_URL"
echo "  Latest symlink:   $LATEST_URL"
echo "  HTTP status:      $HTTP_CODE"
echo "===================================================================="

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "==> Opening download link in your default browser..."
    xdg-open "$DOWNLOAD_URL" >/dev/null 2>&1 &
else
    echo "Warning: published URL did not return 200 (got $HTTP_CODE). Open manually:"
    echo "  $LATEST_URL"
fi
