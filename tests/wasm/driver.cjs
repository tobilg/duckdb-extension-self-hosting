// Checks in headless Chrome that DuckDB-Wasm loads what the action signed, and only that.
// node driver.cjs <page_port> <repository_port> <public_key> <other_public_key> <version_directory> <request_log>
const fs = require('node:fs');
const puppeteer = require('puppeteer-core');

const [pagePort, repositoryPort, keyFile, otherKeyFile, versionDir, logFile] = process.argv.slice(2);
const KEY = fs.readFileSync(keyFile, 'utf8').trim();
const OTHER_KEY = fs.readFileSync(otherKeyFile, 'utf8').trim();
const REPOSITORY = `http://127.0.0.1:${repositoryPort}`;
const OPT_IN = "SET allow_extension_repositories = 'allowed'";
const STORE_FILES = 'opfs://home/.duckdb/extension_repositories/*.repo.json';
const INET = "SELECT '127.0.0.1'::INET AS ip";
const LOADED = "SELECT extension_name FROM duckdb_extensions() WHERE loaded AND install_mode = 'REPOSITORY' ORDER BY 1";
const NOT_SIGNED = /signature is either missing or invalid/;
// The home directory outside OPFS, which needs no registration step but doesn't persist.
const IN_MEMORY = {homeDirectory: '/home/web_user'};

const create = (name, route, key, ifNotExists) =>
    `CREATE EXTENSION REPOSITORY ${ifNotExists ? 'IF NOT EXISTS ' : ''}${name} WITH PREFIX '${REPOSITORY}/${route}' USING PUBLIC KEY '${key}'`;

function findChrome() {
    const candidates = [
        process.env.CHROME_BIN,
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/usr/bin/google-chrome',
        '/usr/bin/chromium',
    ];
    const found = candidates.find((candidate) => candidate && fs.existsSync(candidate));
    if (!found) throw new Error('Chrome not found, set CHROME_BIN');
    return found;
}

let failures = 0;
let checks = 0;
function report(ok, title, detail) {
    checks += 1;
    if (ok) {
        console.log(`ok   ${title}`);
    } else {
        failures += 1;
        console.log(`FAIL ${title}${detail ? `\n     ${detail}` : ''}`);
    }
}
const short = (value) => JSON.stringify(value).slice(0, 300);

(async () => {
    const browser = await puppeteer.launch({
        headless: true,
        executablePath: findChrome(),
        args: ['--no-first-run', '--no-default-browser-check', ...(process.env.CI ? ['--no-sandbox'] : [])],
    });

    // Every scenario gets its own browser context, and with that its own OPFS.
    async function scenario(title, body) {
        console.log(`\n--- ${title}`);
        const context = await browser.createBrowserContext();
        const page = await context.newPage();
        page.on('pageerror', (error) => report(false, 'no page errors', error.message.slice(0, 200)));
        const open = async () => {
            await page.goto(`http://127.0.0.1:${pagePort}/`);
            await page.waitForFunction('window.ready === true');
        };
        await open();
        const t = {
            boot: (config) => page.evaluate((c) => window.boot(c), config || {}),
            stop: () => page.evaluate(() => window.stop()),
            reload: open,
            query: (sql) => page.evaluate((s) => window.q(s), sql),
            register: () => page.evaluate((n) => window.registerOpfs(n, 'read'), STORE_FILES),
            async ok(check, sql) {
                const result = await t.query(sql);
                report(result.ok, check, result.ok ? '' : result.error.slice(0, 300));
                return result;
            },
            async fails(check, sql, pattern) {
                const result = await t.query(sql);
                report(!result.ok && pattern.test(result.error), check, short(result));
            },
        };
        try {
            await body(t);
        } catch (error) {
            report(false, `${title} finished`, String(error.message).slice(0, 300));
        }
        await context.close();
    }

    // The OPFS setup from the README, run again after a reload like every page load would. A repository that already
    // exists has to be prepared before CREATE ... IF NOT EXISTS reads it, and a new one after CREATE wrote it.
    const recommended = async (t, check) => {
        const before = await t.register();
        report(before.ok, `${check}: prepare existing repositories`, short(before));
        await t.ok(`${check}: opt in`, OPT_IN);
        await t.ok(`${check}: pin the key`, create('my_repo', 'good', KEY, true));
        const after = await t.register();
        report(after.ok && after.rows.length === 1, `${check}: prepare the new repository`, short(after));
    };

    await scenario('browser setup with the home directory in OPFS', async (t) => {
        const version = await t.boot();
        console.log(`DuckDB-Wasm ${version}`);
        await recommended(t, 'first load');
        await t.ok('LOAD a C_STRUCT build by repository name', 'LOAD capi_quack FROM my_repo');
        await t.ok('LOAD a CPP build by repository name', 'LOAD inet FROM my_repo');
        const inet = await t.ok('the CPP extension runs', INET);
        report(inet.ok && inet.rows.length === 1, 'and returns a row', short(inet));
        const loaded = await t.ok('both are listed as loaded', LOADED);
        report(loaded.ok && loaded.rows.length === 2, 'two extensions', short(loaded));
        const requests = fs.readFileSync(logFile, 'utf8');
        report(requests.includes(`GET /good/${versionDir}/wasm_eh/capi_quack.duckdb_extension.wasm 200`), 'fetches <prefix>/<version>/<platform>/<name>.duckdb_extension.wasm');

        await t.stop();
        await t.reload();
        await t.boot();
        await recommended(t, 'after a reload');
        await t.ok('the repository persisted, and LOAD works again', 'LOAD capi_quack FROM my_repo');
        await t.ok('so does a second LOAD', 'LOAD inet FROM my_repo');
    });

    await scenario('without the registration step (known DuckDB-Wasm limitation)', async (t) => {
        await t.boot();
        await t.query(OPT_IN);
        await t.query(create('my_repo', 'good', KEY));
        const sameSession = await t.query('LOAD capi_quack FROM my_repo');
        console.log(`note same session, no registration: ${sameSession.ok ? 'works now' : 'fails, as documented in the README'}`);
    });

    await scenario('browser setup with the home directory outside OPFS', async (t) => {
        await t.boot(IN_MEMORY);
        await t.ok('opt in', OPT_IN);
        await t.ok('pin the key', create('my_repo', 'good', KEY));
        await t.ok('LOAD in the same session', 'LOAD capi_quack FROM my_repo');
        await t.ok('INSTALL AND LOAD by repository name', 'INSTALL AND LOAD inet FROM my_repo');
        await t.ok('the extension runs', INET);
        await t.stop();
        await t.reload();
        await t.boot(IN_MEMORY);
        await t.ok('after a reload: opt in', OPT_IN);
        await t.ok('after a reload: the repository is gone, so pinning it again works', create('my_repo', 'good', KEY));
        await t.ok('after a reload: LOAD works', 'LOAD capi_quack FROM my_repo');
    });

    await scenario('what must be rejected', async (t) => {
        await t.boot(IN_MEMORY);
        await t.fails('CREATE needs the opt-in', create('my_repo', 'good', KEY), /not enabled/);
        await t.ok('opt in', OPT_IN);
        await t.ok('pin the key', create('good_repo', 'good', KEY));
        await t.ok('pin a key that did not sign these builds', create('wrong_repo', 'good', OTHER_KEY));
        await t.fails('a build signed with another key', 'LOAD capi_quack FROM wrong_repo', NOT_SIGNED);
        await t.ok('pin the right key for a tampered build', create('tamper_repo', 'tamper', KEY));
        await t.fails('a tampered build', 'LOAD capi_quack FROM tamper_repo', NOT_SIGNED);
        await t.ok('INSTALL by repository name', 'INSTALL capi_quack FROM good_repo');
        await t.fails('a bare LOAD, which only trusts the built-in keys', 'LOAD capi_quack', NOT_SIGNED);
        await t.fails('a direct URL', `LOAD '${REPOSITORY}/good/${versionDir}/wasm_eh/capi_quack.duckdb_extension.wasm'`, NOT_SIGNED);
    });

    await scenario('custom_extension_repository', async (t) => {
        await t.boot(IN_MEMORY);
        await t.ok('set it', `SET custom_extension_repository = '${REPOSITORY}/good'`);
        await t.fails('it only trusts the built-in keys', 'LOAD capi_quack', NOT_SIGNED);
    });

    await scenario('serving', async (t) => {
        await t.boot(IN_MEMORY);
        await t.ok('opt in', OPT_IN);
        await t.ok('pin the key for a bucket without CORS', create('nocors_repo', 'nocors', KEY));
        await t.fails('a bucket without CORS can not be read', 'LOAD capi_quack FROM nocors_repo', /could not be fetched/);
        await t.ok('pin the key for uncompressed objects', create('plain_repo', 'plain', KEY));
        await t.ok('uncompressed objects load too', 'LOAD capi_quack FROM plain_repo');
    });

    await scenario('rotation', async (t) => {
        await t.boot(IN_MEMORY);
        await t.ok('opt in', OPT_IN);
        await t.ok('pin two keys', `CREATE EXTENSION REPOSITORY r WITH PREFIX '${REPOSITORY}/rotated' USING PUBLIC KEYS '${KEY}', '${OTHER_KEY}'`);
        await t.ok('a build signed with the second key loads', 'LOAD capi_quack FROM r');
    });

    await browser.close();
    console.log(`\n${checks} checks, ${failures} failed`);
    process.exit(failures === 0 ? 0 : 1);
})().catch((error) => {
    console.error('driver failed', error);
    process.exit(1);
});
