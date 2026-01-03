#!/bin/bash
#
# GCP Home Assistant Tunnel + Google Assistant Setup
#
# This script automates:
# - Cloud Run tunnel deployment (chisel server)
# - Google Assistant Smart Home Action creation
# - Home Assistant configuration
#
# Prerequisites:
# - gcloud CLI installed and in PATH
# - gactions CLI installed and in PATH (optional)
# - SSH access to Home Assistant (ssh ha)
#

# Strict mode - but we handle errors explicitly
set -o pipefail

# Get script directory for relative paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../output"

# Colors (only if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# Configuration with defaults
REGION="${GCP_REGION:-us-central1}"
CHISEL_VERSION="${CHISEL_VERSION:-1.9.1}"
CHISEL_IMAGE="jpillora/chisel:${CHISEL_VERSION}"
SERVICE_NAME="${SERVICE_NAME:-ha-tunnel}"
SA_NAME="${SA_NAME:-ha-assistant}"
TUNNEL_AUTH_USER="${TUNNEL_AUTH_USER:-hauser}"

# Generate secure password if not provided
if [ -z "$TUNNEL_AUTH_PASS" ]; then
    TUNNEL_AUTH_PASS="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
fi

# Logging functions
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; cleanup_on_error; exit 1; }

header() {
    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN} $1${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
}

# Track created resources for cleanup
CREATED_RESOURCES=()

cleanup_on_error() {
    if [ ${#CREATED_RESOURCES[@]} -eq 0 ]; then
        return
    fi

    echo ""
    warn "Setup failed. Created resources:"
    for resource in "${CREATED_RESOURCES[@]}"; do
        echo "  - $resource"
    done
    echo ""
    warn "To clean up manually:"
    echo "  gcloud projects delete $PROJECT_ID"
    echo ""
}

# Check if running interactively
is_interactive() {
    [ -t 0 ]
}

# Prompt with default (works in non-interactive mode)
prompt() {
    local prompt_text="$1"
    local default="$2"
    local var_name="$3"

    if is_interactive; then
        read -p "$prompt_text [$default]: " value
        value="${value:-$default}"
    else
        value="$default"
        log "Non-interactive mode, using default: $default"
    fi

    eval "$var_name=\"$value\""
}

# Check prerequisites
check_prerequisites() {
    header "Checking Prerequisites"

    # Check gcloud
    if ! command -v gcloud &> /dev/null; then
        error "gcloud CLI not found. Install from: https://cloud.google.com/sdk/docs/install"
    fi
    success "gcloud CLI found: $(gcloud --version 2>/dev/null | head -1)"

    # Check gactions (optional)
    if ! command -v gactions &> /dev/null; then
        warn "gactions CLI not found. Install from: https://developers.google.com/assistant/actionssdk/gactions"
        warn "Smart Home Action will require manual setup"
        SKIP_GACTIONS=true
    else
        success "gactions CLI found"
    fi

    # Check ssh
    if ! command -v ssh &> /dev/null; then
        error "ssh not found"
    fi
    success "ssh found"

    # Check openssl (for password generation)
    if ! command -v openssl &> /dev/null; then
        error "openssl not found (needed for secure password generation)"
    fi
    success "openssl found"

    # Test SSH connectivity to HA
    log "Testing SSH connection to Home Assistant..."
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes ha 'echo ok' &>/dev/null; then
        error "Cannot connect to HA via 'ssh ha'. Ensure SSH is configured."
    fi
    success "SSH to HA working"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"
}

# Authenticate with Google Cloud
authenticate_gcloud() {
    header "Google Cloud Authentication"

    local current_account
    current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || echo "")

    if [ -n "$current_account" ]; then
        log "Currently authenticated as: $current_account"
        if is_interactive; then
            read -p "Use this account? [Y/n] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                gcloud auth login || error "Authentication failed"
            fi
        fi
    else
        log "Please authenticate with Google Cloud..."
        gcloud auth login || error "Authentication failed"
    fi
    success "Authenticated with Google Cloud"
}

# Create or select GCP project
setup_project() {
    header "GCP Project Setup"

    # Generate unique project ID
    local timestamp
    timestamp=$(date +%s | tail -c 7)
    local default_project_id="ha-tunnel-${timestamp}"

    prompt "Enter project ID" "$default_project_id" PROJECT_ID

    # Validate project ID format
    if ! [[ "$PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
        error "Invalid project ID. Must be 6-30 lowercase letters, digits, or hyphens."
    fi

    # Check if project exists
    if gcloud projects describe "$PROJECT_ID" &>/dev/null; then
        log "Project $PROJECT_ID already exists, using it"
    else
        log "Creating project: $PROJECT_ID"
        if ! gcloud projects create "$PROJECT_ID" --name="HA Tunnel"; then
            error "Failed to create project. You may have hit project quota."
        fi
        CREATED_RESOURCES+=("project:$PROJECT_ID")
    fi

    # Set as current project
    gcloud config set project "$PROJECT_ID" --quiet
    success "Using project: $PROJECT_ID"

    # Check and enable billing
    local billing_enabled
    billing_enabled=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "false")

    if [ "$billing_enabled" != "True" ]; then
        log "Billing not enabled, attempting to link billing account..."

        # Find available billing account
        local billing_account
        billing_account=$(gcloud billing accounts list --filter="open=true" --format="value(name)" --limit=1 2>/dev/null || echo "")

        if [ -n "$billing_account" ]; then
            log "Found billing account: $billing_account"
            if gcloud billing projects link "$PROJECT_ID" --billing-account="$billing_account" 2>/dev/null; then
                success "Billing account linked automatically"
            else
                warn "Failed to link billing automatically"
                link_billing_manually
            fi
        else
            warn "No billing account found"
            link_billing_manually
        fi
    else
        success "Billing already enabled"
    fi
}

# Helper to prompt for manual billing setup
link_billing_manually() {
    warn "Please enable billing manually:"
    warn "  https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"

    if is_interactive; then
        read -p "Press Enter after enabling billing (or Ctrl+C to abort)..."
        # Verify billing was enabled
        local billing_check
        billing_check=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "false")
        if [ "$billing_check" != "True" ]; then
            error "Billing still not enabled. Cannot continue."
        fi
        success "Billing enabled"
    else
        error "Billing must be enabled. Run script interactively or link billing first."
    fi
}

# Enable required APIs
enable_apis() {
    header "Enabling APIs"

    local apis=(
        "run.googleapis.com"
        "homegraph.googleapis.com"
        "secretmanager.googleapis.com"
    )

    for api in "${apis[@]}"; do
        log "Enabling $api..."
        if ! gcloud services enable "$api" --quiet; then
            error "Failed to enable $api"
        fi
        success "Enabled $api"
    done
}

# Store credentials in Secret Manager
store_credentials() {
    header "Storing Credentials in Secret Manager"

    local secret_name="ha-tunnel-auth"
    local secret_value="${TUNNEL_AUTH_USER}:${TUNNEL_AUTH_PASS}"

    # Check if secret exists
    if gcloud secrets describe "$secret_name" &>/dev/null; then
        log "Secret already exists, creating new version..."
        echo -n "$secret_value" | gcloud secrets versions add "$secret_name" --data-file=- --quiet
    else
        log "Creating secret: $secret_name"
        echo -n "$secret_value" | gcloud secrets create "$secret_name" --data-file=- --quiet
        CREATED_RESOURCES+=("secret:$secret_name")
    fi

    # Grant Cloud Run default SA access to the secret
    local project_number
    project_number=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null)

    if [ -n "$project_number" ]; then
        local compute_sa="${project_number}-compute@developer.gserviceaccount.com"
        log "Granting secret access to Cloud Run SA: $compute_sa"
        gcloud secrets add-iam-policy-binding "$secret_name" \
            --member="serviceAccount:$compute_sa" \
            --role="roles/secretmanager.secretAccessor" \
            --quiet >/dev/null 2>&1 || warn "Failed to grant secret access (may already exist)"
    fi

    success "Credentials stored in Secret Manager"
    SECRET_NAME="$secret_name"
}

# Deploy Cloud Run chisel server
deploy_cloud_run() {
    header "Deploying Cloud Run Tunnel Server"

    log "Deploying chisel server to Cloud Run..."
    log "Service: $SERVICE_NAME"
    log "Region: $REGION"
    log "Image: $CHISEL_IMAGE"

    # Note: Cloud Run exposes port 8080. Chisel server listens on 8080.
    # The reverse tunnel will map: Cloud Run :8080 -> HA :8123

    if ! gcloud run deploy "$SERVICE_NAME" \
        --image="$CHISEL_IMAGE" \
        --region="$REGION" \
        --platform=managed \
        --allow-unauthenticated \
        --port=8080 \
        --cpu=1 \
        --memory=256Mi \
        --min-instances=0 \
        --max-instances=1 \
        --timeout=3600 \
        --session-affinity \
        --set-secrets="CHISEL_AUTH=${SECRET_NAME}:latest" \
        --args="server,--port,8080,--reverse,--authfile,/secrets/CHISEL_AUTH" \
        --quiet 2>/dev/null; then

        # Fallback: use inline auth if secrets mount fails
        warn "Secret mount failed, using inline auth (less secure)"

        if ! gcloud run deploy "$SERVICE_NAME" \
            --image="$CHISEL_IMAGE" \
            --region="$REGION" \
            --platform=managed \
            --allow-unauthenticated \
            --port=8080 \
            --cpu=1 \
            --memory=256Mi \
            --min-instances=0 \
            --max-instances=1 \
            --timeout=3600 \
            --session-affinity \
            --args="server,--port,8080,--reverse,--auth,${TUNNEL_AUTH_USER}:${TUNNEL_AUTH_PASS}" \
            --quiet; then
            error "Failed to deploy Cloud Run service"
        fi
    fi

    CREATED_RESOURCES+=("cloudrun:$SERVICE_NAME")

    # Get the URL
    CLOUD_RUN_URL=$(gcloud run services describe "$SERVICE_NAME" \
        --region="$REGION" \
        --format="value(status.url)" 2>/dev/null)

    if [ -z "$CLOUD_RUN_URL" ]; then
        error "Failed to get Cloud Run URL"
    fi

    success "Cloud Run deployed: $CLOUD_RUN_URL"

    # WebSocket URL for chisel client
    TUNNEL_URL="${CLOUD_RUN_URL/https:\/\//wss://}"
}

# Create service account for Home Assistant
create_service_account() {
    header "Creating Service Account"

    SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

    # Check if exists
    if gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null; then
        log "Service account already exists: $SA_EMAIL"

        # Check for existing keys (don't create too many)
        local key_count
        key_count=$(gcloud iam service-accounts keys list \
            --iam-account="$SA_EMAIL" \
            --format="value(name)" 2>/dev/null | wc -l)

        if [ "$key_count" -gt 5 ]; then
            warn "Service account has $key_count keys. Consider cleaning up old keys."
        fi
    else
        log "Creating service account..."
        if ! gcloud iam service-accounts create "$SA_NAME" \
            --display-name="Home Assistant Google Assistant"; then
            error "Failed to create service account"
        fi
        CREATED_RESOURCES+=("serviceaccount:$SA_EMAIL")
    fi

    # Grant role (idempotent)
    log "Granting Service Account Token Creator role..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SA_EMAIL" \
        --role="roles/iam.serviceAccountTokenCreator" \
        --condition=None \
        --quiet >/dev/null 2>&1 || true

    # Create key
    SA_KEY_FILE="${OUTPUT_DIR}/service_account.json"
    log "Creating service account key..."

    if ! gcloud iam service-accounts keys create "$SA_KEY_FILE" \
        --iam-account="$SA_EMAIL"; then
        error "Failed to create service account key"
    fi

    # Secure the key file
    chmod 600 "$SA_KEY_FILE"

    success "Service account key saved to: $SA_KEY_FILE"
}

# Create action.json for Smart Home (new Google Home Developer Console format)
create_action_json() {
    header "Creating Smart Home Action Configuration"

    # URLs through the tunnel
    FULFILLMENT_URL="${CLOUD_RUN_URL}/api/google_assistant"
    AUTH_URL="${CLOUD_RUN_URL}/auth/authorize"
    TOKEN_URL="${CLOUD_RUN_URL}/auth/token"

    # New format for Google Home Developer Console
    cat > "${OUTPUT_DIR}/action.json" << EOF
{
  "manifest": {
    "displayName": "Home Assistant",
    "invocationName": "home assistant",
    "category": "SMART_HOME"
  },
  "actions": [
    {
      "name": "actions.devices",
      "fulfillment": {
        "conversationName": "automation"
      }
    }
  ],
  "conversations": {
    "automation": {
      "name": "automation",
      "url": "${FULFILLMENT_URL}",
      "fulfillmentApiVersion": 2
    }
  },
  "accountLinking": {
    "clientId": "https://oauth-redirect.googleusercontent.com/r/${PROJECT_ID}",
    "clientSecret": "placeholder",
    "grantType": "AUTH_CODE",
    "authenticationUrl": "${AUTH_URL}",
    "accessTokenUrl": "${TOKEN_URL}"
  }
}
EOF

    success "Created action.json"
    log "Fulfillment URL: $FULFILLMENT_URL"

    # Also create manual setup instructions
    cat > "${OUTPUT_DIR}/google_home_console_setup.txt" << EOF
Google Home Developer Console Manual Setup
==========================================

1. Go to: https://console.home.google.com/projects
2. Select project: ${PROJECT_ID}
3. Click "Add integration" -> "Cloud-to-cloud"
4. Fill in:

   Display Name: Home Assistant

   OAuth Client ID:
   https://oauth-redirect.googleusercontent.com/r/${PROJECT_ID}

   Authorization URL:
   ${AUTH_URL}

   Token URL:
   ${TOKEN_URL}

   Fulfillment URL:
   ${FULFILLMENT_URL}

5. Click Save -> Test
6. In Google Home app: + -> Set up device -> Works with Google
7. Search for "[test] Home Assistant"
EOF

    success "Created manual setup instructions: google_home_console_setup.txt"
}

# Deploy Smart Home Action (if gactions available)
deploy_smart_home_action() {
    header "Deploying Smart Home Action"

    if [ "$SKIP_GACTIONS" = true ]; then
        warn "Skipping gactions deployment (CLI not installed)"
        warn "See: ${OUTPUT_DIR}/google_home_console_setup.txt for manual setup"
        return 0
    fi

    log "Authenticating with gactions..."
    if ! gactions login --no-launch-browser 2>/dev/null; then
        warn "gactions login failed - manual setup required"
        warn "See: ${OUTPUT_DIR}/google_home_console_setup.txt"
        return 0
    fi

    log "Pushing action configuration..."
    cd "$OUTPUT_DIR"
    if ! gactions push 2>/dev/null; then
        warn "gactions push failed - manual setup may be required"
        return 0
    fi

    log "Deploying to preview..."
    if ! gactions deploy preview 2>/dev/null; then
        warn "gactions deploy failed - manual setup may be required"
        return 0
    fi

    success "Smart Home Action deployed to preview"
}

# Configure Home Assistant
configure_home_assistant() {
    header "Configuring Home Assistant"

    # Upload service account
    log "Uploading service account to HA..."
    if ! cat "$SA_KEY_FILE" | ssh ha 'sudo tee /config/service_account.json > /dev/null && sudo chmod 600 /config/service_account.json'; then
        error "Failed to upload service account to HA"
    fi
    success "Service account uploaded (permissions: 600)"

    # Check if google_assistant already configured
    log "Checking existing configuration..."
    if ssh ha 'sudo grep -q "^google_assistant:" /config/configuration.yaml' 2>/dev/null; then
        warn "google_assistant already in configuration.yaml"
        warn "Please verify project_id is: $PROJECT_ID"
    else
        log "Adding google_assistant configuration..."
        if ! ssh ha "sudo sh -c 'cat >> /config/configuration.yaml << \"EOFCONFIG\"

# Google Assistant (auto-configured by gcp-ha-setup.sh)
google_assistant:
  project_id: ${PROJECT_ID}
  service_account: !include service_account.json
  report_state: true
  exposed_domains:
    - light
    - switch
    - climate
    - cover
    - fan
    - media_player
EOFCONFIG'"; then
            error "Failed to update configuration.yaml"
        fi
        success "google_assistant configuration added"
    fi

    # Check configuration
    log "Validating HA configuration..."
    if ! ssh ha '. /etc/profile.d/homeassistant.sh && ha core check' 2>/dev/null; then
        error "HA configuration check failed. Check configuration.yaml syntax."
    fi
    success "Configuration valid"

    # Restart and wait
    log "Restarting Home Assistant..."
    ssh ha '. /etc/profile.d/homeassistant.sh && ha core restart' >/dev/null 2>&1

    log "Waiting for HA to restart (30s)..."
    sleep 30

    # Verify HA is up
    local retries=10
    while [ $retries -gt 0 ]; do
        if ssh ha 'curl -s -o /dev/null -w "%{http_code}" http://localhost:8123/api/' 2>/dev/null | grep -q "401\|200"; then
            success "Home Assistant is back online"
            return 0
        fi
        log "Waiting for HA... ($retries attempts left)"
        sleep 5
        ((retries--))
    done

    warn "HA may still be starting. Check manually."
}

# Save tunnel configuration securely
save_tunnel_config() {
    header "Saving Configuration"

    local config_file="${OUTPUT_DIR}/tunnel_config.env"

    cat > "$config_file" << EOF
# GCP HA Tunnel Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# SECURITY: This file contains sensitive credentials.
# Do not commit to version control or share.

PROJECT_ID=${PROJECT_ID}
REGION=${REGION}
CLOUD_RUN_URL=${CLOUD_RUN_URL}
TUNNEL_URL=${TUNNEL_URL}
TUNNEL_AUTH_USER=${TUNNEL_AUTH_USER}
TUNNEL_AUTH_PASS=${TUNNEL_AUTH_PASS}
SERVICE_ACCOUNT_FILE=${SA_KEY_FILE}
EOF

    # Secure the config file
    chmod 600 "$config_file"

    success "Configuration saved to: $config_file (permissions: 600)"

    # Create add-on config snippet (without password in logs)
    cat > "${OUTPUT_DIR}/addon_options.yaml" << EOF
# Copy these values to the GCP Tunnel Client add-on configuration
server_url: "${CLOUD_RUN_URL}"
auth_user: "${TUNNEL_AUTH_USER}"
auth_pass: "${TUNNEL_AUTH_PASS}"
local_port: 8123
keepalive: "25s"
log_level: "info"
EOF

    chmod 600 "${OUTPUT_DIR}/addon_options.yaml"
    success "Add-on config saved to: addon_options.yaml"
}

# Print summary (without exposing credentials)
print_summary() {
    header "Setup Complete!"

    echo -e "${GREEN}Cloud Run Tunnel:${NC}"
    echo "  URL: $CLOUD_RUN_URL"
    echo "  WebSocket: $TUNNEL_URL"
    echo "  Auth User: $TUNNEL_AUTH_USER"
    echo "  Auth Pass: <see tunnel_config.env>"
    echo ""
    echo -e "${GREEN}GCP Project:${NC}"
    echo "  ID: $PROJECT_ID"
    echo "  Console: https://console.cloud.google.com/run?project=$PROJECT_ID"
    echo ""
    echo -e "${GREEN}Files Created:${NC}"
    echo "  ${OUTPUT_DIR}/"
    echo "    - service_account.json    (uploaded to HA)"
    echo "    - tunnel_config.env       (credentials - keep secure!)"
    echo "    - addon_options.yaml      (add-on configuration)"
    echo "    - action.json             (Smart Home Action)"
    echo "    - google_home_console_setup.txt"
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "  1. Install GCP Tunnel Client add-on on HA"
    echo "  2. Configure with values from: ${OUTPUT_DIR}/addon_options.yaml"
    echo "  3. Start the add-on"
    echo "  4. Link in Google Home app:"
    echo "     - Open Google Home app"
    echo "     - Tap + → Set up device → Works with Google"
    echo "     - Search for '[test] Home Assistant'"
    echo ""
    echo -e "${YELLOW}Security Notes:${NC}"
    echo "  - Credentials are in: ${OUTPUT_DIR}/tunnel_config.env"
    echo "  - Do NOT commit these files to git"
    echo "  - Add to .gitignore: output/"
    echo ""
}

# Main
main() {
    header "GCP Home Assistant Tunnel Setup"

    # Trap errors for cleanup
    trap cleanup_on_error ERR

    check_prerequisites
    authenticate_gcloud
    setup_project
    enable_apis
    store_credentials
    deploy_cloud_run
    create_service_account
    create_action_json
    deploy_smart_home_action
    configure_home_assistant
    save_tunnel_config
    print_summary

    # Clear trap on success
    trap - ERR
}

# Run main with all arguments
main "$@"
