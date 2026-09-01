#!/usr/bin/env python3
"""Validate the v1 native-auth schema and its positive/negative fixtures.

This runner intentionally uses only the Python standard library. It implements
just the JSON Schema vocabulary used by the checked-in contract so validation is
runnable on a clean checkout without adding a dependency to Semreh.
"""

from __future__ import annotations

import copy
import json
import re
import sys
import unittest
from pathlib import Path
from urllib.parse import urlsplit


HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
SCHEMA_PATH = REPO_ROOT / "docs" / "contracts" / "native-auth-components-v1.schema.json"
VALID_DIR = HERE / "valid"
INVALID_DIR = HERE / "invalid"

MESSAGE_TYPES = {
    "hermes.auth-context.v1",
    "semreh.native-component.v1",
    "semreh.native-component-state.v1",
    "semreh.native-secret-envelope.v1",
}

# Compare normalized key spellings so credential-shaped additions cannot hide
# behind camelCase, snake_case, dashes, or capitalization.
FORBIDDEN_KEYS = {
    "credential",
    "credentials",
    "value",
    "values",
    "defaultvalue",
    "defaultvalues",
    "domtext",
    "text",
    "innertext",
    "html",
    "innerhtml",
    "outerhtml",
    "cookie",
    "cookies",
    "token",
    "tokens",
    "code",
    "oidccode",
    "state",
    "oidcstate",
    "pkce",
    "pkcedata",
    "query",
    "querystring",
    "fragment",
    "secret",
    "secretvalue",
    "password",
    "passphrase",
    "authorization",
    "bearer",
}


class SchemaValidationError(AssertionError):
    """Raised when an instance does not satisfy the checked-in schema."""


def normalized_key(key: str) -> str:
    return re.sub(r"[^a-z0-9]", "", key.casefold())


def forbidden_key_paths(value: object, path: str = "$", found: list[str] | None = None) -> list[str]:
    if found is None:
        found = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            if normalized_key(key) in FORBIDDEN_KEYS:
                found.append(child_path)
            forbidden_key_paths(child, child_path, found)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            forbidden_key_paths(child, f"{path}[{index}]", found)
    return found


class MiniJSONSchemaValidator:
    """Small validator for the closed vocabulary used by this contract.

    The production contract remains the JSON Schema file. This class exists so
    the fixture test does not require jsonschema or any other third-party module.
    """

    def __init__(self, schema: dict[str, object]):
        self.schema = schema

    def resolve(self, reference: str) -> dict[str, object]:
        if not reference.startswith("#/"):
            raise SchemaValidationError(f"unsupported schema reference: {reference}")
        node: object = self.schema
        for part in reference[2:].split("/"):
            if not isinstance(node, dict) or part not in node:
                raise SchemaValidationError(f"unresolved schema reference: {reference}")
            node = node[part]
        if not isinstance(node, dict):
            raise SchemaValidationError(f"schema reference is not an object: {reference}")
        return node

    @staticmethod
    def type_matches(instance: object, expected: str) -> bool:
        if expected == "object":
            return isinstance(instance, dict)
        if expected == "array":
            return isinstance(instance, list)
        if expected == "string":
            return isinstance(instance, str)
        if expected == "integer":
            return isinstance(instance, int) and not isinstance(instance, bool)
        if expected == "number":
            return isinstance(instance, (int, float)) and not isinstance(instance, bool)
        if expected == "boolean":
            return isinstance(instance, bool)
        if expected == "null":
            return instance is None
        raise SchemaValidationError(f"unsupported schema type: {expected}")

    def validate(self, instance: object, node: dict[str, object] | None = None, path: str = "$") -> None:
        if node is None:
            node = self.schema
        if "$ref" in node:
            self.validate(instance, self.resolve(str(node["$ref"])), path)
            return

        expected_type = node.get("type")
        if expected_type is not None:
            if isinstance(expected_type, list):
                type_ok = any(self.type_matches(instance, str(item)) for item in expected_type)
            else:
                type_ok = self.type_matches(instance, str(expected_type))
            if not type_ok:
                raise SchemaValidationError(f"{path}: expected {expected_type}")

        if "const" in node and instance != node["const"]:
            raise SchemaValidationError(f"{path}: expected const {node['const']!r}")

        if "enum" in node and instance not in node["enum"]:
            raise SchemaValidationError(f"{path}: expected one of {node['enum']!r}")

        if "oneOf" in node:
            matches = 0
            failures: list[str] = []
            for branch in node["oneOf"]:
                try:
                    self.validate(instance, branch, path)
                except SchemaValidationError as error:
                    failures.append(str(error))
                else:
                    matches += 1
            if matches != 1:
                detail = "; ".join(failures[:3])
                raise SchemaValidationError(f"{path}: oneOf matched {matches} branches ({detail})")

        if "anyOf" in node:
            for branch in node["anyOf"]:
                try:
                    self.validate(instance, branch, path)
                except SchemaValidationError:
                    continue
                break
            else:
                raise SchemaValidationError(f"{path}: anyOf matched no branches")

        if "allOf" in node:
            for branch in node["allOf"]:
                self.validate(instance, branch, path)

        if "if" in node:
            condition_matches = True
            try:
                self.validate(instance, node["if"], path)
            except SchemaValidationError:
                condition_matches = False
            if condition_matches and "then" in node:
                self.validate(instance, node["then"], path)
            elif not condition_matches and "else" in node:
                self.validate(instance, node["else"], path)

        if isinstance(instance, str):
            if "minLength" in node and len(instance) < int(node["minLength"]):
                raise SchemaValidationError(f"{path}: shorter than minLength")
            if "maxLength" in node and len(instance) > int(node["maxLength"]):
                raise SchemaValidationError(f"{path}: longer than maxLength")
            if "pattern" in node and re.search(str(node["pattern"]), instance) is None:
                raise SchemaValidationError(f"{path}: does not match pattern")

        if isinstance(instance, list):
            if "minItems" in node and len(instance) < int(node["minItems"]):
                raise SchemaValidationError(f"{path}: fewer than minItems")
            if "maxItems" in node and len(instance) > int(node["maxItems"]):
                raise SchemaValidationError(f"{path}: more than maxItems")
            if node.get("uniqueItems"):
                encoded = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in instance]
                if len(encoded) != len(set(encoded)):
                    raise SchemaValidationError(f"{path}: items are not unique")
            if "items" in node:
                for index, item in enumerate(instance):
                    self.validate(item, node["items"], f"{path}[{index}]")

        if isinstance(instance, dict):
            required = node.get("required", [])
            for key in required:
                if key not in instance:
                    raise SchemaValidationError(f"{path}: missing required field {key!r}")

            properties = node.get("properties", {})
            if not isinstance(properties, dict):
                raise SchemaValidationError(f"{path}: malformed properties schema")
            additional = node.get("additionalProperties", True)
            for key, child in instance.items():
                if key in properties:
                    self.validate(child, properties[key], f"{path}.{key}")
                elif additional is False:
                    raise SchemaValidationError(f"{path}: additional property {key!r}")
                elif isinstance(additional, dict):
                    self.validate(child, additional, f"{path}.{key}")

        if node.get("not") is not None:
            try:
                self.validate(instance, node["not"], path)
            except SchemaValidationError:
                pass
            else:
                raise SchemaValidationError(f"{path}: not-schema matched")


def load_json(path: Path) -> object:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def load_message(path: Path) -> dict[str, object]:
    message = load_json(path)
    if not isinstance(message, dict):
        raise SchemaValidationError(f"{path.name}: fixture root must be an object")
    return message


def is_canonical_origin(origin: object) -> bool:
    if not isinstance(origin, str) or origin != origin.strip():
        return False
    parsed = urlsplit(origin)
    if parsed.scheme != "https" or parsed.username or parsed.password:
        return False
    if not parsed.hostname or parsed.path or parsed.query or parsed.fragment:
        return False
    if parsed.netloc != parsed.netloc.lower():
        return False
    try:
        port = parsed.port
    except ValueError:
        return False
    if port is not None and (port == 443 or not 1 <= port <= 65535):
        return False
    return re.fullmatch(
        r"https://[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+(?:\:[0-9]{1,5})?",
        origin,
    ) is not None


def is_safe_path(path: object) -> bool:
    return isinstance(path, str) and re.fullmatch(r"/(?:[A-Za-z0-9._~!$&'()*+,;=:@/-]*)", path) is not None


class NativeAuthFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = load_json(SCHEMA_PATH)
        if not isinstance(cls.schema, dict):
            raise SchemaValidationError("schema root must be an object")
        cls.validator = MiniJSONSchemaValidator(cls.schema)
        cls.valid_paths = sorted(VALID_DIR.glob("*.json"))
        cls.invalid_paths = sorted(INVALID_DIR.glob("*.json"))

    def assert_valid_fixture(self, path: Path) -> dict[str, object]:
        message = load_message(path)
        self.validator.validate(message)
        self.assertIn(message.get("type"), MESSAGE_TYPES, path.name)
        return message

    def assert_invalid_fixture(self, path: Path) -> None:
        message = load_message(path)
        with self.assertRaises(SchemaValidationError, msg=path.name):
            self.validator.validate(message)

    def test_schema_is_a_closed_four_message_union(self) -> None:
        self.assertEqual(self.schema.get("$schema"), "https://json-schema.org/draft/2020-12/schema")
        branches = self.schema.get("oneOf")
        self.assertIsInstance(branches, list)
        self.assertEqual(len(branches), 4)
        self.assertEqual(MESSAGE_TYPES, {
            "hermes.auth-context.v1",
            "semreh.native-component.v1",
            "semreh.native-component-state.v1",
            "semreh.native-secret-envelope.v1",
        })
        for name in ("authContext", "nativeComponent", "nativeComponentState", "nativeSecretEnvelope"):
            definition = self.schema["$defs"][name]
            self.assertIs(definition.get("additionalProperties"), False, name)

    def test_valid_fixture_coverage_and_schema_validation(self) -> None:
        expected = {
            "auth-context.json",
            "password-form.json",
            "otp-form.json",
            "webui-projected-identifier.json",
            "browser-owned-oidc-state.json",
            "browser-owned-passkey-state.json",
            "browser-owned-captcha-state.json",
            "cancellation.json",
            "secret-envelope.json",
        }
        self.assertEqual(expected, {path.name for path in self.valid_paths})
        seen_types = set()
        for path in self.valid_paths:
            message = self.assert_valid_fixture(path)
            seen_types.add(message["type"])
            self.assertEqual([], forbidden_key_paths(message), path.name)
        self.assertEqual(MESSAGE_TYPES, seen_types)

    def test_invalid_fixture_coverage_and_rejection(self) -> None:
        expected = {
            "unknown-kind.json",
            "oversized-label.json",
            "selector-injection.json",
            "html-injection.json",
            "javascript-injection.json",
            "query-string-leakage.json",
            "unsafe-origin.json",
            "credential-bearing-payload.json",
            "plaintext-envelope-fields.json",
        }
        self.assertEqual(expected, {path.name for path in self.invalid_paths})
        for path in self.invalid_paths:
            self.assert_invalid_fixture(path)

    def test_forbidden_credential_shaped_keys_are_rejected_recursively(self) -> None:
        base = load_message(VALID_DIR / "password-form.json")
        for key in (
            "credential",
            "credentials",
            "value",
            "defaultValue",
            "DOM_text",
            "text",
            "cookie",
            "token",
            "code",
            "state",
            "PKCE",
            "query",
            "fragment",
        ):
            mutated = copy.deepcopy(base)
            mutated["safe_metadata"] = {key: None}
            self.assertTrue(forbidden_key_paths(mutated), key)
            with self.assertRaises(SchemaValidationError, msg=key):
                self.validator.validate(mutated)

    def test_unsafe_origins_and_paths_are_rejected(self) -> None:
        base = load_message(VALID_DIR / "password-form.json")
        for origin in (
            "http://accounts.example.test",
            "https://accounts.example.test/",
            "https://accounts.example.test?next=/evil",
            "https://user:pass@accounts.example.test",
            "https://accounts.example.test:443",
            "https://Accounts.example.test",
        ):
            mutated = copy.deepcopy(base)
            mutated["provider_origin"] = origin
            with self.assertRaises(SchemaValidationError, msg=origin):
                self.validator.validate(mutated)
            self.assertFalse(is_canonical_origin(origin), origin)

        for path in ("/login?next=/evil", "/login#fragment", "https://evil.example.test/login"):
            mutated = copy.deepcopy(base)
            mutated["path"] = path
            with self.assertRaises(SchemaValidationError, msg=path):
                self.validator.validate(mutated)
            self.assertFalse(is_safe_path(path), path)

    def test_browser_issued_target_reference_is_immutable_and_bounded(self) -> None:
        base = load_message(VALID_DIR / "password-form.json")
        for binding_mutation in (
            {"issued_by": "model"},
            {"immutable": False},
            {"match_count": 2},
            {"visibility": "hidden"},
            {"target_ref": {"issued_by": "model"}},
        ):
            mutated = copy.deepcopy(base)
            mutated["binding"].update(binding_mutation)
            with self.assertRaises(SchemaValidationError, msg=str(binding_mutation)):
                self.validator.validate(mutated)

    def test_secret_envelope_has_no_plaintext_field_ids_and_is_never_journaled(self) -> None:
        message = self.assert_valid_fixture(VALID_DIR / "secret-envelope.json")
        self.assertNotIn("field_ids", message)
        self.assertNotIn("fields", message)
        self.assertEqual(message["journal_policy"], "never")
        self.assertRegex(message["ciphertext"], r"^enc_v1\.synthetic_placeholder\.[A-Za-z0-9_-]+$")
        # Deliberately do not base64-decode or otherwise interpret ciphertext.
        self.assertEqual([], forbidden_key_paths(message))


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(NativeAuthFixtureTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)

