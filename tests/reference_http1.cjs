// Minimal application; keep HTTP parsing, expectations and errors at Node defaults.
const http = require('node:http');

http.createServer((request, response) => {
  const chunks = [];
  request.on('error', () => {});
  request.on('data', chunk => chunks.push(chunk));
  request.on('end', () => {
    const body = request.url === '/echo' ? Buffer.concat(chunks) : Buffer.from('ZHTPS\n');
    response.setHeader('Content-Length', body.length);
    response.end(body);
  });
}).listen(0, '127.0.0.1', function () {
  console.log(this.address().port);
});
