// Short explicit budgets make lifecycle comparisons practical; these are not defaults.
const http = require('node:http');
const reading = Number(process.argv[2]);
let holding = 0;
let released = 0;

const server = http.createServer({
  headersTimeout: reading,
  requestTimeout: reading,
  connectionsCheckingInterval: 10,
  keepAliveTimeout: 300,
  keepAliveTimeoutBuffer: 0,
}, (request, response) => {
  request.on('error', () => {});
  response.on('error', () => {});
  switch (request.url) {
    case '/lifecycle-early':
      response.writeHead(403);
      response.end('denied');
      break;
    case '/lifecycle-echo': {
      const chunks = [];
      request.on('data', chunk => chunks.push(chunk));
      request.on('end', () => response.end(Buffer.concat(chunks)));
      break;
    }
    case '/large':
      response.setHeader('Content-Length', 8 * 1024 * 1024);
      response.end(Buffer.alloc(8 * 1024 * 1024, 'x'));
      break;
    case '/stream-cancel':
      holding++;
      response.on('close', () => released++);
      response.write('data: first\n\n');
      break;
    case '/timeout':
    case '/lifecycle-delay':
      // No application watchdog: this probes the distinction from transport timeouts.
      setTimeout(() => response.end('late'), 250);
      break;
    case '/inspect':
      response.end(JSON.stringify({holding, released}));
      break;
    default:
      response.end('ok');
  }
});
server.setTimeout(600);
server.listen(0, '127.0.0.1', function () { console.log(this.address().port); });
process.once('SIGTERM', () => {
  server.close(() => process.exit(0));
  process.stderr.write('shutdown_started\n');
  setTimeout(() => server.closeAllConnections(), 600).unref();
});
