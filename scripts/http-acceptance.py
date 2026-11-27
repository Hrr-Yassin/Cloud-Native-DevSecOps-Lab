#!/usr/bin/env python3
"""Verify expected behavior against the dedicated TLS listener through loopback."""

import argparse
import http.client
import json
import socket
import ssl
from pathlib import Path

HOST = "desk.lab.invalid"
PORT = 8443
ORIGIN = f"https://{HOST}:{PORT}"


class LoopbackTLS(http.client.HTTPSConnection):
    def connect(self):
        raw = socket.create_connection(("127.0.0.1", PORT), self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=HOST)
        except (OSError, ssl.SSLError):
            raw.close()
            raise


def run(ca, operator, viewer, read_only):
    context = ssl.create_default_context(cafile=ca)
    outcomes = {}

    def request(name, method, path, status, *, body=None, session=None, origin=ORIGIN, csrf=True):
        headers = {"Origin": origin}
        if body is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(body)
        if session is not None:
            headers["Cookie"] = session[0]
            if csrf:
                headers["X-CSRF-Token"] = session[1]
        conn = LoopbackTLS(HOST, PORT, context=context, timeout=10)
        try:
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse()
            data = response.read(65536)
            if response.status != status:
                raise RuntimeError(f"{name} returned {response.status}, expected {status}")
            outcomes[name] = status
            return response, data
        finally:
            conn.close()

    def login(name, username, password):
        response, body = request(name, "POST", "/api/session", 200,
                                 body={"username": username, "password": password})
        cookie = response.getheader("Set-Cookie")
        expected = {"path=/", "secure", "httponly", "samesite=strict", "max-age=28800"}
        if not cookie or not cookie.startswith("__Host-lab_session="):
            raise RuntimeError("Session cookie name is incorrect")
        if not expected.issubset(item.strip().lower() for item in cookie.split(";")[1:]):
            raise RuntimeError("Session cookie attributes are incomplete")
        return cookie.split(";")[0], json.loads(body)["csrf"]

    page, html = request("tls_frontend", "GET", "/", 200)
    if b"Security Desk" not in html or "frame-ancestors 'none'" not in page.getheader("Content-Security-Policy", ""):
        raise RuntimeError("Frontend content or CSP is unavailable")
    request("health", "GET", "/healthz", 200)
    request("readiness", "GET", "/readyz", 200)
    request("metrics_private", "GET", "/metrics", 404)
    request("unauthenticated_read", "GET", "/api/findings", 401)

    admin = login("operator_login", "fixture-operator", operator)
    reader = login("viewer_login", "fixture-viewer", viewer)
    record = {"title": "Review synthetic image findings", "severity": "high"}
    request("viewer_write_denied", "POST", "/api/findings", 403, session=reader, body=record)
    request("origin_denied", "POST", "/api/findings", 403, session=admin, body=record,
            origin="https://unrelated.invalid")
    request("csrf_denied", "POST", "/api/findings", 403, session=admin, body=record, csrf=False)
    request("invalid_severity_denied", "POST", "/api/findings", 400, session=admin,
            body={**record, "severity": "unknown"})
    if not read_only:
        _, body = request("operator_created", "POST", "/api/findings", 201, session=admin, body=record)
        finding = json.loads(body)
        request("operator_resolved", "PATCH", f"/api/findings/{finding['id']}", 200, session=admin,
                body={"status": "resolved"})
    _, body = request("viewer_read", "GET", "/api/findings", 200, session=reader)
    if not any(item["title"] == record["title"] and item["status"] == "resolved"
               for item in json.loads(body)["findings"]):
        raise RuntimeError("The controlled remediation record is missing")
    request("logout", "DELETE", "/api/session", 204, session=admin)
    request("revoked_session_denied", "GET", "/api/session", 401, session=admin)
    request("viewer_logout", "DELETE", "/api/session", 204, session=reader)
    return outcomes


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ca", type=Path, required=True)
    parser.add_argument("--fixture-credentials", type=Path, required=True)
    parser.add_argument("--read-only", action="store_true")
    args = parser.parse_args()
    values = json.loads(args.fixture_credentials.read_text(encoding="utf-8"))
    print(json.dumps(run(args.ca, values["operator"], values["viewer"], args.read_only), indent=2))
