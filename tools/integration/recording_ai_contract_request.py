"""Business reference for the proposed selected input and request records.

This checks supplied fixtures. It does not atomically read TranscriptDocumentStore,
observe a real chat run, constrain Agent tools, or publish application files.
"""

import hashlib
from datetime import datetime
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from recording_ai_contract_common import decode_json, range_errors, range_key, schema_validator, source_equal, uuid_set


def _ids(values):
    return [str(UUID(value)) for value in values]


def _context_errors(value):
    if value["timezone"] is not None:
        try:
            ZoneInfo(value["timezone"])
        except (ValueError, ZoneInfoNotFoundError):
            return ["invalidTimezone"]
    return []


def _recording_context(document):
    zone = document.get("timezone")
    try:
        if zone is not None:
            ZoneInfo(zone)
    except (ValueError, ZoneInfoNotFoundError):
        # An old opaque/fixed-offset identifier does not become the current
        # device zone. Preserve its original bytes privately and expose null.
        zone = None
    return {"kind": document["kind"] if document["kind"] in ("meeting", "recording") else None, "startedAt": document.get("started_at"), "timezone": zone}


def _original_locations(original):
    raw_ranges = original.get("source_ranges", [])
    if not raw_ranges and original.get("source_chunk_id"):
        start = original.get("start_sample", original["offset_milliseconds"] * 16)
        raw_ranges = [{"source_kind": "audio_chunk", "source_id": original["source_chunk_id"], "start_sample": start, "end_sample": original.get("end_sample", start)}]
    ranges, anchors = [], []
    for raw in raw_ranges:
        scope = {"sourceKind": raw.get("source_kind", "audio_chunk"), "sourceID": raw.get("source_id", raw.get("chunk_id")), "startSample": raw["start_sample"], "endSample": raw["end_sample"]}
        if scope["endSample"] > scope["startSample"]:
            ranges.append(scope)
        elif scope["endSample"] == scope["startSample"]:
            anchors.append({"segmentID": original["id"], "sourceKind": scope["sourceKind"], "sourceID": scope["sourceID"], "sample": scope["startSample"]})
    return ranges, anchors


def _contained(scope, allowed):
    cursor = scope["startSample"]
    for interval in sorted((item for item in allowed if range_key(item) == range_key(scope)), key=lambda item: item["startSample"]):
        if interval["startSample"] > cursor:
            break
        cursor = max(cursor, interval["endSample"])
        if cursor >= scope["endSample"]:
            return True
    return False


def _anchor_errors(completeness, anchors):
    def anchor_identity(anchor):
        return UUID(anchor["segmentID"]), range_key(anchor), anchor["sample"]

    actual = {anchor_identity(item) for item in completeness["legacyAnchors"]}
    expected = {anchor_identity(item) for item in anchors}
    return ["legacyAnchorMismatch"] if actual != expected or len(actual) != len(completeness["legacyAnchors"]) else []


def _projection_errors(completeness, selected, allowed):
    errors = []
    for scope in completeness["expectedRanges"]:
        if not _contained(scope, allowed):
            errors.append("selectionEvidenceLeak")
    for scope in allowed:
        if not _contained(scope, completeness["expectedRanges"]):
            errors.append("selectionDomainMismatch")
    for row in completeness["observedRanges"]:
        if not _contained(row["range"], allowed) or not uuid_set(row["segmentIDs"]).issubset(set(selected)):
            errors.append("selectionEvidenceLeak")
        # Evidence carries no text; its nested sample bounds still belong to
        # the selected source interval, never the whole original job window.
        def nested_bounds(item):
            if isinstance(item, dict):
                if "startSample" in item and "endSample" in item:
                    projected = dict(row["range"], startSample=item["startSample"], endSample=item["endSample"])
                    if not _contained(projected, allowed):
                        errors.append("selectionEvidenceLeak")
                for child in item.values():
                    nested_bounds(child)
            elif isinstance(item, list):
                for child in item:
                    nested_bounds(child)
        nested_bounds(row["evidence"])
    for warning in completeness["warnings"]:
        if warning["range"] is not None and not _contained(warning["range"], allowed):
            errors.append("selectionEvidenceLeak")
    for gap in completeness["captureGaps"]:
        start, end = gap["startSample"], gap["endSample"]
        if not any(item["startSample"] <= start < item["endSample"] and (end is None or end <= item["endSample"]) for item in allowed):
            errors.append("selectionEvidenceLeak")
    return errors


def _input_errors(value, context):
    errors = _context_errors(value["recordingContext"])
    if context.get("sourceDeleted"):
        errors.append("sourceUnavailable")
    selected = _ids(value["selectedSegmentIDs"])
    segment_ids = _ids([item["id"] for item in value["segments"]])
    if len(set(selected)) != len(selected) or segment_ids != selected:
        errors.append("selectionMismatch")
    completeness = value["completeness"]
    if _ids(completeness["selectedSegmentIDs"]) != selected:
        errors.append("selectionMismatch")
    anchors = completeness["legacyAnchors"]
    for segment in value["segments"]:
        for scope in segment["sourceRanges"]:
            errors.extend(range_errors(scope))
        if not segment["sourceRanges"]:
            if not any(UUID(anchor["segmentID"]) == UUID(segment["id"]) for anchor in anchors):
                errors.append("sourceLocationMissing")
            if completeness["contentState"] == "complete":
                errors.append("legacyAnchorNotCoverage")

    raw = context.get("canonicalBytesUTF8")
    if raw is None:
        return errors + ["authorityMissing"]
    try:
        document = decode_json(raw)
    except ValueError:
        return errors + ["authorityMalformed"]
    expected_source = {"recordingID": document["recording_id"], "revision": document["revision"], "sha256": hashlib.sha256(raw.encode("utf-8")).hexdigest()}
    if not source_equal(value["source"], expected_source):
        errors.append("sourceMismatch")
    expected_context = _recording_context(document)
    if value["recordingContext"] != expected_context:
        errors.append("recordingContextMismatch")
    source_segments = {str(UUID(item["id"])): item for item in document["segments"]}
    expected_order = [str(UUID(item["id"])) for item in document["segments"] if str(UUID(item["id"])) in set(selected)]
    if selected != expected_order:
        errors.append("selectionMismatch")
    if value["selectionMode"] == "all" and selected != _ids([item["id"] for item in document["segments"]]):
        errors.append("selectionMismatch")
    allowed_ranges, exact_anchors = [], []
    for item in value["segments"]:
        original = source_segments.get(str(UUID(item["id"])))
        if original is None:
            errors.append("selectionMismatch")
            continue
        if item["text"] != original["text"] or item["sequence"] != original["sequence"]:
            errors.append("segmentChanged")
        ranges, original_anchors = _original_locations(original)
        allowed_ranges.extend(ranges)
        exact_anchors.extend(original_anchors)
        if item["sourceRanges"] != ranges:
            errors.append("segmentRangeMismatch")
        if item["speakerLabel"] != context.get("approvedSpeakerLabels", {}).get(item["id"]):
            errors.append("metadataNotApproved")
    if value["metadata"] != context.get("approvedMetadata", {}) or value["template"] != context.get("approvedTemplate"):
        errors.append("metadataNotApproved")
    # Evidence comes from a source-matched private sidecar, never model input.
    if value["completeness"] != context.get("approvedCompleteness"):
        errors.append("evidenceMismatch")
    errors.extend(_anchor_errors(completeness, exact_anchors))
    if value["selectionMode"] == "segments":
        errors.extend(_projection_errors(completeness, selected, allowed_ranges))
    from recording_ai_contract_transcript import validate as validate_transcript
    errors.extend(validate_transcript("completeness", completeness, {}))
    return errors


def _run_errors(value, context):
    errors = []
    start = datetime.fromisoformat(value["startedAt"].replace("Z", "+00:00"))
    end = value["endedAt"]
    if (value["state"] == "running") != (end is None):
        errors.append("runStateMismatch")
    if end is not None and datetime.fromisoformat(end.replace("Z", "+00:00")) < start:
        errors.append("timestampOrder")
    actual = context.get("executionRecord")
    if actual is None:
        errors.append("executionEvidenceMissing")
    elif not all(actual.get(key) == value[key] for key in ("runID", "requestID", "inputSha256", "sessionID", "triggerMessageID", "startedAt", "endedAt", "state")) or actual.get("started") is not True:
        errors.append("executionMismatch")
    return errors


def _request_errors(value, context):
    errors = _context_errors(value["recordingContext"])
    if value["inputPath"] != f'VoiceContext/Requests/{value["requestID"]}/input.json':
        errors.append("inputPathMismatch")
    if uuid_set(value["selectedSegmentIDs"]) != uuid_set(value["completeness"]["selectedSegmentIDs"]):
        errors.append("selectionMismatch")
    if set(value["resultTypes"]) != set(value["typeOutcomes"]):
        errors.append("outcomeTypesMismatch")
    outcomes = list(value["typeOutcomes"].values())
    for item in outcomes:
        if (item["state"] == "committed") != bool(item["artifactIDs"]):
            errors.append("outcomeArtifactMismatch")
        if item["state"] == "committed" and item["errorCode"] is not None:
            errors.append("outcomeErrorMismatch")
        if item["state"] == "failed" and item["errorCode"] is None:
            errors.append("outcomeErrorMismatch")
    states = {item["state"] for item in outcomes}
    state = value["state"]
    if state == "prepared":
        if states != {"pending"} or value["runAssociations"]:
            errors.append("requestStateMismatch")
    elif "running" in states or "pending" in states:
        if state != "running":
            errors.append("requestStateMismatch")
    elif "validating" in states:
        if state != "validating":
            errors.append("requestStateMismatch")
    elif states == {"committed"}:
        if state != "committed":
            errors.append("requestStateMismatch")
    elif "committed" in states:
        if state != "partiallyCommitted":
            errors.append("requestStateMismatch")
    elif state not in states or state not in ("failed", "cancelled", "interrupted"):
        errors.append("requestStateMismatch")
    if state in ("running", "validating", "committed", "partiallyCommitted") and (value["modelBindingID"] is None or not value["runAssociations"]):
        errors.append("executionEvidenceMissing")
    if len(uuid_set([run["runID"] for run in value["runAssociations"]])) != len(value["runAssociations"]):
        errors.append("duplicateRunID")
    for run in value["runAssociations"]:
        if UUID(run["requestID"]) != UUID(value["requestID"]) or run["inputSha256"] != value["inputSha256"]:
            errors.append("executionMismatch")
        errors.extend(_run_errors(run, {"executionRecord": context.get("executionRecords", {}).get(run["runID"])}))
    raw = context.get("inputBytesUTF8")
    if raw is None:
        return errors + ["authorityMissing"]
    if hashlib.sha256(raw.encode("utf-8")).hexdigest() != value["inputSha256"]:
        errors.append("inputHashMismatch")
    try:
        fixed_input = decode_json(raw)
    except ValueError:
        return errors + ["inputMalformed"]
    if not schema_validator("request", "input").is_valid(fixed_input):
        return errors + ["inputSchemaInvalid"]
    if UUID(fixed_input["requestID"]) != UUID(value["requestID"]) or not source_equal(fixed_input["source"], value["source"]):
        errors.append("sourceMismatch")
    for key in ("recordingContext", "selectionMode", "selectedSegmentIDs", "completeness"):
        if fixed_input[key] != value[key]:
            errors.append("inputBindingMismatch")
    errors.extend(_input_errors(fixed_input, context))
    if datetime.fromisoformat(value["updatedAt"].replace("Z", "+00:00")) < datetime.fromisoformat(value["createdAt"].replace("Z", "+00:00")):
        errors.append("timestampOrder")
    return errors


def validate(definition, value, context):
    try:
        if definition == "input":
            return _input_errors(value, context)
        if definition == "request":
            return _request_errors(value, context)
        if definition == "runAssociation":
            return _run_errors(value, context)
        if definition == "recordingContext":
            return _context_errors(value)
    except (KeyError, TypeError, ValueError, OverflowError):
        return ["authorityMalformed"]
    return []
