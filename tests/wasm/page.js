import * as duckdb from '@duckdb/duckdb-wasm';

let db = null;
let conn = null;

function plain(value) {
    return JSON.parse(JSON.stringify(value, (_, v) => {
        if (typeof v === 'bigint') return v.toString();
        if (v && typeof v.toArray === 'function') return Array.from(v.toArray());
        return v;
    }));
}

function failure(error) {
    return {ok: false, error: String(error && error.message ? error.message : error)};
}

window.stop = async () => {
    if (conn) await conn.close().catch(() => {});
    if (db) await db.terminate().catch(() => {});
    conn = null;
    db = null;
};

window.boot = async (config = {}) => {
    await window.stop();
    db = new duckdb.AsyncDuckDB(new duckdb.VoidLogger(), new Worker('/dist/duckdb-browser-base.worker.js'));
    await db.instantiate('/dist/duckdb-base.wasm');
    await db.open(config);
    conn = await db.connect();
    return db.getVersion();
};

window.q = async (sql) => {
    try {
        const table = await conn.query(sql);
        return {ok: true, rows: table.toArray().map((row) => plain(row.toJSON()))};
    } catch (error) {
        return failure(error);
    }
};

window.registerOpfs = async (name, mode) => {
    try {
        return {ok: true, rows: await db.registerOPFSFileName(name, mode)};
    } catch (error) {
        return failure(error);
    }
};

window.ready = true;
