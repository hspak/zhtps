// Compatibility API preserves Node's automatic Expect handling over HTTP/2.
const fs = require('node:fs');
const http2 = require('node:http2');

const server = http2.createSecureServer({
  cert: fs.readFileSync(process.argv[2]),
  key: fs.readFileSync(process.argv[3]),
}, (request, response) => {
  const chunks = [];
  request.on('error', () => {});
  response.on('error', () => {});
  request.on('data', chunk => chunks.push(chunk));
  request.on('end', () => {
    const body = request.url === '/echo' ? Buffer.concat(chunks) : Buffer.from('ZHTPS\n');
    response.setHeader('Content-Length', body.length);
    response.end(body);
  });
});
server.on('sessionError', () => {});
server.listen(0, '127.0.0.1', function () {
  console.log(this.address().port);
});
