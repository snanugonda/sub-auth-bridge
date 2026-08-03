# Idea: lightweight local service registry + gateway (deferred)

**Status:** deliberately out of scope for this repo. Take this to a new
project, in a new folder, in a fresh session. Not a task for
`open-ai-sub-auth` — noted here on 2026-08-03 so the idea isn't lost.

## The problem

Right now, if a consuming app wants to talk to `packages/service`, it
needs to know the actual host:port it's running on. `open-ai-sub-auth`
solves this at small scale with a dynamic-port-plus-discovery-file
approach (`.repo-state/service-port`, written by `repo.sh start`, read by
`status`/`chat`/etc.) — good enough for one service, one machine, driven
through one script.

The bigger version of this problem: **a stable URL that consumers always
use, regardless of where/how the actual backend is deployed, with the
backend registering its real location on every deploy.** That's the
pattern cloud infra tools solve — Consul + Envoy, Kubernetes Service +
Endpoints, Netflix Eureka + Zuul, AWS Cloud Map. Worth building a genuinely
lightweight version of that pattern for personal/local-scale use, instead
of reaching for one of those heavyweight tools.

## Shape of a lightweight version

1. **A tiny gateway process** bound to one fixed, dedicated port that never
   changes (e.g. `18787`) — the one URL every consumer ever talks to:
   `http://localhost:18787`. Nothing else has reason to bind that exact
   port, so it doesn't have the collision problem a "real" backend service
   does.
2. **Backends self-register on startup** — on boot, a service does
   `POST http://localhost:18787/register {port: <its own port>}`.
   Matches the actual cloud pattern: the service announces itself, nothing
   external has to track it.
3. **The gateway proxies everything else through** to whatever's currently
   registered — plain HTTP passthrough (Node's built-in `http` is enough
   to hand-roll this, no dependency needed for a v1).
4. If nothing's registered (not started yet, crashed), the gateway returns
   a clear `502` instead of connection-refused.

## Open questions for the new project

- Ordering dependency: backend might start before the gateway is up.
  Needs retry/backoff on the registration call rather than a hard
  requirement that the gateway starts first.
- Multiple backends / multiple environments registering under the same
  name — round-robin? Last-write-wins? Needs a real answer once there's
  more than one deploy target.
- Health-checking registered backends and de-registering on failure,
  vs. just letting registration go stale and expire after a TTL.
- Auth on the `/register` endpoint itself — right now nothing stops any
  local process from registering itself as "the" backend.
- Whether this ever needs to work across machines (not just same-host),
  which changes the calculus toward real service discovery (mDNS/DNS-SD)
  instead of a single local gateway process.
