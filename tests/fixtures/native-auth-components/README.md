# Native-auth component fixtures

This directory is the dependency-free validation slice for
[`docs/contracts/native-auth-components-v1.md`](../../../docs/contracts/native-auth-components-v1.md).

## Layout

- `valid/` contains one model-facing message per JSON file for password/secret,
  one-time-code, browser-owned OIDC/passkey/CAPTCHA flows, cancellation, the
  auth context, and the synthetic encrypted-envelope shape.
- `invalid/` contains deliberately rejected messages for every security boundary
  called out by the contract: unknown kind, oversized label, selector/HTML/JS
  injection, query-string/path leakage, unsafe origin, credential-shaped keys,
  and plaintext envelope fields.
- `test_native_auth_components.py` is a standard-library-only test runner. It
  validates the fixtures against the checked-in JSON Schema using a small
  dependency-free validator, applies recursive forbidden-key checks, and probes
  unsafe origins/paths.

No fixture contains a real credential or secret. The envelope fixture contains
only a clearly marked `enc_v1.synthetic_placeholder.*` ciphertext placeholder;
the test checks its shape and never decodes or interprets it.

Run from the repository root:

```bash
python3 tests/fixtures/native-auth-components/test_native_auth_components.py
```

