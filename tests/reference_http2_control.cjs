const fs = require('node:fs');
const http2 = require('node:http2');
let holding = 0;
let released = 0;

const server = http2.createSecureServer({
  cert: fs.readFileSync(process.argv[2]),
  key: fs.readFileSync(process.argv[3]),
}, (request, response) => {
  request.on('error', () => {});
  response.on('error', () => {});
  if (request.url === '/stream-cancel') {
    holding++;
    response.on('close', () => released++);
    response.write('data: first\n\n');
    return;
  }
  if (request.url === '/inspect') {
    response.end(JSON.stringify({holding, released}));
    return;
  }
  const chunks = [];
  request.on('data', chunk => chunks.push(chunk));
  request.on('end', () => {
    const body = request.url === '/large' ? Buffer.alloc(8 * 1024 * 1024, 'x')
      : request.url === '/lifecycle-echo' ? Buffer.concat(chunks) : Buffer.from('ok');
    response.setHeader('Content-Length', body.length);
    response.end(body);
  });
});
server.on('sessionError', () => {});
server.listen(0, '127.0.0.1', function () { console.log(this.address().port); });
