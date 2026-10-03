"""Reference business checks for an unfrozen C00 proposal, never production I/O.

The caller first validates JSON Schema. Context is independent controlled store,
Agent lifecycle, read-tool and file evidence; accepting model-supplied context
would invalidate every guarantee in this module.
"""

import base64
import hashlib
from uuid import UUID

from recording_ai_contract_common import canonical_bytes, decode_json, range_errors, schema_validator, source_equal, uuid_set, valid_relative_path
from recording_ai_contract_request import validate as validate_request


def _id(value):
    return str(UUID(value))


def _same_id(left, right):
    try:
        return _id(left) == _id(right)
    except (ValueError, TypeError, AttributeError):
        return False


def _bytes(file):
    if isinstance(file.get("bytesUTF8"), str):
        return file["bytesUTF8"].encode("utf-8")
    if isinstance(file.get("bytesBase64"), str):
        return base64.b64decode(file["bytesBase64"], validate=True)
    raise ValueError("fileBytesMissing")


def _citations(value):
    if isinstance(value, dict):
        if "source" in value and "segmentIDs" in value:
            yield value
        for child in value.values():
            yield from _citations(child)
    elif isinstance(value, list):
        for child in value:
            yield from _citations(child)


def _citation_errors(value, source, selected, input_value):
    errors = []
    segments = {_id(item["id"]): item for item in input_value.get("segments", [])}
    for citation in _citations(value):
        if not source_equal(citation["source"], source):
            errors.append("citationSourceMismatch")
        cited = uuid_set(citation["segmentIDs"])
        if not cited <= selected:
            errors.append("citationOutsideSelection")
        if "startSample" in citation:
            if range_errors(citation):
                errors.append("citationRangeInvalid")
            ranges = [r for sid in cited if sid in segments for r in segments[sid].get("sourceRanges", [])]
            identities = {(r["sourceKind"], _id(r["sourceID"])) for r in ranges}
            if len(identities) != 1:
                errors.append("citationAmbiguousRange")
            else:
                cursor = citation["startSample"]
                for interval in sorted(ranges, key=lambda r: r["startSample"]):
                    if interval["startSample"] <= cursor:
                        cursor = max(cursor, interval["endSample"])
                if cursor < citation["endSample"]:
                    errors.append("citationRangeOutsideSource")
        if "excerpt" in citation and not any(citation["excerpt"] in segments[sid]["text"] for sid in cited if sid in segments):
            errors.append("citationExcerptMismatch")
    return errors


def _file_errors(files, context):
    errors = []
    paths = [item["relativePath"] for item in files]
    if len(paths) != len(set(paths)):
        errors.append("duplicateFilePath")
    evidence = {item["relativePath"]: item for item in context.get("files", [])}
    for item in files:
        path = item["relativePath"]
        if not valid_relative_path(path):
            errors.append("artifactUnsafePath")
        observed = evidence.get(path)
        if observed is None:
            errors.append("artifactFileMissing")
            continue
        if observed.get("kind") != "regular":
            errors.append("artifactFileNotRegular")
        try:
            if hashlib.sha256(_bytes(observed)).hexdigest() != item["sha256"]:
                errors.append("artifactFileHashMismatch")
        except (ValueError, UnicodeError):
            errors.append("artifactFileEvidenceMissing")
    return errors


def _representation_errors(artifact, context):
    """Structured data is authoritative; previews require managed-render evidence."""
    errors, structured = [], False
    evidence = {item["relativePath"]: item for item in context.get("files", [])}
    renderer = context.get("rendererEvidence", {})
    data_hash = hashlib.sha256(canonical_bytes(artifact["data"])).hexdigest()
    rendered = {item["relativePath"]: item for item in renderer.get("files", [])}
    for file in artifact["files"]:
        actual = evidence.get(file["relativePath"])
        if actual is None:
            continue
        try:
            raw = _bytes(actual)
            if file["mediaType"] == "application/json":
                structured = True
                if canonical_bytes(decode_json(raw.decode("utf-8"))) != canonical_bytes(artifact["data"]):
                    errors.append("artifactStructuredDataMismatch")
            elif file["mediaType"] in ("text/markdown", "text/vnd.mermaid"):
                text = raw.decode("utf-8")
                if "\x00" in text:
                    errors.append("artifactFileFormatInvalid")
                expected = rendered.get(file["relativePath"])
                if (not _same_id(renderer.get("artifactID"), artifact["artifactID"])
                        or renderer.get("type") != artifact["type"]
                        or renderer.get("dataSha256") != data_hash
                        or expected is None or expected.get("mediaType") != file["mediaType"]
                        or _bytes(expected) != raw):
                    errors.append("artifactRendererMismatch")
            else:
                errors.append("artifactMediaTypeUnsupported")
        except (ValueError, UnicodeError):
            errors.append("artifactFileFormatInvalid")
    if not structured:
        errors.append("artifactStructuredDataMissing")
    return errors


def _coverage_errors(coverage, context):
    request, evidence = context.get("request"), context.get("readEvidence")
    if not isinstance(request, dict) or not isinstance(evidence, dict):
        return ["artifactEvidenceMissing"]
    required = ("selectedSegmentIDs", "inputSha256")
    if any(key not in request for key in required) or "readSegmentIDs" not in evidence:
        return ["artifactEvidenceMissing"]
    errors = []
    selected = uuid_set(coverage["selectedSegmentIDs"])
    read = uuid_set(coverage["readSegmentIDs"])
    missing = uuid_set(coverage["missingSegmentIDs"])
    expected = uuid_set(request["selectedSegmentIDs"])
    observed = uuid_set(evidence["readSegmentIDs"])
    if selected != expected:
        errors.append("artifactSelectionMismatch")
    if not read <= selected or not missing <= selected or read & missing or read | missing != selected:
        errors.append("coveragePartitionInvalid")
    if read != observed or evidence.get("inputSha256") != request["inputSha256"]:
        errors.append("artifactReadEvidenceMismatch")
    # Original audio gaps need not have text IDs. Unread selected text is not
    # relabelled as an unrecoverable audio gap to pass a publication check.
    if read != selected or observed != selected or missing:
        errors.append("incompleteInputRead")
    if "unresolvedRanges" not in context:
        errors.append("artifactEvidenceMissing")
    elif canonical_bytes(coverage["unresolvedRanges"]) != canonical_bytes(context["unresolvedRanges"]):
        errors.append("coverageUnresolvedMismatch")
    for item in coverage["unresolvedRanges"]:
        errors.extend(range_errors(item["range"]))
    return errors


def _action_errors(actions, artifact, context):
    errors = []
    ids = [str(UUID(item["actionID"])) for item in actions]
    if len(ids) != len(set(ids)):
        errors.append("duplicateActionID")
    for item in actions:
        if not _same_id(item["artifactID"], artifact["artifactID"]):
            errors.append("actionArtifactMismatch")
        if not source_equal(item["source"], artifact["source"]):
            errors.append("actionSourceMismatch")
    if "writeAttempts" not in context:
        errors.append("artifactEvidenceMissing")
    elif context["writeAttempts"] != 0:
        errors.append("unconfirmedActionWrite")
    return errors


def _minutes_errors(data, context):
    request = context.get("request", {})
    record = request.get("recordingContext", {})
    completeness = request.get("completeness", {})
    if "kind" not in record or any(key not in completeness for key in ("processingState", "contentState", "recordingContentState")):
        return ["artifactEvidenceMissing"]
    if record["kind"] == "recording" or completeness["processingState"] != "terminal":
        expected = "preliminary"
    elif "partial" in (completeness["contentState"], completeness["recordingContentState"]):
        expected = "withMissingContent"
    elif completeness["contentState"] != "complete" or completeness["recordingContentState"] != "complete" or record["kind"] != "meeting":
        expected = "completenessUnknown"
    else:
        expected = "formal"
    return [] if data["summaryClass"] == expected else ["summaryClassMismatch"]


def _tree_errors(data):
    errors = []
    nodes = {_id(node["nodeID"]): node for node in data["nodes"]}
    if len(nodes) != len(data["nodes"]):
        errors.append("mindmapDuplicateNode")
    root = _id(data["rootNodeID"])
    roots = [key for key, node in nodes.items() if node["parentNodeID"] is None]
    if roots != [root] or root not in nodes or nodes[root]["type"] != "topic":
        errors.append("mindmapInvalidRoot")
    actions = uuid_set([action["actionID"] for action in data["actions"]])
    for node in nodes.values():
        if node["parentNodeID"] is not None and _id(node["parentNodeID"]) not in nodes:
            errors.append("mindmapParentMissing")
        if node["type"] == "action" and _id(node["actionID"]) not in actions:
            errors.append("mindmapActionMissing")
        key, seen, depth = _id(node["nodeID"]), set(), 0
        while key in nodes:
            if key in seen:
                errors.append("mindmapCycle")
                break
            seen.add(key)
            depth += 1
            if depth > 12:
                errors.append("mindmapDepthExceeded")
            parent = nodes[key]["parentNodeID"]
            if parent is None:
                if key != root:
                    errors.append("mindmapUnreachable")
                break
            key = _id(parent)
    return errors


def _export_errors(data, artifact, context):
    origin = context.get("originatingArtifact")
    if not isinstance(origin, dict) or origin.get("status") != "committed":
        return ["exportOriginMissing"]
    errors = []
    if not _same_id(origin["artifactID"], data["originatingArtifactID"]) or origin["type"] != data["originatingType"]:
        errors.append("exportOriginMismatch")
    if not source_equal(origin["source"], artifact["source"]):
        errors.append("exportSourceMismatch")
    body = origin["data"]
    if origin["type"] == "mindmap":
        expected = {_id(node["nodeID"]): node["citations"] for node in body["nodes"]}
        hierarchy = [{"nodeID": node["nodeID"], "parentNodeID": node["parentNodeID"]} for node in body["nodes"]]
    else:
        expected = {_id(action["actionID"]): action["citations"] for action in body["actions"]}
        if origin["type"] == "minutes":
            expected[_id(origin["artifactID"])] = origin["citations"]
        hierarchy = []
    observed = {_id(item["elementID"]): item["citations"] for item in data["provenance"]}
    if len(observed) != len(data["provenance"]) or observed.keys() != expected.keys() or any(canonical_bytes(observed[key]) != canonical_bytes(expected[key]) for key in observed.keys() & expected.keys()):
        errors.append("exportProvenanceMissing")
    if canonical_bytes(data["hierarchy"]) != canonical_bytes(hierarchy):
        errors.append("exportHierarchyMismatch")
    metadata = canonical_bytes({"source": artifact["source"], "provenance": data["provenance"], "hierarchy": data["hierarchy"]}).decode("utf-8")
    header = "<!-- voicecontext-provenance: " + metadata + " -->" if data["format"] == "markdown" else "%% voicecontext-provenance: " + metadata
    files = {file["relativePath"]: file for file in context.get("files", [])}
    rendered_count = 0
    for declared in artifact["files"]:
        if declared["mediaType"] == "application/json":
            continue
        rendered_count += 1
        try:
            text = _bytes(files[declared["relativePath"]]).decode("utf-8")
            expected_media = "text/markdown" if data["format"] == "markdown" else "text/vnd.mermaid"
            if declared["mediaType"] != expected_media or header not in text.splitlines():
                errors.append("exportMetadataMissing")
        except (KeyError, ValueError, UnicodeError):
            errors.append("exportMetadataMissing")
    if rendered_count == 0:
        errors.append("exportFileMissing")
    return errors


def _validate(definition, value, context):
    if definition in ("file", "files"):
        return list(dict.fromkeys(_file_errors([value] if definition == "file" else value, context)))
    if definition == "coverage":
        return list(dict.fromkeys(_coverage_errors(value, context)))
    if definition not in ("artifact", "artifactBase"):
        artifact = context.get("artifact")
        if not isinstance(artifact, dict):
            return ["artifactEvidenceMissing"]
        artifact = {**artifact, "data": value, "type": definition}
    else:
        artifact = value
    request, run, read = context.get("request"), context.get("runAssociation"), context.get("readEvidence")
    if not all(isinstance(item, dict) for item in (request, run, read)) or not isinstance(context.get("inputBytesUTF8"), str):
        return ["artifactEvidenceMissing"]
    if any(key not in request for key in ("source", "requestID", "inputSha256", "selectedSegmentIDs")):
        return ["artifactEvidenceMissing"]
    errors = []
    if not source_equal(artifact["source"], request["source"]):
        errors.append("artifactSourceMismatch")
    if not _same_id(artifact["requestID"], request["requestID"]):
        errors.append("artifactRequestMismatch")
    actual_hash = hashlib.sha256(context["inputBytesUTF8"].encode("utf-8")).hexdigest()
    if artifact["inputSha256"] != request["inputSha256"] or actual_hash != artifact["inputSha256"]:
        errors.append("artifactInputHashMismatch")
    if not isinstance(context.get("canonicalBytesUTF8"), str):
        errors.append("artifactEvidenceMissing")
    elif hashlib.sha256(context["canonicalBytesUTF8"].encode("utf-8")).hexdigest() != artifact["source"]["sha256"]:
        errors.append("artifactSourceHashMismatch")
    if not _same_id(run.get("runID"), artifact["runID"]) or run.get("sessionID") != artifact["sessionID"] or not _same_id(run.get("requestID"), artifact["requestID"]) or run.get("inputSha256") != artifact["inputSha256"] or not run.get("startedAt") or not _same_id(read.get("runID"), artifact["runID"]):
        errors.append("artifactRunMismatch")
    trigger = context.get("triggerMessage", {})
    if not _same_id(run.get("triggerMessageID"), artifact["triggerMessageID"]) or not _same_id(trigger.get("id"), artifact["triggerMessageID"]) or trigger.get("sessionID") != artifact["sessionID"] or trigger.get("role") != "user":
        errors.append("artifactTriggerMismatch")
    if context.get("sourceDeleted"):
        errors.append("artifactSourceDeleted")
    if not schema_validator("request", "runAssociation").is_valid(run):
        errors.append("artifactRunEvidenceInvalid")
    else:
        errors.extend(validate_request("runAssociation", run, context))
    try:
        input_value = decode_json(context["inputBytesUTF8"])
    except (ValueError, TypeError):
        return list(dict.fromkeys(errors + ["artifactInputEvidenceMissing"]))
    if not schema_validator("request", "input").is_valid(input_value):
        return list(dict.fromkeys(errors + ["artifactInputSchemaInvalid"]))
    errors.extend(validate_request("input", input_value, context))
    if not source_equal(input_value["source"], artifact["source"]):
        errors.append("artifactSourceMismatch")
    if uuid_set(input_value["selectedSegmentIDs"]) != uuid_set(request["selectedSegmentIDs"]) or uuid_set([s["id"] for s in input_value["segments"]]) != uuid_set(request["selectedSegmentIDs"]):
        errors.append("artifactSelectionMismatch")
    if input_value.get("recordingContext") != request.get("recordingContext") or input_value.get("completeness") != request.get("completeness"):
        errors.append("artifactInputContextMismatch")
    errors.extend(_coverage_errors(artifact["coverage"], context))
    errors.extend(_citation_errors(artifact, artifact["source"], uuid_set(request["selectedSegmentIDs"]), input_value))
    errors.extend(_file_errors(artifact["files"], context))
    errors.extend(_representation_errors(artifact, context))
    data = artifact["data"]
    errors.extend(_action_errors(data.get("actions", []), artifact, context))
    if artifact["type"] == "minutes":
        errors.extend(_minutes_errors(data, context))
    elif artifact["type"] == "mindmap":
        errors.extend(_tree_errors(data))
    elif artifact["type"] == "export":
        errors.extend(_export_errors(data, artifact, context))
    return list(dict.fromkeys(errors))


def validate(definition, value, context):
    """Return independent errors; malformed external evidence fails closed."""
    try:
        return _validate(definition, value, context)
    except (KeyError, TypeError, ValueError, OverflowError):
        return ["artifactEvidenceMalformed"]
