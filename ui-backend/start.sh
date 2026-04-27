#!/bin/sh
set -eu

STATE_DIR="${UI_STATE_DIR:-/run/smoothiso-ui}"
REQUEST_DIR="${UI_REQUEST_DIR:-${STATE_DIR}/requests}"
RESPONSE_DIR="${UI_RESPONSE_DIR:-${STATE_DIR}/responses}"
FRONTEND_DIR="${UI_FRONTEND_DIR:-${SMOOTHGUI_FRONTEND_DIR:-/smoothiso-ui}}"
PORT="${SMOOTHGUI_FRONTEND_PORT:-8080}"
BIND_ADDR="${SMOOTHGUI_FRONTEND_BIND:-0.0.0.0}"
LOG_FILE="${STATE_DIR}/smoothiso-frontend.log"
HTTPD_LOG="${STATE_DIR}/smoothiso-httpd.log"
PYTHON_LOG="${STATE_DIR}/smoothiso-python.log"
NC_LOG="${STATE_DIR}/smoothiso-nc.log"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
CGI_DIR="${FRONTEND_DIR}/cgi-bin"

mkdir -p "$STATE_DIR" "$REQUEST_DIR" "$RESPONSE_DIR" "$CGI_DIR" "/cgi-bin"
: > "$LOG_FILE"
: > "$HTTPD_LOG" 2>/dev/null || true
: > "$PYTHON_LOG" 2>/dev/null || true
: > "$NC_LOG" 2>/dev/null || true

log() {
    printf '%s [start.sh] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo -)" "$*" >> "$LOG_FILE"
}
cp "${SCRIPT_DIR}/request" "$CGI_DIR/request" 2>/dev/null || true
cp "${SCRIPT_DIR}/respond" "$CGI_DIR/respond" 2>/dev/null || true
ln -sf "${CGI_DIR}/request" "/cgi-bin/request" 2>/dev/null || true
ln -sf "${CGI_DIR}/respond" "/cgi-bin/respond" 2>/dev/null || true
chmod +x "$CGI_DIR/request" "$CGI_DIR/respond" "/cgi-bin/request" "/cgi-bin/respond" 2>/dev/null || true

start_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        log "python3 not present; skipping python backend"
        return 1
    fi
    cat > /tmp/smoothiso-ui-bridge.py << 'PY'
import os
import json
import urllib.parse
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler


request_dir = os.environ.get("UI_REQUEST_DIR", "/run/smoothiso-ui/requests")
response_dir = os.environ.get("UI_RESPONSE_DIR", "/run/smoothiso-ui/responses")
bind_addr = os.environ.get("SMOOTHGUI_FRONTEND_BIND", "0.0.0.0")
bind_port = int(os.environ.get("SMOOTHGUI_FRONTEND_PORT", "8080"))
frontend_dir = os.environ.get("UI_FRONTEND_DIR", "/smoothiso-ui")


class InstallerBridgeHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        kwargs["directory"] = frontend_dir
        super().__init__(*args, **kwargs)

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _next_request(self):
        try:
            files = sorted(os.listdir(request_dir))
        except FileNotFoundError:
            return None
        for name in files:
            if name.endswith(".json"):
                path = os.path.join(request_dir, name)
                if not os.path.isfile(path):
                    continue
                with open(path, "r", encoding="utf-8") as fh:
                    try:
                        return json.load(fh)
                    except json.JSONDecodeError:
                        return {"id": "invalid", "kind": "notice", "title": "Invalid request", "message": "Installer request payload is malformed."}
        return None

    def _consume_query_id(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        ids = query.get("id")
        if not ids:
            return None
        return ids[0]

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/cgi-bin/request":
            request = self._next_request()
            if request is None:
                self._json(None)
                return
            self._json(request)
            return
        super().do_GET()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/cgi-bin/respond":
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length).decode("utf-8", errors="ignore") if length > 0 else ""
            req_id = self._consume_query_id()
            if not req_id:
                self._json({"error": "Missing id"}, status=400)
                return
            os.makedirs(response_dir, exist_ok=True)
            with open(os.path.join(response_dir, req_id + ".json"), "w", encoding="utf-8") as fh:
                fh.write(body)
            self._json({"ok": True, "id": req_id})
            return
        self.send_error(405, "Method Not Allowed")


def main():
    os.makedirs(request_dir, exist_ok=True)
    os.makedirs(response_dir, exist_ok=True)
    with ThreadingHTTPServer((bind_addr, bind_port), InstallerBridgeHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
PY
    log "starting python3 backend on ${BIND_ADDR}:${PORT}"
    python3 /tmp/smoothiso-ui-bridge.py >>"$PYTHON_LOG" 2>&1 &
    local py_pid=$!
    sleep 1
    if ! kill -0 "$py_pid" 2>/dev/null; then
        log "python3 backend died during startup; see ${PYTHON_LOG}"
        return 1
    fi
    log "python3 backend running (pid=$py_pid)"
    return 0
}

start_busybox_httpd() {
    if ! command -v busybox >/dev/null 2>&1; then
        log "busybox not on PATH; skipping busybox httpd backend"
        return 1
    fi
    if ! busybox --list 2>/dev/null | grep -q '^httpd$'; then
        log "busybox build lacks httpd applet; skipping"
        return 1
    fi

    # busybox httpd auto-runs executables under cgi-bin/ in the docroot;
    # `-c` expects a config FILE, not a directory, so we omit it here.
    # Run in background and verify the listener stays up before returning.
    log "starting busybox httpd on ${BIND_ADDR}:${PORT} docroot=${FRONTEND_DIR}"
    busybox httpd \
        -f \
        -vv \
        -p "${BIND_ADDR}:${PORT}" \
        -h "$FRONTEND_DIR" \
        >>"$HTTPD_LOG" 2>&1 &
    local httpd_pid=$!
    sleep 1
    if ! kill -0 "$httpd_pid" 2>/dev/null; then
        log "busybox httpd died during startup; see ${HTTPD_LOG}"
        return 1
    fi
    log "busybox httpd running (pid=$httpd_pid)"
    return 0
}

start_busybox_nc() {
    command -v busybox >/dev/null 2>&1 || return 1
    if ! busybox --list 2>/dev/null | grep -q '^nc$'; then
        return 1
    fi

    bridge="/tmp/smoothiso-ui-nc-bridge.sh"
    cat > "$bridge" << 'SH'
#!/bin/sh
set -eu

STATE_DIR="${UI_STATE_DIR:-/run/smoothiso-ui}"
REQUEST_DIR="${UI_REQUEST_DIR:-${STATE_DIR}/requests}"
RESPONSE_DIR="${UI_RESPONSE_DIR:-${STATE_DIR}/responses}"
FRONTEND_DIR="${UI_FRONTEND_DIR:-/smoothiso-ui}"
LOG_FILE="${STATE_DIR}/smoothiso-frontend.log"

http_respond() {
    status="$1"
    message="$2"
    content_type="$3"
    body="$4"
    body_len=$(printf '%s' "$body" | wc -c)

    printf 'HTTP/1.1 %s %s\r\n' "$status" "$message"
    printf 'Content-Type: %s\r\n' "$content_type"
    printf 'Cache-Control: no-cache, no-store, must-revalidate\r\n'
    printf 'Content-Length: %s\r\n' "$body_len"
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '%s' "$body"
}

next_request_json() {
    for req_file in "$REQUEST_DIR"/*.json; do
        [ -f "$req_file" ] || continue
        cat "$req_file"
        return 0
    done
    printf 'null'
}

serve_static_file() {
    path="$1"
    [ "$path" = "/" ] && path="/index.html"
    if [ -d "${FRONTEND_DIR}${path}" ]; then
        path="${path%/}/index.html"
    fi

    case "$path" in
        */..) 
            http_respond "403" "Forbidden" "text/plain; charset=utf-8" "Forbidden"
            return
            ;;
    esac

    if [ -z "$path" ] || [ "$path" = "/" ]; then
        path="/index.html"
    fi

    local_file="${FRONTEND_DIR}${path}"
    if [ ! -f "$local_file" ]; then
        http_respond "404" "Not Found" "text/plain; charset=utf-8" "Not found"
        return
    fi

    ext="${local_file##*.}"
    content_type="application/octet-stream"
    case "$ext" in
        html) content_type="text/html; charset=utf-8" ;;
        js) content_type="application/javascript; charset=utf-8" ;;
        css) content_type="text/css; charset=utf-8" ;;
        json) content_type="application/json; charset=utf-8" ;;
        svg) content_type="image/svg+xml" ;;
        png) content_type="image/png" ;;
        jpg|jpeg) content_type="image/jpeg" ;;
        gif) content_type="image/gif" ;;
        txt) content_type="text/plain; charset=utf-8" ;;
        ico) content_type="image/x-icon" ;;
    esac

    body=$(cat "$local_file")
    http_respond "200" "OK" "$content_type" "$body"
}

if ! read request_line; then
    exit 0
fi
request_line="${request_line%$'\r'}"
method="${request_line%% *}"
rest="${request_line#* }"
path_with_query="${rest%% *}"
query=""
path="$path_with_query"
case "$path_with_query" in
    *\?*)
        query="${path_with_query#*\?}"
        path="${path_with_query%\?*}"
        ;;
esac

content_length=0
while read header; do
    header="${header%$'\r'}"
    [ -z "$header" ] && break
    case "$header" in
        Content-Length:*|content-length:*)
            content_length="${header#*: }"
            ;;
    esac
done

body=""
if [ -n "$content_length" ] && [ "$content_length" -gt 0 ] 2>/dev/null; then
    body=$(dd bs=1 count="$content_length" 2>/dev/null || true)
fi

case "$path" in
    /cgi-bin/request)
        [ "$method" = "GET" ] || { http_respond "405" "Method Not Allowed" "application/json; charset=utf-8" '{"error":"method not allowed"}'; exit 0; }
        payload=$(next_request_json)
        http_respond "200" "OK" "application/json; charset=utf-8" "$payload"
        ;;
    /cgi-bin/respond)
        [ "$method" = "POST" ] || { http_respond "405" "Method Not Allowed" "application/json; charset=utf-8" '{"error":"method not allowed"}'; exit 0; }
        req_id=""
        for pair in $(printf '%s' "$query" | tr '&' ' '); do
            case "$pair" in
                id=*) req_id="${pair#id=}" ;;
            esac
        done
        [ -n "$req_id" ] || { http_respond "400" "Bad Request" "application/json; charset=utf-8" '{"error":"missing id"}'; exit 0; }
        mkdir -p "$RESPONSE_DIR"
        printf '%s' "$body" > "${RESPONSE_DIR}/${req_id}.json"
        http_respond "200" "OK" "application/json; charset=utf-8" "{\"ok\":true,\"id\":\"$req_id\"}"
        ;;
    *)
        [ "$method" = "GET" ] || { http_respond "405" "Method Not Allowed" "text/plain; charset=utf-8" "Method not allowed"; exit 0; }
        serve_static_file "$path"
        ;;
esac
SH

    chmod +x "$bridge"

    # Some busybox builds reject `-s` in listen mode (we have seen
    # `nc: invalid option -- 's'` in the d-i image). Listen mode binds
    # the port on all interfaces by default; if BIND_ADDR is set to a
    # specific loopback address we just rely on that default — the
    # firewall context here is the installer ramdisk, never an external
    # interface.
    log "starting busybox nc bridge on ${BIND_ADDR}:${PORT} (single-shot loop)"
    busybox nc -l -p "$PORT" -e "$bridge" >>"$NC_LOG" 2>&1 &
    local nc_pid=$!
    sleep 1
    if ! kill -0 "$nc_pid" 2>/dev/null; then
        log "busybox nc died during startup; see ${NC_LOG}"
        return 1
    fi
    log "busybox nc bridge running (pid=$nc_pid)"

    # Respawn nc after each connection finishes (busybox nc -l only handles one).
    # `wait` won't work across the subshell boundary so we poll with kill -0.
    (
        while kill -0 "$nc_pid" 2>/dev/null; do
            sleep 1
        done
        while true; do
            busybox nc -l -p "$PORT" -e "$bridge" >>"$NC_LOG" 2>&1
        done
    ) &
    return 0
}

log "ui-backend start: BIND=${BIND_ADDR} PORT=${PORT} FRONTEND_DIR=${FRONTEND_DIR}"
if [ -e /sys/class/net/lo ] && [ -r /sys/class/net/lo/operstate ]; then
    log "lo operstate: $(cat /sys/class/net/lo/operstate 2>/dev/null || echo unknown)"
fi
if command -v ip >/dev/null 2>&1; then
    log "interfaces: $(ip -o link 2>/dev/null | tr '\n' ';' | head -c 400)"
fi

if start_busybox_httpd; then
    log "selected backend: busybox httpd"
    wait
    exit 0
fi

if start_python; then
    log "selected backend: python3"
    wait
    exit 0
fi

if start_busybox_nc; then
    log "selected backend: busybox nc"
    wait
    exit 0
fi

log "ALL BACKENDS FAILED. Per-backend logs follow."
log "----- httpd -----"
[ -s "$HTTPD_LOG" ] && cat "$HTTPD_LOG" >> "$LOG_FILE"
log "----- python -----"
[ -s "$PYTHON_LOG" ] && cat "$PYTHON_LOG" >> "$LOG_FILE"
log "----- nc -----"
[ -s "$NC_LOG" ] && cat "$NC_LOG" >> "$LOG_FILE"
log "----- end -----"

echo "SmoothGUI frontend backend unavailable; tried busybox httpd, python3, and busybox nc." >&2
exit 1
