#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import http.server
import socketserver
import os
import sys

PORT = 9194

class CORSHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(200)
        self.end_headers()

    def log_message(self, format, *args):
        print(f"  [{self.log_date_time_string()}] {args[0]}")

    def guess_type(self, path):
        base, ext = os.path.splitext(path)
        ext = ext.lower()
        if ext == '.txt':
            return 'text/plain; charset=utf-8'
        if ext == '.html':
            return 'text/html; charset=utf-8'
        if ext == '.css':
            return 'text/css; charset=utf-8'
        if ext in ('.js', '.mjs'):
            return 'application/javascript; charset=utf-8'
        if ext == '.json':
            return 'application/json; charset=utf-8'
        return super().guess_type(path)

os.chdir(os.path.dirname(os.path.abspath(__file__)))

print("\n  Matisu 群控管理台")
print(f"  http://localhost:{PORT}/group_control.html")
print(f"  http://localhost:{PORT}/qkurl.txt")
print("\n  按 Ctrl+C 停止服务\n")

with socketserver.TCPServer(("", PORT), CORSHandler) as httpd:
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n  服务已停止")
        sys.exit(0)
