# Native-auth local HTTPS fixture

A deterministic, loopback-only, metadata-only fixture for unattended Semreh ↔ WebUI ↔ Hermes Browser Use native-auth E2E. It uses only Python's standard library plus the system `openssl` executable. It never requires credentials or manual form input.

## Start

From the repository root, run this in terminal 1 (foreground by design):

```bash
cd tests/e2e/native_auth_fixture
python3 launch.py | tee /tmp/semreh-native-auth-ready.json
```

The launcher prints exactly one JSON `ready` record, then waits. Both HTTPS ports are dynamically allocated on `127.0.0.1`. The ephemeral self-signed SAN certificate and private key live in a mode-0700 runtime temporary directory outside the repository and are removed at shutdown.

In terminal 2, select an endpoint from the ready record without hard-coding a port:

```bash
READY=/tmp/semreh-native-auth-ready.json
endpoint() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["endpoints"][sys.argv[2]])' "$READY" "$1"; }
```

## Health, manifest, state, and reset

```bash
curl --silent --show-error --insecure "$(endpoint health)"
curl --silent --show-error --insecure "$(endpoint manifest)"
curl --silent --show-error --insecure "$(endpoint state)"
curl --silent --show-error --insecure \
  --request POST --header 'Content-Type: application/x-www-form-urlencoded' --data '' \
  "$(endpoint reset)"
```

`/__test__/state` contains only bounded safe metadata: scenario/route, global and scenario attempt numbers, allowlisted field names/kinds, present/empty booleans, length buckets, unexpected-field count, and redirect/invalid-result state. It never retains submitted strings, POST bodies, query contents, headers, cookies, auth data, tokens, or referrers.

## Shutdown

```bash
curl --silent --show-error --insecure \
  --request POST --header 'Content-Type: application/x-www-form-urlencoded' --data '' \
  "$(endpoint shutdown)"
```

Shutdown terminates both HTTPS origins and removes the temporary certificate directory. The fixture is intentionally not installed as a daemon and never uses supervised or fixed ports.

## Run the matrix

```bash
cd tests/e2e/native_auth_fixture
python3 run_matrix.py
python3 run_matrix.py --list
```

The manifest is the programmatic source of truth for all 39 versioned scenarios and each case's `fillable`, `fail_closed_target_changed`, `browser_owned`, or `unsupported` expected behavior. Browser-owned checkpoints expose unmistakable metadata and no fake credential inputs. Pages use no third-party requests, analytics, external assets/fonts, storage, cookies, or service workers.

