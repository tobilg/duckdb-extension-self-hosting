// Two static servers: the page, and a cross-origin extension repository that behaves like a public bucket.
// node server.cjs <page_dir> <dist_dir> <repository_dir> <page_port> <repository_port> <request_log>
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const [pageDir, distDir, repositoryDir, pagePort, repositoryPort, logFile] = process.argv.slice(2);
const log = fs.createWriteStream(logFile, {flags: 'a'});
const types = {'.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json'};

function resolve(root, urlPath) {
    const target = path.normalize(path.join(root, decodeURIComponent(urlPath)));
    if (!target.startsWith(path.normalize(root))) return null;
    return fs.existsSync(target) && !fs.statSync(target).isDirectory() ? target : null;
}

http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x').pathname;
    const target = url === '/' ? path.join(pageDir, 'index.html')
        : url.startsWith('/dist/') ? resolve(distDir, url.slice(6)) : resolve(pageDir, url);
    if (!target) {
        res.writeHead(404);
        return res.end();
    }
    res.writeHead(200, {'Content-Type': types[path.extname(target)] || 'application/octet-stream'});
    return res.end(fs.readFileSync(target));
}).listen(Number(pagePort), '127.0.0.1');

// The action's Wasm objects are Brotli, like a bucket would hold them. The plain route holds them decompressed.
http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x').pathname;
    const route = url.split('/')[1];
    const headers = route === 'nocors' ? {} : {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
        'Access-Control-Allow-Headers': '*',
    };
    if (req.method === 'OPTIONS') {
        res.writeHead(204, headers);
        return res.end();
    }
    const target = resolve(repositoryDir, url);
    log.write(`${req.method} ${url} ${target ? 200 : 404}\n`);
    if (!target) {
        res.writeHead(404, headers);
        return res.end();
    }
    const body = fs.readFileSync(target);
    headers['Content-Type'] = types[path.extname(target)] || 'application/octet-stream';
    if (target.endsWith('.wasm') && route !== 'plain') headers['Content-Encoding'] = 'br';
    headers['Content-Length'] = body.length;
    res.writeHead(200, headers);
    return res.end(req.method === 'HEAD' ? undefined : body);
}).listen(Number(repositoryPort), '127.0.0.1');
