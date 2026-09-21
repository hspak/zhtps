// Optional cert/key select HTTP/2; otherwise use the native HTTP/1 server.
const http = require('node:http');
const http2 = require('node:http2');
const fs = require('node:fs');

function respond(request, response) {
  const name = request.url.split('?')[1];
  request.on('error', () => {});
  response.on('error', () => {});
  if (name === 'panic-before') throw new Error('response comparison panic');
  if (name === 'panic-after') {
    response.write('abc');
    response.flushHeaders();
    setTimeout(() => { throw new Error('response comparison panic'); }, 10);
    return;
  }
  try {
    if (name === 'handler-error') {
      // Native handlers do not return errors; this mapping belongs to the fixture.
      response.writeHead(500);
      response.end('internal error');
    } else if (name.startsWith('stream')) {
      if (name === 'stream-short') response.setHeader('Content-Length', 9);
      if (name === 'stream-long') response.setHeader('Content-Length', 2);
      if (name === 'stream-exact' || name === 'stream-error-exact') response.setHeader('Content-Length', 3);
      if (name === 'stream-trailer') response.setHeader('Trailer', 'x-checksum');
      response.flushHeaders();
      if (name === 'stream-error-before') {
        setTimeout(() => response.destroy(), 10);
      } else if (name === 'stream-error-after' || name === 'stream-error-exact') {
        response.write('abc');
        setTimeout(() => response.destroy(), 10);
      } else if (name === 'stream-trailer') {
        response.write('abc');
        response.addTrailers({'x-checksum': 'ok'});
        response.end();
      } else {
        response.end(name === 'stream-empty' ? '' : 'abc');
      }
    } else {
      let body = name === 'empty' || name.startsWith('status-') ? '' : 'abc';
      if (name.startsWith('status-')) {
        response.statusCode = Number(name.slice(7));
        if (response.statusCode === 304) body = 'abc';
      }
      if (name === 'body-204') response.statusCode = 204;
      if (name === 'body-205') response.statusCode = 205;
      if (name === 'duplicate-cookie') response.setHeader('Set-Cookie', ['a=1', 'b=2']);
      if (name === 'invalid-name') response.setHeader('bad name', 'x');
      if (name === 'invalid-value') response.setHeader('x-test', 'x\r\ny');
      if (name === 'nul-value') response.setHeader('x-test', 'x\x00y');
      if (name === 'whitespace-value') response.setHeader('x-test', ' \tabc\t ');
      if (name === 'empty-field') response.setHeader('x-test', '');
      response.end(body);
    }
  } catch (error) {
    // Handle API validation errors explicitly; the panic probes remain uncaught.
    process.stderr.write(JSON.stringify({api_error: error.code || error.message}) + '\n');
    response.destroy();
  }
}

const server = process.argv.length === 4
  ? http2.createSecureServer({cert: fs.readFileSync(process.argv[2]), key: fs.readFileSync(process.argv[3])}, respond)
  : http.createServer(respond);
server.on('sessionError', () => {});
server.listen(0, '127.0.0.1', function () { console.log(this.address().port); });
