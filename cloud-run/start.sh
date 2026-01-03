#!/bin/sh
# Startup script for Cloud Run chisel tunnel server
# Sets up environment and starts supervisor

set -e

# Validate AUTH environment variable
if [ -z "$AUTH" ]; then
    echo "ERROR: AUTH environment variable is required"
    echo "Format: username:password"
    exit 1
fi

# Export for supervisor
export AUTH

# Default REMOTE_UI_ENABLED to empty (disabled) if not set
export REMOTE_UI_ENABLED="${REMOTE_UI_ENABLED:-}"

# Substitute env vars in nginx.conf
envsubst '${REMOTE_UI_ENABLED}' < /etc/nginx/nginx.conf > /tmp/nginx.conf
mv /tmp/nginx.conf /etc/nginx/nginx.conf

echo "=== GCP Tunnel Server Starting ==="
echo "nginx listening on :8080 (external)"
echo "chisel listening on :9000 (internal)"
echo "reverse tunnel on :9001 (internal)"
echo "Remote UI: ${REMOTE_UI_ENABLED:-disabled}"
echo "=================================="

# Start supervisor (runs nginx + chisel)
exec /usr/bin/supervisord -c /etc/supervisord.conf
