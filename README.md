# jwc-redis

Shared cache and rate-limit state for JWC apps — with an in-process
fallback when Redis isn't configured.

JWC's built-in `cache_*` family is fast and needs no infrastructure, and
it is **per process**. Run two replicas and each keeps its own copy: a
rate limit of 100/min becomes 200/min across two pods, and a value
invalidated on one stays stale on the other.

This package gives you one API that uses Redis when it's there and the
in-process cache when it isn't. The same app code runs on a laptop with
no Redis and on a 12-pod deployment with one.

## Install

```json
{
    "dependencies": {
        "jwc-redis": "^0.1.0"
    }
}
```

Then point the runtime at a server:

```bash
export JWC_REDIS_URL=redis://127.0.0.1:6379
```

Leave `JWC_REDIS_URL` unset and everything still works — just per
process. See [Fallback](#fallback) for what that costs you.

**Requires a `jwc` built with `--features redis`.** Without it the
`redis_*` built-ins this package wraps raise at call time, and the binary
prints a warning at boot if `JWC_REDIS_URL` is set.

## Quick start

```jwc
import redis;

route GET "/profile/{id}" {
    let id = path_param("id");

    let cached = redis.get_json("profile:" + id);
    if (cached != null) {
        return json(cached);
    }

    let profile = load_profile(id);
    redis.set_json("profile:" + id, profile, 300);
    return json(profile);
}
```

Rate limiting, which is the reason most apps reach for Redis:

```jwc
import redis;

middleware RateLimit {
    if (!redis.rate_limit("rl:" + client_ip(), 100, 60)) {
        return status_code(429, { error: "rate limit exceeded" });
    }
    return null;
}
```

## API

### Key/value

| Function | Returns | Notes |
|---|---|---|
| `redis.get(key)` | string / `null` | `null` for a missing key — never `""` |
| `redis.set(key, value, ttl_secs)` | bool | `ttl_secs` of `0` means no expiry |
| `redis.del(key)` | int | Keys removed: `1` or `0` |
| `redis.exists(key)` | bool | |
| `redis.incr(key)` | int | New value; creates the key at `1` |
| `redis.expire(key, ttl_secs)` | bool | `false` when the key doesn't exist |

### JSON

| Function | Returns | Notes |
|---|---|---|
| `redis.get_json(key)` | value / `null` | `get` + `json_parse` |
| `redis.set_json(key, value, ttl_secs)` | bool | `json_stringify` + `set` |

There is no `remember(key, ttl, loader)`. JWC has no first-class
functions, so a loader callback can't be passed — write cache-aside
inline, as in [Quick start](#quick-start).

### Rate limiting

| Function | Returns | Notes |
|---|---|---|
| `redis.rate_limit(key, limit, window_secs)` | bool | `true` = allowed |

Fixed window. On Redis it is a single Lua script, so `INCR` and `EXPIRE`
are atomic — the two-call version has a window where a crash between them
leaves a counter with no TTL that never resets, blocking that key
forever.

### Raw

| Function | Returns | Notes |
|---|---|---|
| `redis.available()` | bool | Is this process really talking to Redis? |
| `redis.ping()` | bool | Round-trip. Never raises |
| `redis.eval(script, keys, args)` | string / `null` | Lua; `keys` / `args` are arrays |

`eval` is the one entry point with no fallback — a Lua script can't be
emulated in-process, and returning `null` would be indistinguishable from
a nil reply by a script that really ran. Without Redis it raises
`RedisError`.

## Fallback

Without `JWC_REDIS_URL`, every function above except `eval` runs against
the in-process `cache_*` built-ins. The package's conformance suite
asserts the two modes produce **identical output**, so this isn't a
degraded API — it's the same API against a smaller scope.

What the fallback does not give you:

- **Sharing.** State is per process. With N replicas a limit of 100/min
  is enforced as 100/min *each*.
- **Atomic `incr`.** The fallback reads then writes, so two concurrent
  requests in one process can both read 3 and both write 4. Redis `INCR`
  has no such gap.

When correctness depends on shared state, branch on it:

```jwc
if (!redis.available()) {
    return internal_error({ error: "shared cache unavailable" });
}
```

## Environment

| Var | Default | Description |
|---|---|---|
| `JWC_REDIS_URL` | _(unset)_ | Connection string; unset selects the fallback. `rediss://` for TLS |
| `JWC_REDIS_POOL_SIZE` | `64` | Max pooled connections |
| `JWC_REDIS_RETRY_MAX_ATTEMPTS` | `3` | Transient-error retry ceiling |
| `JWC_REDIS_RETRY_BACKOFF_MS` | `100` | Base retry backoff; doubles per attempt |

All four are read by the runtime, not by this package. Full reference:
[jwc-lang deployment/redis](https://github.com/just-web-code/jwc-lang/blob/main/docs/docs/deployment/redis.md).

## Errors

Failures raise `RedisError`, with subtypes for the cases worth branching
on: `RedisError.ConnectionFailure`, `RedisError.TimedOut`,
`RedisError.NoScript`, `RedisError.LoadingError`. Catching the parent
catches all of them.

```jwc
try {
    redis.set("k", "v", 60);
} catch (e: RedisError) {
    // `try` takes a single catch clause — branch on e.type for specifics.
    print("cache write failed: " + e.type);
}
```

Transient failures are retried by the runtime with exponential backoff
before they ever reach you. Permanent ones (a Lua syntax error,
`WRONGTYPE`) are not.

## Compatibility

| | |
|---|---|
| Requires | `jwc` ≥ 0.8.9, built with `--features redis` |
| Redis | 6.0+ (uses `SET ... EX`, `EVAL`) |
| Native AOT | Supported — `jwc build --native` emits the same behaviour |
| Values | UTF-8 strings. Store binary as base64 |

## Repository layout

```
.
├── pkg/                    ← the published package
│   ├── jwc-redis.jwcproj
│   └── main.jwc
└── tests/                  ← outside pkg/, deliberately
    ├── case_*.jwc + .stdout.txt
    ├── harness/            ← app project depending on ../../pkg
    └── run.sh
```

`ecosystem.md` §3.7 puts conformance cases at `tests/case_*.jwc` *inside*
the package. They can't live there today: each case defines its own
`main()` so it can be run, and source discovery merges every `.jwc` under
the package root into whatever depends on it — so a consumer, and `jwc
publish` itself, fail with `E015: Duplicate function name: main`.
Keeping `tests/` a sibling of `pkg/` sidesteps it, at the cost of the
tarball not shipping the cases.

[jwc-lang#58](https://github.com/just-web-code/jwc-lang/pull/58) fixes
the discovery rule; once it ships, `tests/` can move under `pkg/` and
this note goes away.

## Publishing

```bash
cd pkg
jwc publish
```

From `pkg/`, not the repo root — the manifest is what defines the package
root, and running it a level up would try to publish the tests too.

## Tests

```bash
tests/run.sh                                            # fallback only
JWC_TEST_REDIS_URL=redis://127.0.0.1:6379 tests/run.sh  # both modes
```

Each case runs in both modes against the same expected file — that shared
expectation is what pins the fallback-is-transparent claim.
`case_availability` is the exception, with one expectation per mode.

`jwc test` currently only lints; it does not run package conformance
cases, which is why `tests/run.sh` exists.

## License

MIT — see [LICENSE](LICENSE).
