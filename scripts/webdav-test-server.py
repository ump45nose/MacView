#!/usr/bin/env python3
"""只读 WebDAV 测试服务：支持 PROPFIND、HEAD 与 Range GET。"""

import argparse
import base64
import email.utils
import http.server
import os
import posixpath
import socketserver
import sys
import urllib.parse
import xml.etree.ElementTree as ET


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class WebDAVHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def _check_auth(self):
        user = self.server.auth_user
        password = self.server.auth_password
        if not user and not password:
            return True
        expected = "Basic " + base64.b64encode("{}:{}".format(user, password).encode("utf-8")).decode("ascii")
        if self.headers.get("Authorization") == expected:
            return True
        body = b"Unauthorized"
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="MacView"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return False

    def _resolve_path(self):
        raw_path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        norm = posixpath.normpath(raw_path)
        parts = [p for p in norm.split("/") if p and p != "."]
        if any(p == ".." for p in parts):
            return None, None
        root = os.path.realpath(self.server.root_dir)
        fs_path = os.path.realpath(os.path.join(root, *parts)) if parts else root
        if fs_path != root and not fs_path.startswith(root + os.sep):
            return None, None
        href = "/" + "/".join(urllib.parse.quote(p, safe="") for p in parts)
        if os.path.isdir(fs_path) and not href.endswith("/"):
            href += "/"
        return fs_path, href

    def _etag(self, st):
        return '"{:x}-{:x}"'.format(st.st_mtime_ns, st.st_size)

    def _prop_response(self, href, fs_path):
        st = os.stat(fs_path)
        is_dir = os.path.isdir(fs_path)
        resp = ET.Element("D:response")
        ET.SubElement(resp, "D:href").text = href
        propstat = ET.SubElement(resp, "D:propstat")
        prop = ET.SubElement(propstat, "D:prop")
        rt = ET.SubElement(prop, "D:resourcetype")
        if is_dir:
            ET.SubElement(rt, "D:collection")
        else:
            ET.SubElement(prop, "D:getcontentlength").text = str(st.st_size)
        ET.SubElement(prop, "D:getlastmodified").text = email.utils.formatdate(st.st_mtime, usegmt=True)
        ET.SubElement(prop, "D:getetag").text = self._etag(st)
        ET.SubElement(propstat, "D:status").text = "HTTP/1.1 200 OK"
        return resp

    def do_PROPFIND(self):
        if not self._check_auth():
            return
        fs_path, href = self._resolve_path()
        if fs_path is None or not os.path.exists(fs_path):
            self.send_error(404)
            return
        depth = self.headers.get("Depth", "1")
        multistatus = ET.Element("D:multistatus", {"xmlns:D": "DAV:"})
        multistatus.append(self._prop_response(href, fs_path))
        if os.path.isdir(fs_path) and depth != "0":
            for name in sorted(os.listdir(fs_path)):
                child_fs = os.path.join(fs_path, name)
                child_href = href.rstrip("/") + "/" + urllib.parse.quote(name, safe="")
                if os.path.isdir(child_fs):
                    child_href += "/"
                multistatus.append(self._prop_response(child_href, child_fs))
        body = b'<?xml version="1.0" encoding="utf-8"?>' + ET.tostring(multistatus, encoding="utf-8")
        self.send_response(207, "Multi-Status")
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_file(self, send_body):
        if not self._check_auth():
            return
        fs_path, _ = self._resolve_path()
        if fs_path is None or not os.path.isfile(fs_path):
            self.send_error(404)
            return
        st = os.stat(fs_path)
        size = st.st_size
        range_header = self.headers.get("Range")
        start, end, status = 0, size - 1, 200
        if range_header and range_header.startswith("bytes="):
            spec = range_header[6:].split(",", 1)[0].strip()
            parts = spec.split("-", 1)
            if len(parts) == 2:
                try:
                    if parts[0] == "":
                        suffix = int(parts[1])
                        start = max(0, size - suffix)
                        end = size - 1
                    else:
                        start = int(parts[0])
                        end = int(parts[1]) if parts[1] else size - 1
                    if start >= size or start > end or start < 0:
                        self.send_response(416)
                        self.send_header("Content-Range", "bytes */{}".format(size))
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    end = min(end, size - 1)
                    status = 206
                except ValueError:
                    pass

        length = max(0, end - start + 1) if size > 0 else 0
        self.send_response(status)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", self._etag(st))
        self.send_header("Last-Modified", email.utils.formatdate(st.st_mtime, usegmt=True))
        if status == 206:
            self.send_header("Content-Range", "bytes {}-{}/{}".format(start, end, size))
        self.send_header("Content-Length", str(length))
        self.end_headers()
        if send_body and length > 0:
            with open(fs_path, "rb") as fp:
                fp.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = fp.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)

    def do_GET(self):
        self._serve_file(True)

    def do_HEAD(self):
        self._serve_file(False)


def main():
    parser = argparse.ArgumentParser(description="MacView 只读 WebDAV 测试服务")
    parser.add_argument("--root", required=True, help="根目录")
    parser.add_argument("--port", type=int, default=8080, help="监听端口（0 为随机端口）")
    parser.add_argument("--user", default="", help="Basic 认证用户名")
    parser.add_argument("--password", default="", help="Basic 认证密码")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), WebDAVHandler)
    server.root_dir = os.path.abspath(args.root)
    server.auth_user = args.user
    server.auth_password = args.password
    actual_port = server.server_address[1]
    sys.stdout.write("READY http://127.0.0.1:{}/\n".format(actual_port))
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
