#!/usr/bin/env python3
"""tailcat funnel 后端：纯静态文件服务。

- GET  /...            静态文件（仅 SITE_DIR 内）
- 其余方法/路径        404 / 405

设备 token 不经过本服务：tailcat 不回传 token，token 由用户在设备上
查看（终端文本/二维码）后手动转发。

环境变量：
  TAILCAT_SITE_DIR        静态文件目录（默认 ../site 相对本文件）
  TAILCAT_ACCESS_LOG      访问日志（默认 ./logs/access.log）
  TAILCAT_PORT            监听端口（默认 8090，仅 127.0.0.1）
"""

import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE = Path(__file__).resolve().parent
SITE_DIR = Path(os.environ.get("TAILCAT_SITE_DIR", BASE.parent / "site")).resolve()
ACCESS_LOG = Path(os.environ.get("TAILCAT_ACCESS_LOG", BASE / "logs" / "access.log"))
PORT = int(os.environ.get("TAILCAT_PORT", "8090"))


class Handler(BaseHTTPRequestHandler):
    server_version = "tailcat-funnel/1.1"

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

    def do_POST(self):
        self._send(405, "method not allowed\n")

    def do_PUT(self):
        self._send(405, "method not allowed\n")

    def do_DELETE(self):
        self._send(405, "method not allowed\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
