#!/usr/bin/env python3
"""tailcat funnel 后端：静态文件 + 设备 token 上传接口。

- GET  /...            静态文件（仅 SITE_DIR 内）
- POST /api/token      上传设备 token；需 X-Upload-Key 匹配 upload key 文件
- 其余方法/路径        404 / 405

token 追加写入 DATA_FILE（每行一个 JSON 对象），本机直接读取，
不提供任何读取接口。

环境变量：
  TAILCAT_SITE_DIR        静态文件目录（默认 ../site 相对本文件）
  TAILCAT_DATA_FILE       token 存储路径（默认 ./data/tokens.jsonl）
  TAILCAT_UPLOAD_KEY_FILE upload key 文件（默认 ./secrets/upload-key）
  TAILCAT_ACCESS_LOG      访问日志（默认 ./logs/access.log）
  TAILCAT_PORT            监听端口（默认 8090，仅 127.0.0.1）
"""

import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE = Path(__file__).resolve().parent
SITE_DIR = Path(os.environ.get("TAILCAT_SITE_DIR", BASE.parent / "site")).resolve()
DATA_FILE = Path(os.environ.get("TAILCAT_DATA_FILE", BASE / "data" / "tokens.jsonl"))
ACCESS_LOG = Path(os.environ.get("TAILCAT_ACCESS_LOG", BASE / "logs" / "access.log"))
PORT = int(os.environ.get("TAILCAT_PORT", "8090"))
UPLOAD_KEY = Path(
    os.environ.get("TAILCAT_UPLOAD_KEY_FILE", BASE / "secrets" / "upload-key")
).read_text().strip()

TOKEN_RE = re.compile(r"^tc[A-Za-z0-9_-]{1,200}$")
HOST_RE = re.compile(r"^[A-Za-z0-9._-]{1,253}$")
MAX_BODY = 4096


class Handler(BaseHTTPRequestHandler):
    server_version = "tailcat-funnel/1.0"

    def log_message(self, fmt, *args):
        line = "%s - %s" % (self.address_string(), fmt % args)
        with open(ACCESS_LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), line))

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if body:
            self.wfile.write(body)

    # ---- static ----

    def do_GET(self):
        rel = self.path.split("?", 1)[0].split("#", 1)[0]
        if rel == "/":
            rel = "/index.html"
        # 防目录穿越：解析后必须仍在 SITE_DIR 内
        target = (SITE_DIR / rel.lstrip("/")).resolve()
        if not str(target).startswith(str(SITE_DIR) + "/") or not target.is_file():
            self._send(404, "not found\n")
            return
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".sh": "text/plain; charset=utf-8",
            ".txt": "text/plain; charset=utf-8",
        }.get(target.suffix, "application/octet-stream")
        self._send(200, target.read_bytes(), ctype)

    # ---- token upload ----

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/api/token":
            self._send(404, "not found\n")
            return
        if self.headers.get("X-Upload-Key", "") != UPLOAD_KEY:
            self._send(403, "forbidden\n")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, "bad content-length\n")
            return
        if length <= 0 or length > MAX_BODY:
            self._send(400, "bad body size\n")
            return
        try:
            payload = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send(400, "bad json\n")
            return
        token = str(payload.get("token", ""))
        host = str(payload.get("host", ""))
        if not TOKEN_RE.match(token):
            self._send(400, "bad token\n")
            return
        if host and not HOST_RE.match(host):
            host = ""
        record = {
            "ts": int(time.time()),
            "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "token": token,
            "host": host,
            "ip": self.headers.get("X-Forwarded-For", self.client_address[0]),
        }
        DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(DATA_FILE, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        self._send(200, '{"ok":true}\n', "application/json")

    def do_PUT(self):
        self._send(405, "method not allowed\n")

    def do_DELETE(self):
        self._send(405, "method not allowed\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
