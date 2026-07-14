#!/usr/bin/env bash
# Realistic Go CI log noise with an optional injected error block.
#
# Usage:
#   lognoise.sh --lines N --error-at start|middle|end|none|<0-100> [--error-kind compile|panic|test]
#
# --error-at: position of the error block as a fraction of N
#   (start = 2%, middle = 50%, end = last ~30 lines, a bare number = percent).
#   Noise continues after the block, so the error is genuinely buried.
# Always exits 0. The caller decides the job exit code.
set -euo pipefail

LINES=40000
ERROR_AT=none
ERROR_KIND=panic

while [ $# -gt 0 ]; do
  case "$1" in
    --lines) LINES="$2"; shift 2 ;;
    --error-at) ERROR_AT="$2"; shift 2 ;;
    --error-kind) ERROR_KIND="$2"; shift 2 ;;
    *) echo "lognoise.sh: unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$ERROR_AT" in
  start) PCT=2 ;;
  middle) PCT=50 ;;
  end) PCT=100 ;;
  none) PCT=-1 ;;
  *) PCT="$ERROR_AT" ;;
esac

awk -v total="$LINES" -v pct="$PCT" -v kind="$ERROR_KIND" '
function emit_error(    mod) {
  mod = "github.com/glitchy-sheep/ci-events-playground"
  if (kind == "compile") {
    print "# " mod "/internal/registry"
    print "./internal/registry/manifest.go:142:15: undefined: buildManifest"
    print "./internal/registry/manifest.go:158:9: cannot use img (variable of type *Image) as ManifestEntry value in argument to appendEntry"
    print "./internal/registry/push.go:77:21: not enough arguments in call to client.Push"
    print "\thave (context.Context, string)"
    print "\twant (context.Context, string, PushOptions)"
  } else if (kind == "panic") {
    print "panic: runtime error: invalid memory address or nil pointer dereference"
    print "[signal SIGSEGV: segmentation violation code=0x1 addr=0x28 pc=0x6f4a2c]"
    print ""
    print "goroutine 17 [running]:"
    print mod "/internal/registry.(*Client).resolveDigest(0x0, {0xc000123400, 0x2a})"
    print "\t/home/runner/work/ci-events-playground/internal/registry/resolve.go:88 +0x1a4"
    print mod "/internal/registry.(*Client).Publish(0xc0001a2000, {0x9b4d20, 0xc000456780})"
    print "\t/home/runner/work/ci-events-playground/internal/registry/publish.go:141 +0x2ec"
    print mod "/internal/scheduler.(*Queue).drain(0xc000098d80)"
    print "\t/home/runner/work/ci-events-playground/internal/scheduler/queue.go:203 +0x91"
    print mod "/internal/scheduler.(*Queue).Run.func1()"
    print "\t/home/runner/work/ci-events-playground/internal/scheduler/queue.go:117 +0x35"
    print "created by " mod "/internal/scheduler.(*Queue).Run in goroutine 1"
    print "\t/home/runner/work/ci-events-playground/internal/scheduler/queue.go:115 +0x18a"
    print "exit status 2"
  } else {
    print "--- FAIL: TestPublishManifest (0.42s)"
    print "    manifest_test.go:87: got 3 images, want 4"
    print "    manifest_test.go:91: digest mismatch: got sha256:9f86d081884c7d65, want sha256:2c26b46b68ffc68f"
    print "FAIL"
    print "FAIL\t" mod "/internal/registry\t2.31s"
  }
}
BEGIN {
  npkg = split("api auth build cache config controller registry scheduler storage telemetry worker", pkgs, " ")
  ntest = split("TestPublishManifest TestResolveDigest TestCacheEviction TestRetryBackoff TestParseConfig TestSchedulerQueue TestAuthToken TestStorageGC TestWorkerPool TestTelemetryFlush", tests, " ")
  mod = "github.com/glitchy-sheep/ci-events-playground"

  if (pct < 0) errline = -1
  else if (pct >= 100) { errline = total - 30 } else { errline = int(total * pct / 100) }
  if (errline == 0) errline = 1

  dl = int(total / 50); if (dl > 200) dl = 200

  for (i = 1; i <= total; i++) {
    if (i == errline) emit_error()
    if (i <= dl) {
      printf "go: downloading github.com/%s/%s v1.%d.%d\n", pkgs[(i % npkg) + 1], pkgs[((i + 3) % npkg) + 1], i % 20, i % 10
      continue
    }
    r = i % 6
    pkg = pkgs[(i % npkg) + 1]
    t = tests[(i % ntest) + 1]
    if (r == 0)      printf "=== RUN   %s\n", t
    else if (r == 1) printf "=== RUN   %s/case_%d\n", t, i % 17
    else if (r == 2) printf "    --- PASS: %s/case_%d (0.0%ds)\n", t, i % 17, i % 9
    else if (r == 3) printf "--- PASS: %s (0.%02ds)\n", t, i % 90 + 10
    else if (r == 4) printf "ok  \t%s/internal/%s\t%d.%02ds\n", mod, pkg, i % 5, i % 100
    else             printf "go build %s/internal/%s\n", mod, pkg
  }
}
'
