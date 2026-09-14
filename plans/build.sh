set -euo pipefail

CNAME="ossm-build-$$"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Phase 1: Pre-fetch Go modules with network (like Cachi2 in Konflux)
run_in_podman "go mod download"

# Skip TestAttributeGen: downloads a WASM artifact at runtime (OSSM-1931).
# Konflux does the same in proxy-test.Containerfile.
echo "DEBUG: === sed skip TestAttributeGen START ==="
echo "DEBUG: file exists check:"
podman exec "${CNAME}" ls -la test/envoye2e/stats_plugin/stats_test.go
echo "DEBUG: line BEFORE sed:"
podman exec "${CNAME}" grep -n 'func TestAttributeGen' test/envoye2e/stats_plugin/stats_test.go || echo "DEBUG: pattern NOT FOUND before sed"
echo "DEBUG: running sed..."
run_in_podman "sed -i '/func TestAttributeGen/a \\\\tt.Skip(\"OSSM-1931: wasm download not available in hermetic build\")' test/envoye2e/stats_plugin/stats_test.go"
echo "DEBUG: sed exit code from run_in_podman: $?"
echo "DEBUG: line AFTER sed:"
podman exec "${CNAME}" grep -n 'TestAttributeGen' test/envoye2e/stats_plugin/stats_test.go || echo "DEBUG: pattern NOT FOUND after sed"
echo "DEBUG: showing lines 378-385 after sed:"
podman exec "${CNAME}" sed -n '378,385p' test/envoye2e/stats_plugin/stats_test.go
echo "DEBUG: === sed skip TestAttributeGen END ==="

# Phase 2: Disconnect network (like unshare --net in Konflux)
for net in $(podman inspect "${CNAME}" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'); do
  podman network disconnect --force "${net}" "${CNAME}"
done

if podman exec "${CNAME}" curl -s --connect-timeout 3 https://github.com > /dev/null 2>&1; then
  echo "ERROR: container still has network access after disconnect" >&2
  exit 1
fi
echo "Network disconnected: container is now isolated"

# Phase 3: Build and test without network
run_in_podman "GOPROXY=off bash ossm/ci/pre-submit.sh"

# Phase 4: Produce release artifact (bazel cache is warm, no network needed)
run_in_podman "GOPROXY=off SKIP_GCS_UPLOAD=true bash ossm/ci/post-submit.sh"
collect_artifact
