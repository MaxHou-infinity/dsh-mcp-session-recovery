# dsh-mcp-session-recovery

An out-of-tree patch that makes `@deepseek-ai/dsh-mcp-client` recover when a
**stateful Streamable HTTP MCP server restarts** underneath a running DSH.

Without it, every tool from that server fails permanently — restarting DSH is
the only fix. With it, the client notices the dead session and rebuilds the
connection on its own within a second or two.

> **中文摘要**：当带会话状态的 MCP 服务端（Streamable HTTP）在 DSH 运行期间重启，
> 它内存里的会话会清空，而 DSH 仍握着重启前的 `mcp-session-id`。此后该服务端的
> **所有工具调用永久失败**，只能靠重启 DSH 恢复。本仓库是一个仓外补丁，让客户端
> 自己发现会话失效并重连，1~2 秒内自愈。上游已知（见下方链接），官方暂不接受
> 外部 PR，故以此形式发布。

## The bug

`dsh-mcp-client` has a complete reconnect supervisor — bounded exponential
backoff, outage-scoped attempt budget, tool re-sync on reconnect. It is wired to
exactly one signal:

```js
generation.onclose = () => { ... if (attemptSettled) generationDown(generation) }
```

Session loss never produces a close. The MCP SDK reports it as a **request-level
error**: the transport throws `SdkHttpError` with `status: 404` and calls
`onerror` only, leaving `onclose` silent. The dead `mcp-session-id` is retained,
because the SDK rewrites it only on a *successful handshake* — and handshakes
happen only inside `connectGeneration()`, which only runs at startup or after a
reconnect.

So:

```
MCP server restarts → server-side session table cleared
  → client still holds the old mcp-session-id
  → next tool call → HTTP 404
  → SDK fires onerror (NOT onclose)
  → dsh-mcp-client subscribes to no onerror → signal dropped
  → no reconnect, no new handshake, session id never replaced
  ⇒ permanent failure for the life of the Host process
```

Starting a new conversation does **not** help: the MCP bridge is process-scoped,
one plugin instance per Host, shared by every session. Only a Host restart does.

A telling asymmetry: a *failed connect attempt* **does** reach the supervisor
(`settleFailedGeneration → generationDown → scheduleReconnect`), so a server that
is down at startup keeps being retried. Only a session invalidated on an
**already-established** connection falls through the gap.

## Affected versions

`lib/index.js` is byte-identical across these, so the same patch applies to both:

| version | `lib/index.js` sha256 | affected |
|---|---|---|
| `@deepseek-ai/dsh-mcp-client@0.2.0-rc.2` | `758d8fc4…f5dd` | yes |
| `@deepseek-ai/dsh-mcp-client@0.2.1-alpha.4` | `758d8fc4…f5dd` | yes |

`grep -c onerror lib/index.js` → `0` on both.

## Install

```bash
git clone https://github.com/MaxHou-infinity/dsh-mcp-session-recovery
cd dsh-mcp-session-recovery
./apply.sh
```

The script finds the installed plugin, refuses to proceed if the file does not
match the revision the patch was cut against (unless you confirm), backs the
original up to `~/.dsh/backups/dsh-mcp-client-pre-onerror-fix/`, applies the
patch in a scratch repo so a partial application cannot land, and syntax-checks
the result. It is idempotent.

Then restart DSH:

```bash
kill $(lsof -ti tcp:3080 -sTCP:LISTEN); dsh web
```

## Verify

**Reproduce the bug and the fix offline**, with no DSH restart and no real MCP
server — a fake stateful server invalidates its session mid-flight:

```bash
node test/run.mjs /path/to/.../dsh-mcp-client/lib/index.js
```

It prints `RECOVERED` (patched) or `STUCK` (unpatched). Run it against the
backup to see the control.

**Verify the real thing** — with DSH running and its MCP tools working, restart
the MCP server, then call a tool:

- first call fails with `404 Session not found` (expected — that is the trigger)
- **within a second or two, calls succeed again with no DSH restart**

Before this patch the second step never happened.

## What the patch changes

Two additions, ~35 lines, no behaviour change on any other path:

1. `isSessionLostError(error)` — a deliberately narrow predicate: `status === 404`
   (which the transport only produces for a request that carried a session id),
   plus `400` whose body names the session as missing/invalid/unknown/expired.
   Anything else surfaces unchanged, so ordinary request errors never recycle a
   healthy generation.
2. `generation.onerror = (error) => { if (attemptSettled && isSessionLostError(error)) generationDown(generation) }`
   — funnels session loss into the same disconnect path `onclose` already uses.
   Everything downstream (backoff, fresh handshake, tool re-sync) is the existing,
   unmodified machinery.

## Uninstall

```bash
./revert.sh          # restores from the newest backup
```

Reinstalling or upgrading DSH also reverts it — this patch lives inside the
globally installed `@deepseek-ai/dsh` package and is **not** preserved across a
DSH upgrade. Re-run `./apply.sh` after upgrading if the bug is still present
(check with `grep -c onerror lib/index.js`).

## Why this is not an upstream PR

The official repository does not accept them. From
[CONTRIBUTING.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/CONTRIBUTING.md):

> We are sorry that we cannot accept external pull requests at the moment.

and the repo's PR API returns `404` — pull requests are disabled, as are issues.
The policy instead points contributors at Discussions and at the ecosystem:

> We do not believe that packages in the official repository are inherently more
> important than packages created by the community.

So this is published as an out-of-tree patch rather than a fork. The upstream
report lives at
[deepseek-ai/deepseek-harness#9740](https://github.com/deepseek-ai/deepseek-harness/discussions/9740);
if the maintainers adopt a fix, this repository retires.

## License

MIT. The patch modifies MIT-licensed code, Copyright (c) 2026 DeepSeek; the
patch file and scripts here are provided under the same terms.
