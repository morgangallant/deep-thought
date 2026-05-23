#!/bin/bash
# Setup script for the deep-thought VM on exe.dev.
#
# Expects two env vars (passed via `ssh exe.dev new --env ...`):
#   EMAIL_ADDRESS  - recipient for answer emails
#   SHARED_SECRET  - bearer token the iOS shortcut presents
#
# After this runs, ssh into the VM and run `claude login` once so the
# systemd service (running as root) can use the credentials.

set -euo pipefail

PORT=8000

cat > /etc/deep-thought.env <<EOF
EMAIL_ADDRESS=${EMAIL_ADDRESS}
SHARED_SECRET=${SHARED_SECRET}
PORT=${PORT}
EOF
chmod 600 /etc/deep-thought.env

mkdir -p /opt/deep-thought
cat > /opt/deep-thought/server.py <<'PYEOF'
#!/usr/bin/env python3
"""HTTP server that dispatches questions to claude-code and emails the answer."""
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import urllib.request

SHARED_SECRET = os.environ["SHARED_SECRET"]
EMAIL_ADDRESS = os.environ["EMAIL_ADDRESS"]
PORT = int(os.environ.get("PORT", "8000"))

EMAIL_GATEWAY = "http://169.254.169.254/gateway/email/send"


def log(msg):
    print(msg, flush=True)


def send_email(subject, body):
    payload = json.dumps({"to": EMAIL_ADDRESS, "subject": subject, "body": body}).encode()
    req = urllib.request.Request(
        EMAIL_GATEWAY,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            log(f"email sent: {resp.status} {resp.read()!r}")
    except Exception as e:
        log(f"email failed: {e}")


SYSTEM_PROMPT = """\
You are answering a question that arrived from the user's iOS shortcut. \
Your final reply will be sent to them by email, so write for that medium: \
plain text, no markdown headings or bullet decoration, clear prose, paragraphs \
separated by blank lines. The user is not watching you work and cannot reply, \
so deliver a complete, self-contained answer.

Approach every question with care:
  - Restate the question in your own words if it is ambiguous, then proceed \
with the most reasonable interpretation.
  - Think step by step. Do not guess. If you do not know, say so.
  - Research using your web tools (WebSearch, WebFetch) whenever the answer \
depends on current facts, specific sources, or anything you are unsure about. \
Prefer primary sources.
  - You are free to download files, clone repos, or fetch documents into a \
temporary directory (e.g. under /tmp) if reading code or PDFs would help. \
Clean up when done.
  - Cite sources inline as bare URLs in parentheses, e.g. (https://example.com/page). \
At the end of the answer, list the sources you actually used under a line \
that simply reads "Sources:" — one URL per line. Omit the section if you \
genuinely used none.

Length: as long as needed and no longer. A factual question deserves a tight \
answer; a research question deserves depth. Do not pad."""


def run_agent(question):
    log(f"running agent for: {question[:120]!r}")
    try:
        result = subprocess.run(
            [
                "claude",
                "-p",
                "--dangerously-skip-permissions",
                "--append-system-prompt", SYSTEM_PROMPT,
                question,
            ],
            capture_output=True,
            text=True,
            timeout=1800,
        )
        answer = result.stdout.strip()
        if not answer:
            answer = (result.stderr.strip() or "(no output)")
        if result.returncode != 0:
            answer = f"(claude exited {result.returncode})\n\n{answer}"
    except subprocess.TimeoutExpired:
        answer = "Agent timed out after 30 minutes."
    except Exception as e:
        answer = f"Agent error: {e}"

    subject_q = question.strip().splitlines()[0] if question.strip() else "(empty question)"
    if len(subject_q) > 80:
        subject_q = subject_q[:77] + "..."
    body = f"Q: {question}\n\n---\n\n{answer}"
    send_email(f"deep-thought: {subject_q}", body)


class Handler(http.server.BaseHTTPRequestHandler):
    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._json(200, {"status": "ok"})

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        expected = f"Bearer {SHARED_SECRET}"
        if auth != expected:
            self._json(401, {"error": "unauthorized"})
            return

        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b""
        question = ""
        try:
            data = json.loads(raw or b"{}")
            if isinstance(data, dict):
                question = (data.get("question") or data.get("q") or "").strip()
        except json.JSONDecodeError:
            question = raw.decode(errors="replace").strip()

        if not question:
            self._json(400, {"error": "missing question"})
            return

        threading.Thread(target=run_agent, args=(question,), daemon=True).start()
        self._json(202, {"status": "queued"})

    def log_message(self, fmt, *args):
        log(fmt % args)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    log(f"deep-thought listening on :{PORT}")
    Server(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF

cat > /etc/systemd/system/deep-thought.service <<'EOF'
[Unit]
Description=deep-thought agent server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=exedev
Group=exedev
WorkingDirectory=/home/exedev
EnvironmentFile=/etc/deep-thought.env
ExecStart=/usr/bin/python3 /opt/deep-thought/server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now deep-thought.service
