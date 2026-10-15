# dsh-mcp-session-recovery

An out-of-tree patch that makes `@deepseek-ai/dsh-mcp-client` recover when a
**stateful Streamable HTTP MCP server stops recognising the session** underneath
a running DSH — whether because the server restarted, or because an idle timeout
pruned the session while everything stayed up.

Without it, every tool from that server fails permanently — restarting DSH is
the only fix. With it, the client notices the dead session and rebuilds the
connection on its own within a second or two.

> **中文摘要**：当带会话状态的 MCP 服务端（Streamable HTTP）不再认识 DSH 手里那个
> `mcp-session-id` 时（服务端重启，**或会话因空闲超时被清理**），该服务端的
> **所有工具调用会永久失败**，只能靠重启 DSH 恢复。本仓库是一个仓外补丁，让客户端
> 自己发现会话失效并重连，1~2 秒内自愈。
>
> ⚠️ 注意一个常见误解：**并不需要服务端重启**。实测有服务端把会话持久化到磁盘、重启
> 完全无损，但设有 12 小时空闲超时 —— 只要 DSH 挂着超过 12 小时没有 MCP 调用，
> 同样会中招。详见下文。
>
> 上游已知（见下方链接），官方暂不接受外部 PR，故以此形式发布。

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
the server no longer recognises our mcp-session-id
  → client still holds the old id
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

### What invalidates a session depends on the server

Both variants produce the same 404 and the same permanent failure, so the patch
is the same — but the trigger is worth knowing, because it determines how often
you hit this:

| server behaviour | trigger | notes |
|---|---|---|
| sessions held in memory | process restart | the classic case |
| **sessions persisted and restored** | **idle timeout** | a restart is harmless; long idleness is not |

The second variant is the one verified end-to-end here. Nowledge Mem's backend
logs

```
MCP session idle timeout and restart restore store configured
  seconds=43200                                    # 12 hours
  store_path=…/co.nowledge.mem.desktop/mcp-sessions.json
```

and indeed a session survives repeated server restarts (confirmed: an MCP session
created before two consecutive app restarts still answered `200` afterwards),
while one aged past 43200s is pruned and rejected with
`404 Not Found: Session not found`.

**Practical consequence:** leaving DSH running for more than 12 hours without an
MCP call is enough to break the connection — no crash, no restart, nothing
visible. That is far easier to hit than a server crash, and it is exactly this
shape of failure that is invisible without the patch.

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

**Verify the real thing** — with DSH running and its MCP tools working,
invalidate the session, then call a tool:

- first call fails with `404 Session not found` (expected — that is the trigger)
- **within a second or two, calls succeed again with no DSH restart**

Before this patch the second step never happened.

### Result from the end-to-end run this patch was built on

Against a real DSH host (0.2.0-rc.2) and a real Nowledge Mem backend, stopping
the session by aging it past the server's 43200s idle timeout:

| step | observed |
|---|---|
| first tool call | `Error POSTing to endpoint: Not Found: Session not found` |
| server session store, ~8s later | a **new** `dsh-mcp-client` session id appears |
| second tool call | succeeds |

No DSH restart in between. The server-side session store is the useful witness
here: a new entry appearing on its own is proof that a fresh `initialize`
handshake happened, which only the reconnected generation performs.

To invalidate a session the same way for a persisted-session server, stop the
server, age the entry in its session store, and start it again — mutating a live
store is pointless, because the running server holds the session in memory.

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
