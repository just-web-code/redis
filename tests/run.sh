#!/usr/bin/env bash
#
# Conformance runner for jwc-redis.
#
# `ecosystem.md` §3.7 asks packages to ship `tests/case_*.jwc` +
# `.stdout.txt` and says `jwc test` should run them in the package root.
# As of jwc 0.8.x `jwc test` only lints (validation + dead-code warnings)
# — there is no conformance runner for packages yet. The case files are
# in the shape the spec describes so they work unchanged when one lands;
# until then, this script is the runner.
#
# A package can't be executed directly (`type: "pkg"`), so each case is
# copied into `tests/harness/` — a minimal app project that depends on
# the package by path — and run from there.
#
# Every case except case_availability runs TWICE, against the same
# expected output: once with JWC_REDIS_URL set and once without. That is
# the package's central claim — the in-process fallback is observably
# identical to the Redis path — so it is what gets asserted, rather than
# only ever testing the configured path.
#
# Usage:
#   tests/run.sh                       # fallback only (no Redis needed)
#   JWC_TEST_REDIS_URL=redis://127.0.0.1:6379 tests/run.sh
#
#   JWC=/path/to/jwc tests/run.sh      # override the binary under test
#
# Exit status is non-zero if any case fails.

set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
HARNESS="$ROOT/tests/harness"
JWC="${JWC:-jwc}"

if ! command -v "$JWC" >/dev/null 2>&1 && [ ! -x "$JWC" ]; then
    echo "error: '$JWC' not found. Install jwc, or set JWC=/path/to/jwc." >&2
    echo "       The binary must be built with --features redis for the" >&2
    echo "       Redis pass; the fallback pass works with any build." >&2
    exit 2
fi

pass=0
fail=0

# run_case <case-file> <expected-file> <label> [redis-url]
run_case() {
    local case_file="$1" expected="$2" label="$3" redis_url="${4:-}"

    cp "$case_file" "$HARNESS/main.jwc"

    local actual
    if [ -n "$redis_url" ]; then
        actual="$(JWC_REDIS_URL="$redis_url" "$JWC" run "$HARNESS" 2>&1)"
    else
        # Explicitly cleared, not merely absent — the developer's shell may
        # already export it, which would silently turn the fallback pass
        # into a second Redis pass.
        actual="$(env -u JWC_REDIS_URL "$JWC" run "$HARNESS" 2>&1)"
    fi

    if [ "$actual" == "$(cat "$expected")" ]; then
        echo "  ok    $label"
        pass=$((pass + 1))
    else
        echo "  FAIL  $label"
        diff <(echo "$actual") "$expected" | sed 's/^/        /'
        fail=$((fail + 1))
    fi
}

echo "jwc-redis conformance ($JWC)"

for case_file in "$ROOT"/tests/case_*.jwc; do
    name="$(basename "$case_file" .jwc)"
    expected="$ROOT/tests/$name.stdout.txt"

    if [ ! -f "$expected" ]; then
        echo "  FAIL  $name (no $name.stdout.txt)"
        fail=$((fail + 1))
        continue
    fi

    # case_availability is the one case that MUST differ between modes —
    # it reports whether Redis is actually connected — so it carries a
    # separate expectation per mode instead of one shared file.
    if [ "$name" == "case_availability" ]; then
        run_case "$case_file" "$ROOT/tests/$name.fallback.stdout.txt" "$name [fallback]"
        if [ -n "${JWC_TEST_REDIS_URL:-}" ]; then
            run_case "$case_file" "$expected" "$name [redis]" "$JWC_TEST_REDIS_URL"
        fi
        continue
    fi

    run_case "$case_file" "$expected" "$name [fallback]"
    if [ -n "${JWC_TEST_REDIS_URL:-}" ]; then
        run_case "$case_file" "$expected" "$name [redis]" "$JWC_TEST_REDIS_URL"
    fi
done

rm -f "$HARNESS/main.jwc"

if [ -z "${JWC_TEST_REDIS_URL:-}" ]; then
    echo
    echo "note: JWC_TEST_REDIS_URL is unset — only the in-process fallback"
    echo "      was exercised. Nothing here touched a real Redis server."
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
