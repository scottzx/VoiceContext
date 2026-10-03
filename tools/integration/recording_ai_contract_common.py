"""Reference checks for the C00 proposal, not application persistence or I/O."""

import hashlib
import json
import re
from functools import lru_cache
from pathlib import Path, PurePosixPath
from uuid import UUID


def canonical_bytes(value):
    """The proposal uses scalar-sorted keys, exact strings and signed Int64."""
    def check(item):
        if item is None or isinstance(item, bool):
            return
        if isinstance(item, int):
            if not -(2**63) <= item < 2**63:
                raise ValueError("integerOutsideInt64")
            return
        if isinstance(item, str):
            try:
                item.encode("utf-8", errors="strict")
            except UnicodeEncodeError as error:
                raise ValueError("invalidUnicode") from error
            return
        if isinstance(item, list):
            for child in item:
                check(child)
            return
        if isinstance(item, dict):
            for key, child in item.items():
                if not isinstance(key, str):
                    raise ValueError("nonStringKey")
                check(key)
                check(child)
            return
        raise ValueError("unsupportedCanonicalType")

    check(value)
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def payload_hash(value):
    bound = {key: value[key] for key in ("actionID", "artifactID", "source", "citations", "payload")}
    return hashlib.sha256(canonical_bytes(bound)).hexdigest()


def source_equal(a, b):
    return UUID(a["recordingID"]) == UUID(b["recordingID"]) and a["revision"] == b["revision"] and a["sha256"] == b["sha256"]


def uuid_set(ids):
    return {str(UUID(item)) for item in ids}


def valid_relative_path(path):
    if not isinstance(path, str) or not path or "\\" in path or "\x00" in path:
        return False
    parts = path.split("/")
    return not (PurePosixPath(path).is_absolute() or re.match(r"^[A-Za-z]:", path) or any(part in ("", ".", "..") for part in parts))


def range_key(value):
    return value["sourceKind"], str(UUID(value["sourceID"]))


def range_errors(value):
    errors = []
    if value["startSample"] < 0 or value["endSample"] <= value["startSample"]:
        errors.append("invalidRange")
    if value["startSample"] >= 2**63 or value["endSample"] >= 2**63:
        errors.append("integerOutsideInt64")
    return errors


def decode_json(raw):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicateJSONKey")
            result[key] = value
        return result

    def constant(_):
        raise ValueError("invalidJSONConstant")

    return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)


@lru_cache(maxsize=None)
def schema_validator(name, definition):
    from jsonschema import Draft202012Validator, FormatChecker
    from referencing import Registry, Resource

    folder = Path(__file__).resolve().parents[2] / "docs/design/recording-ai-actions-schema"
    registry = Registry()
    for path in folder.glob("*.schema.json"):
        schema = decode_json(path.read_text(encoding="utf-8"))
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
    selected = decode_json((folder / f"{name}.schema.json").read_text(encoding="utf-8"))
    return Draft202012Validator({"$ref": f"{selected['$id']}#/$defs/{definition}"}, registry=registry, format_checker=FormatChecker())
