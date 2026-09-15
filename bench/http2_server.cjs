// Shared single-process HTTP/2 fixture for Node and Bun.
const fs = require('node:fs');
const http2 = require('node:http2');

const [port, certificate, key] = process.argv.slice(2);
if (!port || !certificate || !key) {
  throw new Error('usage: runtime bench/http2_server.cjs PORT CERTIFICATE KEY');
}
const body = Buffer.from('ZHTPS\n');
const server = http2.createSecureServer({
  cert: fs.readFileSync(certificate),
  key: fs.readFileSync(key),
  minVersion: 'TLSv1.3',
  maxVersion: 'TLSv1.3',
  allowHTTP1: false,
  settings: { maxConcurrentStreams: 100 },
});
server.on('stream', (stream, headers) => {
  if (headers[':method'] !== 'GET' || headers[':path'] !== '/') {
    stream.respond({ ':status': 404 });
    stream.end();
    return;
  }
  stream.respond({
    ':status': 200,
    'content-type': 'text/plain; charset=utf-8',
    'etag': '"zhtps-root-v1"',
    'content-length': '6',
  });
  stream.end(body);
});
server.listen(Number(port), '127.0.0.1');
