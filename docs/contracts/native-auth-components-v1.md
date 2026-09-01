# Native authentication components contract v1

**Status:** shared contract, v1
**Audience:** Hermes model-facing messages, the Semreh native client, and the browser-side auth bridge
**Schema:** [`native-auth-components-v1.schema.json`](./native-auth-components-v1.schema.json)

This contract lets Hermes ask Semreh to help with an authentication surface without
turning credentials or browser internals into model-visible data. It is a metadata
and capability contract, not a login protocol. The browser remains the owner of
web authentication and exact element references; Semreh remains the owner of secure
native input and secret storage.

## Message types

The JSON Schema is a closed union of these four `type` values:

| Message | Direction/role | Purpose |
| --- | --- | --- |
| `hermes.auth-context.v1` | browser -> model/native bridge | Describes one bounded authentication context and the opaque component/action handles available in it. |
| `semreh.native-component.v1` | browser -> model/native bridge | Describes one browser-issued component, its allowlisted kind, and its immutable target binding. |
| `semreh.native-component-state.v1` | browser -> model/native bridge | Reports safe lifecycle metadata for a component, including browser-owned OIDC, passkey, or CAPTCHA phases and cancellation. |
| `semreh.native-secret-envelope.v1` | native -> native/browser boundary | Carries an opaque encrypted envelope for a secure-fill operation. It is never journaled or interpreted by the model. |

Every message is versioned by its `type`. v1 objects use `additionalProperties: false`.
An additive field is not implicitly compatible: it must be added to this schema and
reviewed for the security rules below, or introduced in a new version.

## Shared metadata rules

### Opaque handles

`context_id`, `browser_session_id`, `component_id`, `field`, `action_handle`,
`tab_handle`, `frame_handle`, `document_generation`, `envelope_id`, and all other
`*_handle`/`ref_id` values are opaque handles. They are identifiers only; they must
not carry credentials, selectors authored by the model, URLs, query strings,
fragments, or user-entered values. They are bounded to 128 characters and use the
schema's restricted handle alphabet.

### Provider origin and path

- `provider_origin` is a canonical HTTPS origin: lowercase DNS host, no userinfo,
  trailing slash, path, query, or fragment. The default HTTPS port is omitted; a
  non-default numeric port may be present.
- `path` is path-only and begins with `/`. It has no `?` or `#` and cannot be used
  to smuggle a query string or fragment. The schema intentionally permits only a
  conservative URL-path character set.
- Origin and path are metadata used for exact binding checks. They are not an
  instruction for the model to navigate or construct a new target.

### Labels and kinds

`label` is a bounded display/accessibility label (maximum 80 characters) with no
markup, control characters, or executable syntax. The only component `kind` values
are:

`identifier`, `secret`, `one_time_code`, `recovery_code`, `submit`, `sso_continue`,
`email_magic_link`, `phone_verification`, `passkey`, `security_key`, `captcha`,
`push_approval`, `device_approval`, and `cancel`.

A password form uses `kind: "secret"`; the word `password` is not a kind and must
not be used to create a new credential category.

## Browser-issued target references

Hermes/WebUI retains an internal `binding` with an exact `target_ref`. The browser
creates this reference and sets `issued_by: "browser"` and `immutable: true`.
The projected native-component event intentionally omits this internal binding;
Hermes revalidates it when the encrypted envelope returns. Internal references may
use one of these bounded strategies:

- `css` with a conservative, length-bounded selector;
- `xpath` with a conservative, length-bounded XPath;
- `role` with an allowlisted role plus a bounded label;
- `label` with a bounded label;
- `frame` with an opaque frame handle;
- `cdp` with an opaque CDP handle; or
- `playwright` with an opaque Playwright locator handle.

The model and page may request an operation by `component_id` or
`action_handle`, but may not author, replace, or alter `target_ref`, its strategy,
its selector, or its binding. A model-provided selector is not a valid target
reference. The native client must reject a reference that did not come from the
browser-issued message associated with the current context.

The binding also carries browser-issued `tab_handle`, `frame_handle`,
`document_generation`, `visibility`, `editability`, and `match_count`. These are
snapshots used for validation, not claims that bypass validation. `match_count`
must be exactly one and visibility must be `visible`.

## Secure-fill gate

Before Semreh decrypts a `semreh.native-secret-envelope.v1` or places any secret
material into a native/browser field, secure-fill revalidates all of the following
against the live browser session, not only the serialized message:

1. `context_id` and `browser_session_id` still identify the active context/session;
2. the `tab_handle` is the expected tab;
3. the `frame_handle` is the expected frame;
4. `document_generation` is current (no navigation or document replacement);
5. the live canonical origin exactly equals `provider_origin`;
6. the component `kind` is the expected allowlisted kind;
7. the target is currently visible;
8. the target is currently editable when the kind requires input; and
9. the exact target reference resolves to one and only one match.

If any check fails, Semreh must not decrypt, fill, retry against a different
locator, or fall back to page-authored DOM instructions. Reacquire a new
browser-issued component instead.

## Model-facing data exclusion

No model-facing message may contain fields or nested keys for:

- credentials or credential-like values (`credential`, `value`, `defaultValue`);
- DOM text or markup (`DOM text`, `text`, `html`, or equivalent snapshots);
- cookies or bearer material (`cookie`, `token`);
- OIDC response material (`code`, `state`, `PKCE`, or equivalent);
- `query` or `fragment` data.

The schema's closed objects prevent undeclared fields, and the fixture validator
also rejects forbidden credential-shaped keys recursively (including common
camelCase/snake_case variants). A label is not a DOM snapshot, and a browser-issued
role/label reference is not permission to send page text to the model.

The message `semreh.native-component-state.v1` can expose only browser-owned flow
metadata such as `flow_kind: "oidc"`, `flow_kind: "passkey"`, or
`flow_kind: "captcha"`, a bounded `phase`, and an opaque `flow_handle`. It never
exposes a provider response, protocol code, protocol state, challenge bytes, or
redirect query parameters.

## Encrypted secret envelope

`semreh.native-secret-envelope.v1` exposes only an envelope identifier, binding
metadata, cipher-suite metadata, and an opaque `ciphertext`. Field IDs and their
corresponding values may exist **only inside the authenticated ciphertext**; there
is no plaintext `field_ids` member and no plaintext value member in this contract.
The model never decrypts the envelope.

The envelope has `journal_policy: "never"`. It must not be written to chat
transcripts, session history, analytics, debug logs, crash reports, browser
storage, or tool traces. Redact the whole envelope before telemetry. The fixtures
use an unmistakable synthetic ciphertext placeholder; the validator checks its
shape but never decodes or interprets it.

## Cancellation and browser-owned flows

Cancellation is represented with a normal component-state message using
`kind: "cancel"`, `status: "cancelled"`, and a bounded `cancel_reason`. It carries
no field value and must invalidate any pending secure-fill operation for the
associated action handle.

OIDC, passkey, and CAPTCHA operations remain browser-owned. Semreh may display
safe lifecycle metadata and ask the browser to continue by opaque handle, but it
does not receive or manufacture protocol state, authorization codes, PKCE data,
CAPTCHA answers, cookies, or tokens.

## Fixture coverage

The companion fixture directory is
`tests/fixtures/native-auth-components/`:

- valid password/secret and one-time-code component forms;
- valid browser-owned OIDC, passkey, and CAPTCHA lifecycle states;
- valid cancellation and synthetic encrypted-envelope messages; and
- invalid unknown kind, oversized label, selector/HTML/JavaScript injection,
  query-string leakage, and credential-shaped payloads.

Run the standalone, dependency-free validator from the repository root:

```bash
python3 tests/fixtures/native-auth-components/test_native_auth_components.py
```

It validates the schema/fixture contract, checks the positive and negative fixture
sets, and verifies that only the synthetic ciphertext placeholder is treated as
opaque test data.

