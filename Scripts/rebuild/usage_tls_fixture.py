#!/usr/bin/env python3
"""Finite, loopback-only TLS peer for the native UsageTransport tests."""
import argparse
import json
from pathlib import Path
import signal
import ssl
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('--wrong-host', action='store_true')
args = parser.parse_args()
signal.alarm(90)
root = args.directory
root.mkdir(parents=True, exist_ok=True)
names = 'DNS:localhost' if args.wrong_host else 'DNS:eu.i.posthog.com,DNS:us.i.posthog.com'
(root / 'openssl.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=Flux local TLS fixture\n[extensions]\nsubjectAltName=' + names + '\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n')
subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(root / 'openssl.cnf'), '-keyout', str(root / 'key.pem'), '-out', str(root / 'ca.pem')], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=10)
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *unused):
        pass

    def do_POST(self):
        self.connection.settimeout(12)
        count = int(self.headers.get('Content-Length', '0'))
        if not 0 < count <= 65536:
            self.send_error(400)
            return
        body = self.rfile.read(count)
        with lock, (root / 'requests.jsonl').open('a') as output:
            output.write(json.dumps({'path': self.path, 'headers': dict(self.headers), 'body': body.decode('utf-8')}) + '\n')
        try:
            mode = json.loads(body).get('mode', 'ok')
            if mode == 'stall':
                time.sleep(12)
            self.send_response(302 if mode == 'redirect' else 503 if mode == 'error' else 200)
            if mode == 'redirect':
                self.send_header('Location', 'https://eu.i.posthog.com/leaked')
            if mode == 'headers':
                for index in range(20):
                    self.send_header('X-Padding-' + str(index), 'x' * 1000)
            if mode == 'advertised':
                self.send_header('Content-Length', '65537')
                self.end_headers()
                return
            if mode == 'chunked':
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                for _ in range(9):
                    block = b'x' * 8192
                    self.wfile.write(('%x\r\n' % len(block)).encode() + block + b'\r\n')
                    self.wfile.flush()
                self.wfile.write(b'0\r\n\r\n')
                return
            response = b'x' * 65536 if mode == 'limit' else b'{"status":"Ok"}'
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(response)))
            self.end_headers()
            self.wfile.write(response)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(str(root / 'ca.pem'), str(root / 'key.pem'))
server.socket = context.wrap_socket(server.socket, server_side=True)
(root / 'ready.json').write_text(json.dumps({'port': server.server_port, 'caPath': str(root / 'ca.pem')}))
server.serve_forever(poll_interval=0.1)
