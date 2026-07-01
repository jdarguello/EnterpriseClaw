#!/usr/bin/env python3
# gh-token-proxy — the GitHub App-token auth-injecting sidecar for the kmcp GitHub MCPs.
#
# WHY THIS EXISTS (see CLAUDE.md §2.2 + the mcps/ README):
#   github-mcp-server reads its GitHub credential from the GITHUB_PERSONAL_ACCESS_TOKEN env var
#   ONCE at process start. It is delivered via kmcp secretRefs -> envFrom, which is a snapshot taken
#   at POD START and never re-read. The token is a GitHub App *installation* token with a ~1h TTL,
#   refreshed into the Secret every 30m by the ESO GithubAccessToken generator — but the running pod
#   never picks up the refreshed value, so after ~1h the MCP sends an expired token and GitHub
#   replies 401 Bad credentials (observed 2026-07-01: pod 7h49m old, all writes 401 while reads on a
#   separate long-lived PAT kept working).
#
# THE FIX (this proxy): point github-mcp-server at THIS sidecar via GITHUB_HOST=http://localhost.
#   github-mcp-server treats any non-github.com / non-*.ghe.com host as GitHub Enterprise Server, so
#   it honors the http scheme (no TLS) and calls us at /api/v3/* (REST) and /api/graphql (GraphQL).
#   NOTE it strips the port (url.Hostname()), so it always calls :80 — this proxy MUST bind :80.
#   github-mcp-server sets its OWN `Authorization: Bearer <dummy>` header; we REPLACE it with the
#   CURRENT token read fresh, per request, from a Pattern-1 native `secret` volume that the kubelet
#   keeps in sync with the ESO-refreshed Secret. Token is therefore always < ~31m old, well inside
#   the 1h TTL, with ZERO pod restarts. The user JWT never reaches here (it stops at the mesh
#   gateway); GitHub-side identity is the App bot, exactly as before.
#
# All values verified live 2026-07-01: http accepted, :80, own-auth-header replaced, list_issues
# uses POST /api/graphql (so GraphQL rewriting is required, not just REST).
import os, sys, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN_FILE = os.environ.get("TOKEN_FILE", "/creds/GITHUB_PERSONAL_ACCESS_TOKEN")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "80"))
API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"

# Response headers we must NOT copy verbatim (we re-derive length; encoding was stripped upstream).
_HOP = {"content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive"}


def read_token():
    with open(TOKEN_FILE, "r") as f:
        return f.read().strip()


def target_url(path):
    # GHES path layout -> github.com dotcom layout (each keeps any ?query intact).
    if path.startswith("/api/graphql"):
        return API + "/graphql" + path[len("/api/graphql"):]
    if path.startswith("/api/v3/"):
        return API + path[len("/api/v3"):]          # strip the /api/v3 prefix, keep leading /
    if path.startswith("/api/uploads/"):
        return UPLOADS + path[len("/api/uploads"):]
    # Defensive fallback: forward as-is to the REST host.
    return API + path


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None
        url = target_url(self.path)

        try:
            token = read_token()
        except Exception as e:
            self._fail(500, f"token file unreadable: {e}")
            return

        # Build a clean header set. Replace Authorization; strip Accept-Encoding (no gzip so we can
        # re-length the body); preserve Accept + Content-Type so REST vs GraphQL negotiation works.
        headers = {
            "Authorization": f"Bearer {token}",
            "User-Agent": self.headers.get("User-Agent", "gh-token-proxy"),
            "Accept": self.headers.get("Accept", "application/vnd.github+json"),
        }
        ct = self.headers.get("Content-Type")
        if ct:
            headers["Content-Type"] = ct
        gh_api_version = self.headers.get("X-GitHub-Api-Version")
        if gh_api_version:
            headers["X-GitHub-Api-Version"] = gh_api_version

        req = urllib.request.Request(url, data=body, method=self.command, headers=headers)
        try:
            resp = urllib.request.urlopen(req, timeout=30)
            status, resp_headers, payload = resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as e:
            # Forward GitHub's real status + body (e.g. 401/403/422) so github-mcp-server sees it.
            status, resp_headers, payload = e.code, e.headers, e.read()
        except Exception as e:
            self._fail(502, f"upstream error: {e}")
            return

        sys.stderr.write(f"[gh-token-proxy] {self.command} {self.path} -> {url} : {status}\n")
        sys.stderr.flush()

        self.send_response(status)
        for k, v in resp_headers.items():
            if k.lower() in _HOP:
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def _fail(self, code, msg):
        sys.stderr.write(f"[gh-token-proxy] ERROR {code}: {msg}\n")
        sys.stderr.flush()
        b = msg.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    do_GET = _handle
    do_POST = _handle
    do_PATCH = _handle
    do_PUT = _handle
    do_DELETE = _handle

    def log_message(self, *a):
        pass  # we log ourselves (without the token)


def main():
    # Fail fast + loud if the token volume is not mounted yet.
    if not os.path.exists(TOKEN_FILE):
        sys.stderr.write(f"[gh-token-proxy] WARN token file {TOKEN_FILE} not present yet\n")
    srv = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    sys.stderr.write(f"[gh-token-proxy] listening on :{LISTEN_PORT}, injecting from {TOKEN_FILE}\n")
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == "__main__":
    main()
