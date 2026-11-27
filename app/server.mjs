import { createServer } from 'node:http';

export function createServers(app) {
  const options = { headersTimeout: 5000, requestTimeout: 10000, keepAliveTimeout: 3000, maxHeaderSize: 8192 };
  const web = createServer(options, app.handle);
  const scraper = createServer(options, (req, res) => {
    if (req.method !== 'GET' || req.url !== '/metrics') {
      res.writeHead(404);
      return res.end();
    }
    let metrics;
    try {
      metrics = app.metrics();
    } catch {
      res.writeHead(503, { 'cache-control': 'no-store' });
      return res.end();
    }
    res.writeHead(200, {
      'content-type': 'text/plain; version=0.0.4; charset=utf-8',
      'cache-control': 'no-store',
    });
    return res.end(metrics);
  });

  for (const server of [web, scraper]) {
    server.maxRequestsPerSocket = 100;
    server.maxConnections = 128;
    server.setTimeout(12000, (socket) => socket.destroy());
  }
  return { web, scraper };
}
