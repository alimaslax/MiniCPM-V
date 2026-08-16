#!/usr/bin/env bash
set -euo pipefail

export HF_HOME="${HF_HOME:-/data/.cache/huggingface}"
export MODEL_DIR="${MODEL_DIR:-/data/models/minicpm-o-4_5}"
export PORT="${PORT:-7860}"
export TAILSCALE_STATE_DIR="${TAILSCALE_STATE_DIR:-/data/tailscale}"
mkdir -p "$HF_HOME" "$MODEL_DIR" /app/demo/data /app/demo/tmp

nginx -c /app/runtime/verda/nginx.conf -g 'daemon off;' &
NGINX_PID=$!

start_tailscale() {
  [[ "${TAILSCALE_ENABLE:-0}" == "1" ]] || return 0
  echo "[minicpm-tailscale] waiting for daemon"
  until [[ -S /tmp/tailscaled.sock ]]; do sleep 1; done
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    tailscale --socket=/tmp/tailscaled.sock up --auth-key="$TAILSCALE_AUTHKEY" --hostname=minicpm-o45-live --accept-dns=false
  else
    echo "[minicpm-tailscale] login link follows; approve it in your Tailscale account"
    tailscale --socket=/tmp/tailscaled.sock up --hostname=minicpm-o45-live --accept-dns=false
  fi
  until TAILSCALE_IP="$(tailscale --socket=/tmp/tailscaled.sock ip -4 2>/dev/null)"; [[ -n "$TAILSCALE_IP" ]]; do sleep 2; done
  echo "[minicpm-tailscale] connected at ${TAILSCALE_IP}; HTTPS is served at the MagicDNS hostname"
  # Tailscale terminates TLS here. A secure browser origin is required for the
  # demo's microphone and camera APIs; do not expose the UI as plain HTTP.
  tailscale --socket=/tmp/tailscaled.sock serve --https=443 http://127.0.0.1:7860
}

if [[ "${TAILSCALE_ENABLE:-0}" == "1" ]]; then
  mkdir -p "$TAILSCALE_STATE_DIR"
  tailscaled --state="$TAILSCALE_STATE_DIR/tailscaled.state" --socket=/tmp/tailscaled.sock --tun=userspace-networking &
  TAILSCALED_PID=$!
  start_tailscale &
  TAILSCALE_CONFIG_PID=$!
fi

cleanup() {
  for pid in "${GATEWAY_PID:-}" "${WORKER_PID:-}" "${BACKEND_PID:-}" "${TAILSCALED_PID:-}" "${TAILSCALE_CONFIG_PID:-}" "$NGINX_PID"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  wait || true
}
trap cleanup TERM INT EXIT

# Nginx is live before the first model download so Verda's liveness probe does
# not kill the continuous replica while the persistent cache is populated.
python3 /app/runtime/verda/bootstrap_model.py

cd /app/demo
[[ -f config.json ]] || cp config.example.json config.json
python3 -m py_backend.server --host 127.0.0.1 --port 22500 --gpu-id 0 --model-path "$MODEL_DIR" &
BACKEND_PID=$!
for _ in $(seq 1 300); do
  kill -0 "$BACKEND_PID" 2>/dev/null || { echo "[minicpm] backend exited during startup" >&2; exit 1; }
  curl -fsS http://127.0.0.1:22500/health >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1:22500/health >/dev/null || { echo "[minicpm] backend did not become ready" >&2; exit 1; }

python3 worker.py --host 127.0.0.1 --port 22400 --gpu-id 0 --backend-server-url http://127.0.0.1:22500 &
WORKER_PID=$!
python3 gateway.py --host 127.0.0.1 --port 8006 --internal-port 8007 --http &
GATEWAY_PID=$!

# The official gateway discovers workers through its internal registry.
for _ in $(seq 1 60); do
  kill -0 "$GATEWAY_PID" 2>/dev/null || { echo "[minicpm] gateway exited during startup" >&2; exit 1; }
  if curl -fsS -X PUT -H 'content-type: application/json' \
      --data '{"endpoint":"127.0.0.1:22400","gpu_group":"gpu-0"}' \
      http://127.0.0.1:8007/internal/workers/minicpm-o45-worker >/dev/null; then
    echo "[minicpm] worker registered with gateway"
    break
  fi
  sleep 1
done

wait -n "$BACKEND_PID" "$WORKER_PID" "$GATEWAY_PID" "$NGINX_PID"
STATUS=$?
trap - EXIT
cleanup
exit "$STATUS"
