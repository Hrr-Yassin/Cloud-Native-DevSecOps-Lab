"""Exercise the production Node HTTP parsers over anonymous local socket pairs."""

import contextlib
import http.client
import io
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = "https://desk.lab.invalid:8443"

WIRE_SERVER = """
import { createReadStream, createWriteStream } from 'node:fs';
import { Duplex } from 'node:stream';
import { randomBytes } from 'node:crypto';
import { createApplication } from './app/http.mjs';
import { createServers } from './app/server.mjs';
import { openStore } from './app/store.mjs';

const [dbPath, origin, webFd, metricsFd] = process.argv.slice(1);
const store = openStore(dbPath);
const app = createApplication({ store, key: randomBytes(32), origin, log: () => {} });
const { web, scraper } = createServers(app);
function attach(server, descriptor) {
  const options = { fd: Number(descriptor), autoClose: false };
  const stream = Duplex.from({
    readable: createReadStream(null, options),
    writable: createWriteStream(null, options),
  });
  stream.setTimeout = () => stream;
  server.emit('connection', stream);
}
attach(web, webFd);
attach(scraper, metricsFd);
process.on('exit', () => store.close());
"""


class DescriptorReader(io.RawIOBase):
    def __init__(self, fd):
        self.fd = fd

    def readable(self):
        return True

    def readinto(self, buffer):
        if not select.select([self.fd], [], [], 5)[0]:
            raise TimeoutError("Timed out reading the local HTTP response")
        data = os.read(self.fd, len(buffer))
        buffer[:len(data)] = data
        return len(data)


class DescriptorTransport:
    def __init__(self, endpoint):
        self.endpoint = endpoint

    def sendall(self, data):
        fd = self.endpoint.fileno()
        remaining = memoryview(data)
        while remaining:
            remaining = remaining[os.write(fd, remaining):]

    def makefile(self, _mode):
        return io.BufferedReader(DescriptorReader(self.endpoint.fileno()))

    def close(self):
        self.endpoint.close()


class AttachedHTTPClient(http.client.HTTPConnection):
    def __init__(self, endpoint):
        super().__init__("desk.lab.invalid")
        self.transport = DescriptorTransport(endpoint)

    def connect(self):
        self.sock = self.transport


class WireTest(unittest.TestCase):
    def test_public_and_metrics_http_routes_remain_separate(self):
        with contextlib.ExitStack() as stack:
            work = Path(stack.enter_context(tempfile.TemporaryDirectory()))
            web_agent, web_end = socket.socketpair()
            metrics_agent, metrics_end = socket.socketpair()
            for endpoint in (web_agent, web_end, metrics_agent, metrics_end):
                stack.enter_context(endpoint)

            fds = [web_end.fileno(), metrics_end.fileno()]
            process = stack.enter_context(subprocess.Popen(
                ["node", "--disable-warning=ExperimentalWarning", "--input-type=module", "-e",
                 WIRE_SERVER, str(work / "state.sqlite"), ORIGIN, *map(str, fds)],
                cwd=ROOT, pass_fds=fds,
            ))
            stack.callback(self.stop, process)
            web_end.close()
            metrics_end.close()
            web = AttachedHTTPClient(web_agent)
            scraper = AttachedHTTPClient(metrics_agent)

            web.request("GET", "/")
            page = web.getresponse()
            self.assertEqual((page.version, page.status), (11, 200))
            self.assertIn("default-src 'none'", page.getheader("content-security-policy"))
            self.assertIn(b"<h1", page.read())

            web.request("GET", "/readyz")
            ready = web.getresponse()
            self.assertEqual(ready.status, 200)
            self.assertEqual(json.loads(ready.read()), {"status": "ok"})

            web.request("GET", "/metrics")
            forbidden = web.getresponse()
            self.assertEqual(forbidden.status, 404)
            forbidden.read()

            scraper.request("GET", "/metrics")
            report = scraper.getresponse()
            self.assertEqual(report.status, 200)
            self.assertIn("version=0.0.4", report.getheader("content-type"))
            self.assertIn(b"desk_http_requests_total 3\n", report.read())

            scraper.request("GET", "/")
            fallback = scraper.getresponse()
            self.assertEqual(fallback.status, 404)
            fallback.read()

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
