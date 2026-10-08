#!/bin/bash
#
# Pin the OpenTelemetry operator's default Python auto-instrumentation image.
#
# Why: the operator's versions.txt pins autoinstrumentation-python=0.58b0,
# which embeds a broken wrapt (2.5.0 despite "wrapt<2") and an old
# typing_extensions. Injected Python pods crash on boot
# (openinference-instrumentation-langchain TypeError + anyio sentinel
# ImportError). See config/prd/openobserve/collector-values.yaml.
#
# This must be applied AFTER (re)installing/upgrading the operator
# (opentelemetry-operator.yaml), because that manifest resets the deployment
# args. Idempotent.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/../prd/openobserve/collector-values.yaml"
DEPLOYMENT="opentelemetry-operator-controller-manager"
NAMESPACE="opentelemetry-operator-system"
CR_NS="openobserve-collector"
CR_NAME="openobserve-python"

IMAGE="$(python3 -c "import yaml; print(yaml.safe_load(open('$VALUES_FILE').read())['instrumentationPythonImage'])")"

if [ -z "$IMAGE" ]; then
    echo "ERROR: instrumentationPythonImage missing in $VALUES_FILE"
    exit 1
fi

echo "Patching $DEPLOYMENT args with --auto-instrumentation-python-image=$IMAGE ..."

# Fetch, edit manager args (replace or append the python image flag), save to
# a temp file, then apply. Simple two-step instead of nested pipes.
TMP_YAML="$(mktemp /tmp/otel-operator-pin.XXXXXX.yaml)"
trap 'rm -f "$TMP_YAML"' EXIT

kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o yaml \
    | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin)
c = d['spec']['template']['spec']['containers'][0]
image = '$IMAGE'
args = [a for a in (c.get('args') or []) if not a.startswith('--auto-instrumentation-python-image=')]
args.append('--auto-instrumentation-python-image=' + image)
c['args'] = args
d['metadata']['annotations'] = d['metadata'].get('annotations') or {}
d['metadata']['annotations']['kubectl.kubernetes.io/last-applied-configuration'] = json_dump if False else '{}'
import json as _json
sys.stdout.write(yaml.safe_dump(_json.loads(_json.dumps(d))))
" > "$TMP_YAML"

kubectl apply -f "$TMP_YAML"

echo "Waiting for operator rollout..."
kubectl -n "$NAMESPACE" rollout status deployment "$DEPLOYMENT" --timeout=180s

echo "Verification (CR must show the pinned image):"
CR_IMAGE="$(kubectl -n "$CR_NS" get instrumentation "$CR_NAME" -o jsonpath='{.spec.python.image}' 2>/dev/null || true)"
echo "CR image: ${CR_IMAGE:-<none>}"

if [ -z "$CR_IMAGE" ] || [ "$CR_IMAGE" != "$IMAGE" ]; then
    echo "CR image mismatch (${CR_IMAGE:-none}) -> patching CR to $IMAGE"
    kubectl -n "$CR_NS" patch instrumentation "$CR_NAME" \
        --type=json \
        -p='[{"op":"replace","path":"/spec/python/image","value":"'"$IMAGE"'"}]'
    echo "Waiting for operator to reconcile the CR..."
    sleep 3
    CR_IMAGE="$(kubectl -n "$CR_NS" get instrumentation "$CR_NAME" -o jsonpath='{.spec.python.image}')"
    echo "CR image after patch: $CR_IMAGE"
fi

if [ "$CR_IMAGE" = "$IMAGE" ]; then
    echo "Done. Python agent image pinned to $IMAGE"
else
    echo "WARNING: CR image ($CR_IMAGE) still differs from target ($IMAGE)"
    exit 1
fi