# redis

Shared cache and rate-limit state for JWC apps.

```jwc
import redis;

routes "/api" {
    route POST "/login" {
        if (!redis.rate_limit("login:" + request.client_ip(), 5, 60)) {
            throw TooManyRequests("try again in a minute");
        }
        ...
    }
}
```

## Install

```json
{
    "dependencies": {
        "redis": "^0.2.0"
    }
}
```

Then point the runtime at a server and build the driver in:

```bash
export JWC_REDIS_URL=redis://127.0.0.1:6379
```

The `jwc` binary needs `--features redis`. A binary built without it warns
at boot when `JWC_REDIS_URL` is set, rather than pretending.

## The surface

| Call | Returns |
|---|---|
| `redis.get(key)` | `text?` — `null` on a miss |
| `redis.set(key, value, ttl_secs)` | `boolean`; `0` means no expiry |
| `redis.del(key)` | `int` — keys removed |
| `redis.incr(key)` | `bigint` — the new value |
| `redis.expire(key, ttl_secs)` | `boolean` |
| `redis.rate_limit(key, limit, window_secs)` | `boolean` — `true` = allowed |
| `redis.enabled()` | `boolean` |

`rate_limit` is `INCR` plus `EXPIRE` in one Lua script, so the count and its
deadline cannot come apart. The two-call form has a window: if the process
dies between them the counter is left with no TTL, never resets, and that
key is blocked for good. The window is fixed — the TTL is set by the request
that creates the key, not pushed forward by the ones after it.

## Without a server

Every name except `enabled()` **raises**. There is no in-process fallback,
and its absence is deliberate.

The 0.9.x version of this package fell back to the `cache_*` built-ins. Those
are not in the 1.0 vocabulary, and the fallback was the wrong default even
while they were: sharing is the entire point. A per-process rate limiter
behind two replicas admits twice the limit, and nothing in the response says
so — you find out from the bill, or from the abuse. A limiter that reads "no
Redis" as "allowed" is worse still.

So: branch on `redis.enabled()` where the call is genuinely optional, and let
it raise where it is not.

```jwc
if (redis.enabled()) {
    let cached = redis.get(@key);
    if (@cached != null) { return json(@cached); }
}
```

## Why this package has no code

`redis.*` is provided by the compiler (`builtins.md` §8), over the Rust
driver in `jwc-lang`'s `src/redis_engine.rs`. This repository is the
manifest that makes `import redis;` resolve — a package import is what
brings the namespace into the declaration space (`names.md` §6.2.3), and
without a `dependencies` entry the import is `E0201: unknown import`.

It cannot be written in JWC. RESP is a binary protocol over TCP, JWC has no
socket, and `ecosystem.md` puts a sub-millisecond binary-wire driver in the
**core tier** for exactly that reason. A pure-JWC layer on top could only
rename what the compiler already exposes.

The name is `redis`, not `jwc-redis`, because a hyphen is not an identifier:
`import jwc-redis;` does not parse, and `jwc publish` refuses a hyphenated
name for that reason (`packages.md` §1). This is a deliberate departure from
the `jwc-*` convention in `ecosystem.md` §3.2.

## Tests

The surface is the compiler's, so its tests live with it:
`jwc-lang/tests/integration_redis.rs`, which runs against a real server via
`JWC_TEST_REDIS_URL` and covers both the driver and the language surface —
including that `rate_limit` actually limits, and that a missing server
raises instead of admitting the request.

## License

MIT — see [LICENSE](./LICENSE).
