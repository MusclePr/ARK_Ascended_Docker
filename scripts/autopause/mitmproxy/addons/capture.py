"""
This script intercepts the communication content with "api.epicgames.dev".

When a server goes to sleep, it disappears from the community server list.
We need to continue communication on behalf of the sleeping server.
The data needed to continue communication is captured here.
"""

import os
import json
import logging
import urllib.parse
from mitmproxy import http

# environment variables
SERVER_PORT = os.getenv("SERVER_PORT", "7777")
SERVER_DIR = os.getenv("AUTO_PAUSE_WORK_DIR", f"/opt/arkserver/.signals/server_{SERVER_PORT}/autopause")
TEMPLATE_PATH = os.getenv("EOS_SESSION_TEMPLATE", f"{SERVER_DIR}/session_template.json")
CREDS_PATH = os.getenv("EOS_CREDS_FILE", f"{SERVER_DIR}/eos_creds.json")

class EosCommCapture:
    def __init__(self):
        logging.info("EosCommCapture: mitmproxy addon initialized.")

    def response(self, flow: http.HTTPFlow):
        # 1. Capture OAuth Token Request (Basic Auth and Deployment ID)
        if "api.epicgames.dev" in flow.request.host and flow.request.path.endswith("/auth/v1/oauth/token"):
            if flow.request.method == "POST" and flow.response and flow.response.status_code == 200:
                try:
                    basic_auth = flow.request.headers.get("Authorization")
                    body_params = dict(urllib.parse.parse_qsl(flow.request.get_text()))
                    deployment_id = body_params.get("deployment_id")
                    
                    if basic_auth and deployment_id:
                        user_agent = flow.request.headers.get("User-Agent", "")
                        if "curl" in user_agent.lower():
                            logging.info("EosCommCapture: Ignored OAuth request from curl.")
                            return
                        else:
                            creds_path = CREDS_PATH
                        creds = {}
                        os.makedirs(os.path.dirname(creds_path), exist_ok=True)
                        if os.path.exists(creds_path):
                            with open(creds_path, "r") as f:
                                try:
                                    creds = json.load(f)
                                except json.JSONDecodeError:
                                    pass
                        
                        creds["basic_auth"] = basic_auth
                        creds["deployment_id"] = deployment_id
                        creds["user_agent"] = user_agent
                        
                        if flow.response and flow.response.text:
                            try:
                                resp_data = flow.response.json()
                                if "access_token" in resp_data:
                                    creds["access_token"] = resp_data["access_token"]
                                    creds["expires_in"] = resp_data.get("expires_in", 3600)
                            except ValueError:
                                pass
                                
                        with open(creds_path, "w") as f:
                            json.dump(creds, f, indent=2)
                            logging.info(f"EosCommCapture: Captured OAuth credentials to {creds_path}")
                except Exception as e:
                    logging.error(f"EosCommCapture: Failed to capture OAuth credentials: {e}")

        # 2. Capture Session Registration Response
        if "api.epicgames.dev" in flow.request.host and flow.request.path.endswith("/sessions"):
            if flow.request.method == "POST" and flow.response and flow.response.status_code in (200, 201):
                try:
                    # Ignore empty response body or non-JSON responses
                    if not flow.response.content:
                        return

                    request_body = {}
                    if flow.request.content:
                        try:
                            parsed_request_body = json.loads(flow.request.get_text())
                            if isinstance(parsed_request_body, dict):
                                request_body = parsed_request_body
                        except (ValueError, TypeError):
                            request_body = {}

                    # Parse response body (which contains session ID and lock) to use as template
                    data = flow.response.json()
                    if data:
                        captured_headers = {
                            k: v
                            for k, v in flow.request.headers.items()
                            if k.lower() in ["authorization", "x-epic-locks", "user-agent", "content-type", "accept"]
                        }
                        response_lock = flow.response.headers.get("x-epic-locks") or flow.response.headers.get("X-Epic-Locks")
                        if response_lock:
                            captured_headers["x-epic-locks"] = response_lock

                        output = {
                            "body": data,
                            "requestBody": request_body,
                            "headers": captured_headers,
                            "url": flow.request.pretty_url
                        }
                        os.makedirs(os.path.dirname(TEMPLATE_PATH), exist_ok=True)
                        with open(TEMPLATE_PATH, "w") as f:
                            json.dump(output, f, indent=2)
                        logging.info(f"EosCommCapture: Captured session registration response and headers to {TEMPLATE_PATH}")
                except ValueError:
                    # Body is not JSON, ignore it (could be lastupdated or other telemetry)
                    pass
                except Exception as e:
                    logging.error(f"EosCommCapture: Failed to capture session response: {e}")

addons = [EosCommCapture()]

