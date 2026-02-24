#!/usr/bin/env python3
"""Autonomous heartbeat agent for EOS during server sleep.

This agent sends periodic heartbeat (lastupdated) requests to EOS
to maintain the server list visibility while the game server is paused.
"""

from __future__ import annotations

import json
import os
import sys
import time
from datetime import datetime, timezone
from typing import Optional, Dict, Any, Tuple
import urllib.request
import urllib.error
import urllib.parse

# Configuration from environment variables
AUTO_PAUSE_WORK_DIR = os.getenv("AUTO_PAUSE_WORK_DIR")

# この環境変数が得られなかった時点で、エラー終了する。
if not AUTO_PAUSE_WORK_DIR:
    print("ERROR: AUTO_PAUSE_WORK_DIR environment variable is not set.")
    sys.exit(1)

TEMPLATE_PATH = os.getenv("EOS_SESSION_TEMPLATE", os.path.join(AUTO_PAUSE_WORK_DIR, "session_template.json"))
CREDS_PATH = os.getenv("EOS_CREDS_FILE", os.path.join(AUTO_PAUSE_WORK_DIR, "eos_creds.json"))

LOG_PATH = os.getenv("EOS_HB_AGENT_LOG_PATH", "")
SLEEP_FLAG_PATH = os.getenv("AUTO_PAUSE_SLEEP_FLAG", "")
HEARTBEAT_INTERVAL_SEC = int(os.getenv("HEARTBEAT_INTERVAL_SEC", "60"))

CURRENT_TOKEN = None
TOKEN_EXPIRES_AT = 0
TOKEN_OBTAINED_AT = 0

def log_line(message: str) -> None:
    timestamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    line = f"{timestamp} {message}"
    if LOG_PATH:
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            print(line)
    else:
        print(line)

def load_json(path: str) -> Optional[Dict[str, Any]]:
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None

def save_json(path: str, data: Dict[str, Any]) -> bool:
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        return True
    except Exception as e:
        log_line(f"save-json: failed to save {path}: {e}")
        return False

def refresh_token(creds: Optional[Dict[str, Any]]) -> Optional[str]:
    global CURRENT_TOKEN, TOKEN_EXPIRES_AT, TOKEN_OBTAINED_AT
    if not creds:
        log_line("refresh-token: skipped (credentials unavailable)")
        return None
    if not creds.get("basic_auth") or not creds.get("deployment_id"):
        log_line("refresh-token: skipped (basic_auth/deployment_id missing)")
        return None

    url = "https://api.epicgames.dev/auth/v1/oauth/token"
    headers = {
        "Authorization": creds["basic_auth"],
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": creds.get("user_agent", "EOS-SDK/1.16.2-32273396 (Wine/10.0)"),
        "Accept": "application/json"
    }
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "deployment_id": creds["deployment_id"]
    }).encode("utf-8")
    
    log_line("refresh-token: requesting to EOS")
    req = urllib.request.Request(url, method="POST", headers=headers, data=data)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            res_data = json.loads(resp.read().decode("utf-8"))
            token = res_data.get("access_token")
            expires_in = res_data.get("expires_in", 3600)
            if token:
                now = time.time()
                CURRENT_TOKEN = token
                TOKEN_OBTAINED_AT = now
                TOKEN_EXPIRES_AT = now + expires_in - 300 # 5 min margin
                
                # Save to credentials file for other scripts to use
                if CREDS_PATH:
                    try:
                        creds["access_token"] = token
                        creds["expires_in"] = expires_in
                        creds["obtained_at"] = int(now)
                        with open(CREDS_PATH, "w", encoding="utf-8") as f:
                            json.dump(creds, f, indent=2)
                    except Exception as e:
                        log_line(f"refresh-token: failed to save to {CREDS_PATH}: {e}")
                
                log_line(f"refresh-token: success, expires in {expires_in}s")
                return token
    except Exception as e:
        log_line(f"refresh-token: failed {e}")
    return None

def send_heartbeat(url: str, headers: Dict[str, str]) -> int:
    req = urllib.request.Request(url, method="POST", headers=headers, data=b"")
    with urllib.request.urlopen(req, timeout=15) as response:
        return response.status

def get_sessions_url(template: Dict[str, Any]) -> Optional[str]:
    url = template.get("url", "")
    if not url:
        return None
    if url.endswith("/sessions"):
        return url
    marker = "/sessions/"
    if marker in url:
        return url.split(marker, 1)[0] + "/sessions"
    return None

def get_session_id(template: Dict[str, Any]) -> str:
    body_obj = template.get("body", {})
    public_data = body_obj.get("publicData", {}) if isinstance(body_obj, dict) else {}
    return str(public_data.get("id") or body_obj.get("id") or "")

def build_session_create_body(template: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    # Prefer explicit request payload when present, otherwise reconstruct from captured response body.
    source = (
        template.get("createBody")
        or template.get("create_body")
        or template.get("requestBody")
        or template.get("request_body")
        or template.get("body")
    )
    if not isinstance(source, dict):
        return None

    body = json.loads(json.dumps(source))

    # Backward compatibility: older templates only stored the registration response body
    # where session payload sits under publicData.
    if "deployment" not in body and isinstance(body.get("publicData"), dict):
        body = json.loads(json.dumps(body["publicData"]))

    generated_fields = {
        "id",
        "sessionId",
        "lock",
        "createdAt",
        "lastUpdated",
        "lastUpdatedAt",
        "registeredPlayers",
        "totalPlayers",
        "bucketId",
        "owner",
        "ownerPlatformId",
    }
    for key in list(generated_fields):
        body.pop(key, None)

    if isinstance(body.get("publicData"), dict):
        body["publicData"].pop("id", None)
    if isinstance(body.get("privateData"), dict):
        body["privateData"].pop("lock", None)
        body["privateData"].pop("id", None)

    return body

def recreate_session(template: Dict[str, Any], creds: Optional[Dict[str, Any]], token: Optional[str]) -> Tuple[bool, Optional[Dict[str, Any]]]:
    sessions_url = get_sessions_url(template)
    if not sessions_url:
        log_line("recreate-session: failed (sessions URL unavailable)")
        return False, None

    create_body = build_session_create_body(template)
    if not create_body:
        log_line("recreate-session: failed (create body unavailable)")
        return False, None

    base_headers = template.get("headers", {}) if isinstance(template.get("headers"), dict) else {}
    headers: Dict[str, str] = {}
    for key, value in base_headers.items():
        if not isinstance(value, str):
            continue
        lower_key = key.lower()
        if lower_key in ("authorization", "user-agent", "accept", "content-type"):
            headers[key] = value

    # Session registration should not carry stale lock values.
    headers.pop("x-epic-locks", None)
    headers.pop("X-Epic-Locks", None)

    if token:
        headers["Authorization"] = f"Bearer {token}"
    elif creds and isinstance(creds.get("access_token"), str):
        headers["Authorization"] = f"Bearer {creds['access_token']}"

    if "Content-Type" not in headers and "content-type" not in headers:
        headers["Content-Type"] = "application/json"
    if "Accept" not in headers and "accept" not in headers:
        headers["Accept"] = "application/json"

    data = json.dumps(create_body, separators=(",", ":")).encode("utf-8")
    req = urllib.request.Request(sessions_url, method="POST", headers=headers, data=data)
    log_line(f"recreate-session: POST {sessions_url}")

    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            status = resp.status
            if status not in (200, 201):
                log_line(f"recreate-session: unexpected status {status}")
                return False, None

            raw = resp.read().decode("utf-8")
            if not raw:
                log_line("recreate-session: empty response body")
                return False, None
            body = json.loads(raw)
            if not isinstance(body, dict):
                log_line("recreate-session: invalid response type")
                return False, None

            new_template = {
                "url": sessions_url,
                "body": body,
                "headers": template.get("headers", {}).copy() if isinstance(template.get("headers"), dict) else {},
            }

            # Keep latest token in template headers for tools that read it.
            if token:
                new_template["headers"]["Authorization"] = f"Bearer {token}"

            # Refresh lock value if response contains it.
            new_lock = (
                body.get("privateData", {}).get("lock") if isinstance(body.get("privateData"), dict) else None
            ) or body.get("lock")
            if isinstance(new_lock, str) and new_lock:
                new_template["headers"]["x-epic-locks"] = new_lock

            if save_json(TEMPLATE_PATH, new_template):
                new_session_id = get_session_id(new_template)
                log_line(f"recreate-session: success (status={status}, session_id={new_session_id})")
            else:
                log_line("recreate-session: warning - created session but failed to persist template")

            return True, new_template
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8")[:300]
        except Exception:
            pass
        if detail:
            log_line(f"recreate-session: HTTP error {e.code} {e.reason} body={detail}")
        else:
            log_line(f"recreate-session: HTTP error {e.code} {e.reason}")
    except Exception as e:
        log_line(f"recreate-session: failed {e}")

    return False, None

def get_last_updated_url(template: Dict[str, Any]) -> Optional[str]:
    url = template.get("url", "")
    if not url:
        return None
        
    # If the URL is already a lastupdated URL, return it
    if "/sessions/" in url and url.endswith("/lastupdated"):
        return url
        
    # If it's a sessions URL, we need to append the session ID
    if url.endswith("/sessions"):
        session_id = get_session_id(template)
        if session_id:
            return f"{url}/{session_id}/lastupdated"
        return None
        
    return None

def get_session_lock(template: Dict[str, Any]) -> str:
    body_obj = template.get("body", {})
    return (
        template.get("headers", {}).get("x-epic-locks")
        or template.get("headers", {}).get("X-Epic-Locks")
        or body_obj.get("privateData", {}).get("lock")
        or body_obj.get("lock")
        or ""
    )

def main_loop() -> None:
    global CURRENT_TOKEN, TOKEN_EXPIRES_AT, TOKEN_OBTAINED_AT
    log_line("heartbeat-agent: starting main loop")
    
    while True:
        try:
            # Check if server is sleeping (flag exists)
            # If SLEEP_FLAG_PATH is empty, we assume we should always run (for testing)
            if not SLEEP_FLAG_PATH or os.path.exists(SLEEP_FLAG_PATH):
                template = load_json(TEMPLATE_PATH)
                if not template:
                    log_line(f"heartbeat-agent: warning - template not found at {TEMPLATE_PATH}")
                    time.sleep(30)
                    continue
                
                url = get_last_updated_url(template)
                if not url:
                    log_line("heartbeat-agent: error - could not determine lastupdated URL")
                    time.sleep(30)
                    continue
                
                headers = template.get("headers", {}).copy()
                if "Accept" not in headers and "accept" not in headers:
                    headers["Accept"] = "*/*"
                # Observed heartbeat calls use form-urlencoded with empty body.
                headers["Content-Type"] = "application/x-www-form-urlencoded"

                # x-epic-locks is required for lastupdated.
                # Prefer captured values from template headers/response body.
                lock_header = get_session_lock(template)
                if lock_header and lock_header != "eos-hb-agent-lock":
                    headers["x-epic-locks"] = lock_header
                else:
                    log_line("heartbeat-agent: warning - x-epic-locks unavailable")
                
                # Try to use credentials for token refresh
                creds = load_json(CREDS_PATH)
                can_refresh_token = bool(creds and creds.get("basic_auth") and creds.get("deployment_id"))
                if can_refresh_token:
                    # Initialize CURRENT_TOKEN from file to prevent invalidating game server's token unnecessarily
                    if not CURRENT_TOKEN and creds.get("access_token"):
                        try:
                            obtained_at = creds.get("obtained_at")
                            if not obtained_at:
                                obtained_at = os.path.getmtime(CREDS_PATH)
                            expires_in = creds.get("expires_in", 3600)
                            if time.time() < (float(obtained_at) + expires_in - 300):
                                CURRENT_TOKEN = creds["access_token"]
                                TOKEN_OBTAINED_AT = float(obtained_at)
                                TOKEN_EXPIRES_AT = float(obtained_at) + expires_in - 300
                                log_line(f"heartbeat-agent: Loaded cached token, valid for another {int(TOKEN_EXPIRES_AT - time.time())}s")
                        except Exception as e:
                            log_line(f"heartbeat-agent: Failed to determine cached token expiration: {e}")
                            
                    if not CURRENT_TOKEN or time.time() > TOKEN_EXPIRES_AT:
                        refresh_token(creds)
                    if CURRENT_TOKEN:
                        headers["Authorization"] = f"Bearer {CURRENT_TOKEN}"
                
                log_line(f"heartbeat-agent: sending heartbeat to {url}")
                try:
                    status = send_heartbeat(url, headers)
                    if status == 204:
                        log_line("heartbeat-agent: success (204)")
                    else:
                        log_line(f"heartbeat-agent: warning status {status}")
                except urllib.error.HTTPError as e:
                    if e.code == 409:
                        log_line("heartbeat-agent: HTTP 409 invalid_lock (x-epic-locks mismatch or stale session lock)")
                    elif e.code in (401, 403):
                        log_line(f"heartbeat-agent: HTTP {e.code} auth error, refreshing token and retrying once")
                        if can_refresh_token and refresh_token(creds):
                            headers["Authorization"] = f"Bearer {CURRENT_TOKEN}"
                            try:
                                retry_status = send_heartbeat(url, headers)
                                if retry_status == 204:
                                    log_line("heartbeat-agent: retry success (204)")
                                else:
                                    log_line(f"heartbeat-agent: retry warning status {retry_status}")
                            except urllib.error.HTTPError as retry_err:
                                log_line(f"heartbeat-agent: retry HTTP error {retry_err.code} {retry_err.reason}")
                            except Exception as retry_ex:
                                log_line(f"heartbeat-agent: retry exception {retry_ex}")
                        else:
                            log_line("heartbeat-agent: token refresh unavailable, skip retry")
                    elif e.code == 404:
                        log_line("heartbeat-agent: HTTP 404 not found (session might have expired, needs recreation)")
                        if can_refresh_token:
                            refresh_token(creds)
                            if CURRENT_TOKEN:
                                headers["Authorization"] = f"Bearer {CURRENT_TOKEN}"

                        recreated, new_template = recreate_session(template, creds, CURRENT_TOKEN)
                        if recreated and new_template:
                            retry_url = get_last_updated_url(new_template)
                            if retry_url:
                                retry_headers = new_template.get("headers", {}).copy() if isinstance(new_template.get("headers"), dict) else {}
                                lock_header = get_session_lock(new_template)
                                if lock_header:
                                    retry_headers["x-epic-locks"] = lock_header
                                if CURRENT_TOKEN:
                                    retry_headers["Authorization"] = f"Bearer {CURRENT_TOKEN}"
                                if "Accept" not in retry_headers and "accept" not in retry_headers:
                                    retry_headers["Accept"] = "*/*"
                                retry_headers["Content-Type"] = "application/x-www-form-urlencoded"
                                try:
                                    retry_status = send_heartbeat(retry_url, retry_headers)
                                    if retry_status == 204:
                                        log_line("heartbeat-agent: post-recreate heartbeat success (204)")
                                    else:
                                        log_line(f"heartbeat-agent: post-recreate heartbeat warning status {retry_status}")
                                except urllib.error.HTTPError as retry_err:
                                    log_line(f"heartbeat-agent: post-recreate heartbeat HTTP error {retry_err.code} {retry_err.reason}")
                                except Exception as retry_ex:
                                    log_line(f"heartbeat-agent: post-recreate heartbeat exception {retry_ex}")
                            else:
                                log_line("heartbeat-agent: recreated session but lastupdated URL unavailable")
                        if not can_refresh_token:
                            log_line("heartbeat-agent: token refresh unavailable on 404")
                    else:
                        log_line(f"heartbeat-agent: HTTP error {e.code} {e.reason}")
                except Exception as e:
                    log_line(f"heartbeat-agent: request exception {e}")
            else:
                # Server is awake, skip heartbeat
                pass
                
            time.sleep(HEARTBEAT_INTERVAL_SEC)
        except Exception as e:
            log_line(f"heartbeat-agent: loop unexpected error {e}")
            time.sleep(30)

if __name__ == "__main__":
    main_loop()
