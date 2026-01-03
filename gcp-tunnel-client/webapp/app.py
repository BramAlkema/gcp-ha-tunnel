#!/usr/bin/env python3
"""
GCP Tunnel Auto-Setup Web UI

Handles:
- Google OAuth flow
- GCP project creation
- Cloud Run deployment
- Automatic configuration
"""

import os
import json
import secrets
import hashlib
import base64
import subprocess
from pathlib import Path
from urllib.parse import urlencode, quote_plus

from flask import Flask, render_template, redirect, request, session, jsonify
import requests

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)

# OAuth config - using "TV and Limited Input" flow for simplicity
# No client secret needed, works from any device
GOOGLE_CLIENT_ID = "292824132082-7a1h7ae29f4aepk6qng3296kdlnpqhea.apps.googleusercontent.com"
GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"

# Required OAuth scopes
SCOPES = [
    "https://www.googleapis.com/auth/cloud-platform",  # Full GCP access
    "https://www.googleapis.com/auth/userinfo.email",  # Get user email
]

# Paths
CONFIG_DIR = Path("/config")
DATA_DIR = Path("/data")
TOKEN_FILE = DATA_DIR / "google_token.json"
SETUP_FILE = DATA_DIR / "setup_state.json"

# Pre-built tunnel server image
TUNNEL_IMAGE = "ghcr.io/bramalkema/gcp-ha-tunnel/tunnel-server:latest"


def get_ingress_path():
    """Get the ingress base path from environment."""
    return os.environ.get("INGRESS_PATH", "")


def generate_project_name():
    """Generate a unique project name."""
    suffix = secrets.token_hex(3)
    return f"ha-tunnel-{suffix}"


def generate_password():
    """Generate a secure password."""
    return secrets.token_urlsafe(24)


def get_setup_state():
    """Load setup state from file."""
    if SETUP_FILE.exists():
        return json.loads(SETUP_FILE.read_text())
    return {"step": "start", "project_id": None, "password": None}


def save_setup_state(state):
    """Save setup state to file."""
    DATA_DIR.mkdir(exist_ok=True)
    SETUP_FILE.write_text(json.dumps(state, indent=2))


def get_token():
    """Load stored OAuth token."""
    if TOKEN_FILE.exists():
        return json.loads(TOKEN_FILE.read_text())
    return None


def save_token(token):
    """Save OAuth token."""
    DATA_DIR.mkdir(exist_ok=True)
    TOKEN_FILE.write_text(json.dumps(token, indent=2))


def refresh_token_if_needed(token):
    """Refresh the access token if expired."""
    # For simplicity, always try to use current token
    # In production, check expiry and refresh
    return token


def gcp_api(method, url, token, **kwargs):
    """Make an authenticated GCP API call."""
    headers = {
        "Authorization": f"Bearer {token['access_token']}",
        "Content-Type": "application/json",
    }
    resp = requests.request(method, url, headers=headers, **kwargs)
    return resp


@app.route("/")
def index():
    """Main page - shows setup wizard or status."""
    state = get_setup_state()
    token = get_token()

    return render_template("index.html",
                         state=state,
                         has_token=token is not None,
                         ingress_path=get_ingress_path())


@app.route("/auth/start")
def auth_start():
    """Start OAuth flow."""
    # Generate PKCE challenge
    code_verifier = secrets.token_urlsafe(64)
    code_challenge = base64.urlsafe_b64encode(
        hashlib.sha256(code_verifier.encode()).digest()
    ).decode().rstrip("=")

    session["code_verifier"] = code_verifier

    # Build auth URL
    params = {
        "client_id": GOOGLE_CLIENT_ID,
        "redirect_uri": request.url_root.rstrip("/") + get_ingress_path() + "/auth/callback",
        "response_type": "code",
        "scope": " ".join(SCOPES),
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
        "access_type": "offline",
        "prompt": "consent",
    }

    auth_url = f"{GOOGLE_AUTH_URL}?{urlencode(params)}"
    return redirect(auth_url)


@app.route("/auth/callback")
def auth_callback():
    """Handle OAuth callback."""
    code = request.args.get("code")
    error = request.args.get("error")

    if error:
        return render_template("error.html", error=error)

    if not code:
        return render_template("error.html", error="No authorization code received")

    # Exchange code for token
    code_verifier = session.get("code_verifier")

    resp = requests.post(GOOGLE_TOKEN_URL, data={
        "client_id": GOOGLE_CLIENT_ID,
        "code": code,
        "code_verifier": code_verifier,
        "grant_type": "authorization_code",
        "redirect_uri": request.url_root.rstrip("/") + get_ingress_path() + "/auth/callback",
    })

    if resp.status_code != 200:
        return render_template("error.html", error=f"Token exchange failed: {resp.text}")

    token = resp.json()
    save_token(token)

    # Update state
    state = get_setup_state()
    state["step"] = "authenticated"
    save_setup_state(state)

    return redirect(get_ingress_path() + "/")


@app.route("/api/billing-accounts")
def list_billing_accounts():
    """List user's billing accounts."""
    token = get_token()
    if not token:
        return jsonify({"error": "Not authenticated"}), 401

    resp = gcp_api("GET",
                   "https://cloudbilling.googleapis.com/v1/billingAccounts",
                   token)

    if resp.status_code != 200:
        return jsonify({"error": resp.text}), resp.status_code

    data = resp.json()
    accounts = data.get("billingAccounts", [])

    # Filter to open accounts only
    open_accounts = [a for a in accounts if a.get("open", False)]

    return jsonify({"accounts": open_accounts})


@app.route("/api/setup", methods=["POST"])
def run_setup():
    """Run the full auto-setup process."""
    token = get_token()
    if not token:
        return jsonify({"error": "Not authenticated"}), 401

    state = get_setup_state()

    # Get or generate values
    project_id = state.get("project_id") or generate_project_name()
    password = state.get("password") or generate_password()
    billing_account = request.json.get("billing_account")

    state["project_id"] = project_id
    state["password"] = password
    state["step"] = "creating_project"
    save_setup_state(state)

    try:
        # Step 1: Create project
        resp = gcp_api("POST",
                      "https://cloudresourcemanager.googleapis.com/v1/projects",
                      token,
                      json={"projectId": project_id, "name": "HA Tunnel"})

        if resp.status_code not in [200, 409]:  # 409 = already exists
            return jsonify({"error": f"Failed to create project: {resp.text}"}), 500

        state["step"] = "linking_billing"
        save_setup_state(state)

        # Step 2: Link billing
        if billing_account:
            resp = gcp_api("PUT",
                          f"https://cloudbilling.googleapis.com/v1/projects/{project_id}/billingInfo",
                          token,
                          json={"billingAccountName": billing_account})

            if resp.status_code != 200:
                return jsonify({"error": f"Failed to link billing: {resp.text}",
                              "billing_required": True}), 400

        state["step"] = "enabling_apis"
        save_setup_state(state)

        # Step 3: Enable APIs
        apis = ["run.googleapis.com", "cloudbuild.googleapis.com"]
        for api in apis:
            resp = gcp_api("POST",
                          f"https://serviceusage.googleapis.com/v1/projects/{project_id}/services/{api}:enable",
                          token)
            # Ignore errors - might already be enabled

        # Wait a bit for APIs to propagate
        import time
        time.sleep(5)

        state["step"] = "deploying"
        save_setup_state(state)

        # Step 4: Deploy Cloud Run
        service_config = {
            "apiVersion": "serving.knative.dev/v1",
            "kind": "Service",
            "metadata": {
                "name": "ha-tunnel",
                "annotations": {
                    "run.googleapis.com/ingress": "all"
                }
            },
            "spec": {
                "template": {
                    "metadata": {
                        "annotations": {
                            "autoscaling.knative.dev/minScale": "0",
                            "autoscaling.knative.dev/maxScale": "1",
                            "run.googleapis.com/cpu-throttling": "true"
                        }
                    },
                    "spec": {
                        "containerConcurrency": 80,
                        "timeoutSeconds": 3600,
                        "containers": [{
                            "image": TUNNEL_IMAGE,
                            "env": [
                                {"name": "AUTH", "value": f"hauser:{password}"}
                            ],
                            "resources": {
                                "limits": {
                                    "cpu": "1",
                                    "memory": "256Mi"
                                }
                            },
                            "ports": [{"containerPort": 8080}]
                        }]
                    }
                }
            }
        }

        # Create or replace service
        region = "us-central1"
        resp = gcp_api("POST",
                      f"https://run.googleapis.com/apis/serving.knative.dev/v1/namespaces/{project_id}/services",
                      token,
                      json=service_config)

        if resp.status_code not in [200, 201]:
            # Try updating existing service
            resp = gcp_api("PUT",
                          f"https://run.googleapis.com/apis/serving.knative.dev/v1/namespaces/{project_id}/services/ha-tunnel",
                          token,
                          json=service_config)

        if resp.status_code not in [200, 201]:
            return jsonify({"error": f"Failed to deploy: {resp.text}"}), 500

        # Step 5: Make service public (allow unauthenticated)
        iam_policy = {
            "bindings": [{
                "role": "roles/run.invoker",
                "members": ["allUsers"]
            }]
        }

        resp = gcp_api("POST",
                      f"https://run.googleapis.com/v1/projects/{project_id}/locations/{region}/services/ha-tunnel:setIamPolicy",
                      token,
                      json={"policy": iam_policy})

        # Get service URL
        resp = gcp_api("GET",
                      f"https://run.googleapis.com/v1/projects/{project_id}/locations/{region}/services/ha-tunnel",
                      token)

        if resp.status_code == 200:
            service_data = resp.json()
            service_url = service_data.get("status", {}).get("url", "")
            state["server_url"] = service_url

        state["step"] = "complete"
        save_setup_state(state)

        # Update add-on configuration
        update_addon_config(state)

        return jsonify({
            "success": True,
            "project_id": project_id,
            "server_url": state.get("server_url", ""),
            "password": password
        })

    except Exception as e:
        return jsonify({"error": str(e)}), 500


def update_addon_config(state):
    """Update the add-on's configuration via Supervisor API."""
    supervisor_token = os.environ.get("SUPERVISOR_TOKEN")
    if not supervisor_token:
        return

    config = {
        "server_url": state.get("server_url", ""),
        "auth_user": "hauser",
        "auth_pass": state.get("password", ""),
        "google_project_id": state.get("project_id", ""),
        "local_port": 8123,
        "keepalive": "25s",
        "log_level": "info",
        "google_secure_devices_pin": ""
    }

    resp = requests.post(
        "http://supervisor/addons/self/options",
        headers={"Authorization": f"Bearer {supervisor_token}"},
        json={"options": config}
    )

    if resp.status_code == 200:
        # Restart add-on to apply config
        requests.post(
            "http://supervisor/addons/self/restart",
            headers={"Authorization": f"Bearer {supervisor_token}"}
        )


@app.route("/api/status")
def get_status():
    """Get current setup status."""
    state = get_setup_state()
    token = get_token()

    return jsonify({
        "authenticated": token is not None,
        "step": state.get("step", "start"),
        "project_id": state.get("project_id"),
        "server_url": state.get("server_url"),
        "has_password": state.get("password") is not None
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8099, debug=False)
