// End-to-end test for the dsh-mcp-client session-recovery patch.
//
// Mounts the REAL (patched or pristine) dsh-mcp-client against a fake
// streamable-HTTP MCP server that can invalidate its session table mid-flight,
// exactly as a restarted stateful server does. Then it asserts whether the
// client recovers on its own without the Host being restarted.
//
// Usage: node run.mjs <path-to-lib/index.js>

import { createServer } from 'node:http'
import { pathToFileURL } from 'node:url'

const target = process.argv[2]
if (!target) throw new Error('usage: node run.mjs <path-to-lib/index.js>')

// ---------------------------------------------------------------- fake server
let generation = 1
let liveSession = null
let initializeCount = 0
let staleHits = 0
let callCount = 0

const TOOL = {
  name: 'echo',
  description: 'Echo text back',
  inputSchema: { type: 'object', properties: { text: { type: 'string' } } },
}

function sse(res, payload, extraHeaders = {}) {
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    ...extraHeaders,
  })
  res.end(`data: ${JSON.stringify(payload)}\n\n`)
}

const server = createServer((req, res) => {
  if (req.method === 'GET') {
    // No server-initiated stream: 405 is explicitly tolerated by the SDK.
    res.writeHead(405).end()
    return
  }
  if (req.method !== 'POST') {
    res.writeHead(405).end()
    return
  }

  let body = ''
  req.on('data', (chunk) => { body += chunk })
  req.on('end', () => {
    let msg
    try { msg = JSON.parse(body) } catch { res.writeHead(400).end('bad json'); return }

    const sentSession = req.headers['mcp-session-id']

    // Handshake: mint a session for the current generation.
    if (msg.method === 'initialize') {
      initializeCount += 1
      liveSession = `sess-${generation}-${initializeCount}`
      return sse(res, {
        jsonrpc: '2.0', id: msg.id,
        result: {
          protocolVersion: '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: { name: 'fake-stateful-server', version: '1.0.0' },
        },
      }, { 'mcp-session-id': liveSession })
    }

    // Anything else must present the live session id.
    if (sentSession !== liveSession) {
      staleHits += 1
      res.writeHead(404, { 'content-type': 'text/plain' }).end('Not Found: Session not found')
      return
    }

    if (msg.method === 'notifications/initialized') {
      res.writeHead(202).end()
      return
    }
    if (msg.method === 'tools/list') {
      return sse(res, { jsonrpc: '2.0', id: msg.id, result: { tools: [TOOL] } })
    }
    if (msg.method === 'tools/call') {
      callCount += 1
      const text = msg.params?.arguments?.text ?? ''
      return sse(res, {
        jsonrpc: '2.0', id: msg.id,
        result: { content: [{ type: 'text', text: `echo:${text}@gen${generation}` }] },
      })
    }
    return sse(res, {
      jsonrpc: '2.0', id: msg.id,
      error: { code: -32601, message: `method not found: ${msg.method}` },
    })
  })
})

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const port = server.address().port

// ------------------------------------------------------------------ fake cordis
const tools = new Map()
const logs = []
const logger = {
  info: (m) => logs.push(['info', String(m)]),
  warn: (m) => logs.push(['warn', String(m)]),
  error: (m) => logs.push(['error', String(m)]),
}

const ctx = {
  logger,
  root: {},
  fiber: { uid: null },
  // Injected services simply do not exist in this harness; Cordis skips them.
  inject: () => {},
  on: () => () => {},
  effect: (fn) => { const d = fn(); return () => d?.() },
  tools: {
    register: (definition) => {
      tools.set(definition.name, definition)
      return () => tools.delete(definition.name)
    },
  },
}

// ------------------------------------------------------------------- the driver
const { apply } = await import(pathToFileURL(target).href)

const config = {
  transport: 'streamable-http',
  serverName: 'faketest',
  url: `http://127.0.0.1:${port}/mcp`,
  headers: {},
  toolCallTimeoutMs: 10_000,
  failOnStartupError: false,
  reconnect: { enabled: true, initialDelayMs: 100, maxDelayMs: 400, maxAttempts: 20 },
}

await apply(ctx, config)

const toolName = 'mcp__faketest__echo'
const tool = tools.get(toolName)
if (!tool) {
  console.log(JSON.stringify({ verdict: 'SETUP_FAILED', registered: [...tools.keys()], logs }, null, 2))
  process.exit(2)
}

const call = async (text) => {
  // Resolve through the live registry each time, the way the Host does: a
  // reconnect disposes the previous generation's definitions and registers new
  // ones, so a captured reference would still point at the dead generation.
  const current = tools.get(toolName)
  if (!current) return { ok: false, error: 'tool not registered' }
  try {
    const out = await current.execute({ text }, { signal: undefined })
    return { ok: true, out }
  } catch (error) {
    return { ok: false, error: String(error?.message ?? error) }
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// 1. healthy call
const before = await call('one')

// 2. simulate the server restarting underneath the Host
generation += 1
liveSession = null // server's session table is empty again

// 3. first call after the restart must fail (the bug's symptom)
const during = await call('two')

// 4. give the supervisor time to notice and rebuild the generation
await sleep(2500)

// 5. the decisive step: does it work again WITHOUT any Host restart?
const after = await call('three')

const verdict = before.ok && !during.ok && after.ok ? 'RECOVERED'
  : !before.ok ? 'SETUP_FAILED'
  : during.ok ? 'INCONCLUSIVE'          // never observed the failure
  : 'STUCK'                             // reproduced the bug: no recovery

console.log(JSON.stringify({
  verdict,
  before,
  during,
  after,
  server: { initializeCount, staleHits, callCount, liveSession },
  reconnectLogs: logs.filter(([, m]) => /reconnect|connection|failed/i.test(m)).map(([l, m]) => `${l}: ${m}`),
}, null, 2))

server.close()
process.exit(verdict === 'RECOVERED' ? 0 : 1)
