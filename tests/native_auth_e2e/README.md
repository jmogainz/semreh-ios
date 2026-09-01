# Native-auth E2E fixture matrix

This subtree is a dependency-free, local-only harness for repeatable native-auth
boundary testing. It does not modify or depend on Hermes/WebUI runtime files, a
personal browser profile, CDP, or supervised ports.

## Matrix

Cases always run in this order:

1. `flat_username_password` — one browser-issued context and target accepts one
   username/password-shaped submission.
2. `expiry` — a deterministic logical-clock control expires the issued context;
   no wall-clock sleeps are used.
3. `replay` — the first use is accepted and reuse of the same context is rejected.
4. `target_replacement` — a stale browser-issued target is rejected after an
   explicit generation change, then a newly issued target is accepted.

The HTTPS listener binds `127.0.0.1:0`, so the OS chooses a disposable port. A
one-day self-signed certificate and mode-`0600` key are generated in a temporary
directory and removed when the fixture closes.

## Metadata-only boundary

Submitted fixture values are synthetic, generated in memory, and sent only to the
loopback fixture. The server immediately reduces them to boolean presence counters.
It never records request bodies, field values, lengths, query strings, cookies,
tokens, selectors, screenshots, or browser storage. HTTP request logging is disabled.
The report contains only:

- ordered case IDs and terminal outcomes;
- opaque fixture context/target handles while a case is running; and
- bounded integer counters (`contexts_issued`, `submission_attempts`, field presence,
  accepted, expired, replay, and replaced-target totals).

`SubmissionDriver` in `orchestrator.py` is the adapter seam for a future signed iOS
simulator/native secure-input driver. `SyntheticLoopbackDriver` is fixture-only and
must not be pointed at a non-loopback origin; `HTTPSFixtureClient` enforces loopback
HTTPS.

## Commands

From the repository root:

```bash
# Run all harness tests.
python3 -m unittest discover -s tests/native_auth_e2e -p 'test_*.py' -v

# List the stable matrix.
python3 tests/native_auth_e2e/orchestrator.py --list

# Run the complete local matrix and print one metadata-only JSON report.
python3 tests/native_auth_e2e/orchestrator.py --run-local

# Optional: launch the disposable HTTPS fixture for a separate driver.
python3 tests/native_auth_e2e/fixture.py --serve
```

The standalone fixture prints one safe ready record containing its dynamic loopback
origin. Stop it with `Ctrl-C`; its certificate directory is then cleaned up.

