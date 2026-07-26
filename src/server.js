import http from 'node:http';
import crypto from 'node:crypto';
import pg from 'pg';

/**
 * App de referencia do bake-off.
 *
 * Identico em todos os provedores. A UNICA variavel do experimento
 * deve ser o provedor — por isso nada de dependencia pesada, nada de
 * framework, nada que introduza diferenca de warm-up entre plataformas.
 *
 * Endpoints medem coisas diferentes de proposito:
 *   /health  -> lat\u00eancia pura de rede + roteamento (sem trabalho)
 *   /db      -> ida e volta ao banco (mede a proximidade banco<->app)
 *   /cpu     -> trabalho de CPU fixo (mede a CPU real que voce recebeu)
 *   /payload -> 100 KB (mede throughput e compressao do edge)
 */

const PROVIDER = process.env.PROVIDER_NAME || 'desconhecido';
const REGION = process.env.PROVIDER_REGION || '-';
const BOOTED = Date.now();

const pool = process.env.DATABASE_URL
  ? new pg.Pool({
      connectionString: process.env.DATABASE_URL,
      max: 3,
      connectionTimeoutMillis: 5000,
      ssl: process.env.PGSSL === 'off' ? false : { rejectUnauthorized: false }
    })
  : null;

// Payload gerado uma vez no boot, nao a cada request.
const PAYLOAD = JSON.stringify({
  note: 'payload fixo de ~100KB para medir throughput',
  data: Array.from({ length: 1200 }, (_, i) => ({
    i, uuid: crypto.randomUUID(), text: 'x'.repeat(40)
  }))
});

/** Trabalho de CPU deterministico. Mesmo custo em qualquer maquina,
 *  entao a diferenca de tempo revela a CPU que voce realmente recebeu. */
function burnCpu(rounds = 120_000) {
  let h = crypto.createHash('sha256');
  for (let i = 0; i < rounds; i++) h = crypto.createHash('sha256').update(String(i));
  return h.digest('hex').slice(0, 12);
}

async function initSchema() {
  if (!pool) return;
  await pool.query(`
    CREATE TABLE IF NOT EXISTS probe (
      id SERIAL PRIMARY KEY,
      created_at TIMESTAMPTZ DEFAULT now(),
      payload TEXT
    )`);
  const { rows } = await pool.query('SELECT count(*)::int AS n FROM probe');
  if (rows[0].n < 500) {
    await pool.query(
      `INSERT INTO probe (payload)
       SELECT md5(random()::text) FROM generate_series(1, $1)`,
      [500 - rows[0].n]
    );
  }
}

function send(res, status, body, extra = {}) {
  const json = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Provider': PROVIDER,
    'X-Region': REGION,
    ...extra
  });
  res.end(json);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const t0 = process.hrtime.bigint();
  const ms = () => Number(process.hrtime.bigint() - t0) / 1e6;

  try {
    switch (url.pathname) {
      case '/health':
        return send(res, 200, {
          ok: true, provider: PROVIDER, region: REGION,
          uptimeSec: Math.round((Date.now() - BOOTED) / 1000),
          serverMs: ms()
        });

      case '/db': {
        if (!pool) return send(res, 503, { error: 'sem DATABASE_URL' });
        const { rows } = await pool.query(
          'SELECT id, created_at FROM probe ORDER BY random() LIMIT 10'
        );
        return send(res, 200, { provider: PROVIDER, rows: rows.length, serverMs: ms() });
      }

      case '/cpu':
        return send(res, 200, {
          provider: PROVIDER, digest: burnCpu(), serverMs: ms()
        });

      case '/payload':
        return send(res, 200, PAYLOAD);

      default:
        return send(res, 404, { error: 'not_found' });
    }
  } catch (err) {
    return send(res, 500, { error: String(err.message).slice(0, 200), serverMs: ms() });
  }
});

initSchema()
  .catch((e) => console.error('schema falhou (seguindo mesmo assim):', e.message))
  .finally(() => {
    const port = Number(process.env.PORT || 3000);
    server.listen(port, () => console.log(`probe ${PROVIDER}/${REGION} :${port}`));
  });
