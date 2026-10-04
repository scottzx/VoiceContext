#!/usr/bin/env python3
"""Offline schema and business-vector regression for the C00 review proposal.

Requires jsonschema and referencing. No network, app launch, EventKit, or private
user data. Passing this command does not freeze or implement the contract.
"""

import argparse
import hashlib
import importlib
import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "docs/design/recording-ai-actions-schema"
AREAS = ("request", "artifact", "transcript", "reminder")


def verify_canonical_vectors():
    from recording_ai_contract_common import canonical_bytes

    cases = load(SCHEMAS / "canonical-hash.vectors.json")
    for case in cases:
        if "valueUTF16" in case:
            value = "".join(chr(unit) for unit in case["valueUTF16"])
        elif "valueNumber" in case:
            value = {"nan": float("nan"), "positiveInfinity": float("inf"), "negativeInfinity": float("-inf")}[case["valueNumber"]]
        else:
            value = case["value"]
        try:
            raw = canonical_bytes(value)
        except ValueError as error:
            if str(error) != case.get("errorCode"):
                raise AssertionError(f"canonical/{case['name']}: {error}") from error
        else:
            if "errorCode" in case:
                raise AssertionError(f"canonical/{case['name']}: expected rejection")
            if raw != case["canonicalUTF8"].encode("utf-8") or hashlib.sha256(raw).hexdigest() != case["sha256"]:
                raise AssertionError(f"canonical/{case['name']}: golden bytes/hash differ")
    print(f"canonical: {len(cases)} exact-byte/rejection vectors checked")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load(path):
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique_object)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--area", choices=AREAS)
    args = parser.parse_args()
    verify_canonical_vectors()
    schemas = {}
    registry = Registry()
    for path in sorted(SCHEMAS.glob("*.schema.json")):
        schema = load(path)
        Draft202012Validator.check_schema(schema)
        if schema["$id"] in schemas:
            raise ValueError("duplicate schema ID")
        schemas[schema["$id"]] = schema
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
    failures = []
    count = 0
    for area in (args.area,) if args.area else AREAS:
        schema = load(SCHEMAS / f"{area}.schema.json")
        module = importlib.import_module(f"recording_ai_contract_{area}")
        cases = load(SCHEMAS / f"{area}.cases.json")
        names = set()
        for case in cases:
            count += 1
            label = f"{area}/{case['name']}"
            if case["name"] in names:
                failures.append(f"{label}: duplicate case name")
            names.add(case["name"])
            if case["definition"] not in schema["$defs"]:
                failures.append(f"{label}: missing definition")
                continue
            validator = Draft202012Validator({"$ref": f"{schema['$id']}#/$defs/{case['definition']}"}, registry=registry, format_checker=FormatChecker())
            shape_errors = list(validator.iter_errors(case["value"]))
            schema_valid = not shape_errors
            if schema_valid != case["schemaValid"]:
                detail = shape_errors[0].message if shape_errors else "unexpectedly accepted"
                failures.append(f"{label}: schema: {detail}")
            errors = module.validate(case["definition"], case["value"], case.get("context", {})) if schema_valid else ["schemaInvalid"]
            semantic_valid = not errors
            if semantic_valid != case["semanticValid"]:
                failures.append(f"{label}: business: {errors or 'unexpectedly accepted'}")
            if schema_valid and "errorCode" in case and case["errorCode"] not in errors:
                failures.append(f"{label}: missing error {case['errorCode']}; got {errors}")
        print(f"{area}: {len(cases)} vectors checked")
    if failures:
        print("\n".join(failures))
        raise SystemExit(1)
    print(f"PASS: {len(schemas)} draft schemas, {count} shape/business vectors; production and runtime unverified")


if __name__ == "__main__":
    main()
