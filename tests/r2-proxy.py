"""Serves an S3-compatible store over plain HTTP the way Cloudflare R2 serves objects stored with a Content-Encoding.

R2 hands such an object back unpacked to a request that doesn't accept its encoding, unless the object's Cache-Control
has no-transform. The size and hash it lists stay those of the stored bytes. SeaweedFS never does this, so tests/e2e.sh
puts this in front of it. Everything else passes through unchanged, including the signed headers.

Usage: python3 -I tests/r2-proxy.py <port> <store endpoint> <CA file of the store>
Logs each object it unpacks to stderr.
"""

import http.client
import http.server
import ssl
import subprocess
import sys
import urllib.parse

PORT = int(sys.argv[1])
STORE = urllib.parse.urlparse(sys.argv[2])
CONTEXT = ssl.create_default_context(cafile=sys.argv[3])
DROPPED = ("connection", "transfer-encoding", "keep-alive")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", ""):
            body = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return body
                body += self.rfile.read(size)
                self.rfile.readline()
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else None

    def forward(self):
        body = self.read_body()
        headers = {k: v for k, v in self.headers.items() if k.lower() not in DROPPED}
        if body is not None:
            headers["Content-Length"] = str(len(body))
        connection = http.client.HTTPSConnection(STORE.hostname, STORE.port, context=CONTEXT, timeout=300)
        connection.request(self.command, self.path, body=body, headers=headers)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        out = [(k, v) for k, v in response.getheaders() if k.lower() not in DROPPED]
        stored = {k.lower(): v for k, v in out}
        if (
            self.command == "GET"
            and response.status == 200
            and stored.get("content-encoding")
            and "no-transform" not in stored.get("cache-control", "")
            and stored["content-encoding"] not in self.headers.get("Accept-Encoding", "")
        ):
            if stored["content-encoding"] != "br":
                self.send_error(501, "r2-proxy.py only unpacks br")
                return
            data = subprocess.run(["brotli", "-d", "-c"], input=data, capture_output=True, check=True).stdout
            out = [(k, v) for k, v in out if k.lower() not in ("content-encoding", "content-length")]
            out.append(("Content-Length", str(len(data))))
            sys.stderr.write("unpacked %s\n" % urllib.parse.urlparse(self.path).path)
            sys.stderr.flush()
        self.send_response(response.status)
        for k, v in out:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    do_GET = do_HEAD = do_PUT = do_POST = do_DELETE = forward

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
