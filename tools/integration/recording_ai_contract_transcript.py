"""Pure reference rules for the unfrozen C00 transcript proposal.

Call only after JSON Schema validation. Context is fixture-supplied external
facts, not an execution lease, filesystem probe or atomic commit boundary.
"""

import hashlib

from recording_ai_contract_common import (
    range_errors, range_key, source_equal, uuid_set, valid_relative_path,
)


def _bounds_errors(ranges):
    return [error for item in ranges for error in range_errors(item)]


def _union(intervals):
    merged = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def _covers(intervals, start, end):
    return any(low <= start and end <= high for low, high in _union(intervals))


def _group(ranges):
    grouped = {}
    for item in ranges:
        grouped.setdefault(range_key(item), []).append((item["startSample"], item["endSample"]))
    return grouped


def _subset(ranges, domain):
    grouped = _group(domain)
    return all(_covers(grouped.get(range_key(item), []), item["startSample"], item["endSample"])
               for item in ranges)


def _overlaps(ranges):
    return any(any(right[0] < left[1] for left, right in zip(sorted(rows), sorted(rows)[1:]))
               for rows in _group(ranges).values())


def _bound_inside(bounds, outer):
    return all(outer["startSample"] <= item["startSample"] < item["endSample"] <= outer["endSample"]
               for item in bounds)


def _evidence_errors(row):
    errors = []
    evidence, outer, outcome = row["evidence"], row["range"], row["outcome"]
    decoded = evidence["decode"]["decodedRanges"]
    speech = evidence["vad"]["speechRanges"]
    processed = evidence["asr"]["processedSpeechRanges"]
    errors.extend(_bounds_errors(decoded + speech + processed))
    if not _bound_inside(decoded + speech + processed, outer):
        errors.append("evidenceOutsideRange")
    if outcome in ("transcribed", "silence", "voicedEmpty"):
        if evidence["decode"]["status"] != "complete" or not _covers(
                [(item["startSample"], item["endSample"]) for item in decoded],
                outer["startSample"], outer["endSample"]):
            errors.append("decodeCoverageIncomplete")
    if outcome == "silence":
        if (evidence["vad"]["status"] != "noSpeech" or speech
                or not evidence["vad"]["detectorVersion"]
                or evidence["asr"]["status"] != "notRun" or processed or row["segmentIDs"]):
            errors.append("silenceEvidenceMissing")
    elif outcome in ("transcribed", "voicedEmpty"):
        if evidence["vad"]["status"] != "speech" or not speech or not evidence["vad"]["detectorVersion"]:
            errors.append("speechEvidenceMissing")
        expected_asr = "text" if outcome == "transcribed" else "empty"
        if evidence["asr"]["status"] != expected_asr:
            errors.append("voicedEmptyEvidenceMissing" if outcome == "voicedEmpty" else "transcriptionEvidenceMissing")
        if not all(_covers([(item["startSample"], item["endSample"]) for item in processed],
                           span["startSample"], span["endSample"]) for span in speech):
            errors.append("speechCoverageIncomplete")
        if outcome == "voicedEmpty" and row["segmentIDs"]:
            errors.append("emptyOutcomeHasText")
    elif outcome == "unreadable" and evidence["decode"]["status"] not in ("failed", "partial"):
        errors.append("unreadableEvidenceMissing")
    elif outcome == "missing" and evidence["decode"]["status"] != "notRun":
        errors.append("missingSourceWasDecoded")
    elif outcome == "failed":
        stage = row["stage"]
        if stage in ("decode", "vad", "asr") and evidence[stage]["status"] != "failed":
            errors.append("failureStageMismatch")
        if stage == "utterance" and (evidence["vad"]["status"] != "speech"
                                     or not speech or evidence["asr"]["status"] != "notRun"):
            errors.append("failureStageMismatch")
    return errors


def _completeness(value, context):
    errors = []
    expected = value["expectedRanges"]
    observed = value["observedRanges"]
    observed_ranges = [row["range"] for row in observed]
    errors.extend(_bounds_errors(expected + observed_ranges))
    if _overlaps(expected) or _overlaps(observed_ranges):
        errors.append("coverageOverlap")
    if not _subset(observed_ranges, expected):
        errors.append("observationOutsideDomain")
    for row in observed:
        errors.extend(_evidence_errors(row))
    for gap in value["captureGaps"]:
        if (gap["startSample"] >= 2**63 or gap["endSample"] is not None
                and (gap["endSample"] < gap["startSample"] or gap["endSample"] >= 2**63)):
            errors.append("invalidGap")
    if any(anchor["sample"] >= 2**63 for anchor in value["legacyAnchors"]):
        errors.append("integerOutsideInt64")
    if value["scope"] == "selection":
        selected = uuid_set(value["selectedSegmentIDs"])
        referred = {item for row in observed for item in uuid_set(row["segmentIDs"])}
        referred.update(uuid_set([item["segmentID"] for item in value["legacyAnchors"]]))
        if not referred <= selected:
            errors.append("unselectedSegmentReference")
        if "recordingContentState" in context and value["recordingContentState"] != context["recordingContentState"]:
            errors.append("recordingCompletenessChanged")
    if value["scope"] == "recording" and value["processingState"] == "capturing" and value["domainFinalized"]:
        errors.append("captureDomainStillOpen")
    negative = any(row["outcome"] in ("pending", "voicedEmpty", "unreadable", "missing", "failed", "interrupted")
                   for row in observed) or any(gap["unrecoverable"] for gap in value["captureGaps"])
    unresolved = (not value["domainFinalized"] or bool(value["legacyAnchors"])
                  or any(gap["endSample"] is None for gap in value["captureGaps"])
                  or not _subset(expected, [row["range"] for row in observed
                                            if row["outcome"] in ("transcribed", "silence")]))
    derived = "partial" if negative else "unknown" if unresolved else "complete"
    if value["contentState"] != derived:
        errors.append("contentStateMismatch")
    if not value["domainFinalized"] and value["contentState"] == "complete":
        errors.append("domainNotFinalized")
    return errors


def _scopes(scopes):
    return [item["range"] for item in scopes]


def _preflight(value, context):
    errors = _bounds_errors(_scopes(value["requestedScopes"]))
    requested = value["requestedScopes"]
    results = value["results"]
    if len(results) != len(requested) or any(sum(row["scope"] == scope for row in results) != 1 for scope in requested):
        errors.append("preflightInventoryIncomplete")
    for row in results:
        scope = row["scope"]["range"]
        errors.extend(range_errors(scope))
        count = scope["endSample"] - scope["startSample"]
        if row["declaredSampleCount"] != count:
            errors.append("declaredRangeMismatch")
        if row["decodeRange"] is not None:
            errors.extend(range_errors(row["decodeRange"]))
        if row["status"] == "readable":
            decoded = row["decodeRange"]
            target_start = scope["startSample"] - row["sourceStartSample"]
            target_end = target_start + count
            if (target_start < 0 or decoded["startSample"] != target_start or decoded["endSample"] != target_end
                    or row["actualSampleCount"] < target_end or row["decodedSampleCount"] < count):
                errors.append("readableRangeNotCovered")
    if context.get("tombstoned"):
        errors.append("sourceDeleted")
    if "currentSource" in context and not source_equal(value["baseSource"], context["currentSource"]):
        errors.append("sourceChanged")
    return errors


def _candidate(value, context):
    requested, processed = _scopes(value["requestedScopes"]), _scopes(value["actuallyProcessedScopes"])
    errors = _bounds_errors(requested + processed)
    if not _subset(processed, requested):
        errors.append("candidateOutsideRetryScope")
    draft_ids = uuid_set([item["draftID"] for item in value["drafts"]])
    if len(draft_ids) != len(value["drafts"]):
        errors.append("duplicateDraftID")
    for draft in value["drafts"]:
        errors.extend(_bounds_errors(draft["sourceRanges"]))
        if not _subset(draft["sourceRanges"], processed):
            errors.append("draftOutsideProcessedScope")
    if "planSource" in context and not source_equal(value["baseSource"], context["planSource"]):
        errors.append("candidatePlanSourceMismatch")
    if context.get("tombstoned"):
        errors.append("sourceDeleted")
    return errors


def _adoption(value, context):
    errors = _bounds_errors([choice["range"] for choice in value["choices"]])
    if context.get("tombstoned"):
        errors.append("sourceDeleted")
    if "currentSource" in context and not source_equal(value["expectedCurrentSource"], context["currentSource"]):
        errors.append("sourceChanged")
    if "candidateSha256" in context and value["candidateSha256"] != context["candidateSha256"]:
        errors.append("candidateChanged")
    if value["status"] == "committed":
        result, base = value["resultSource"], value["expectedCurrentSource"]
        if uuid_set([result["recordingID"]]) != uuid_set([base["recordingID"]]) or result["revision"] <= base["revision"]:
            errors.append("revisionNotAdvanced")
    candidate = context.get("candidate")
    if candidate and uuid_set([candidate["candidateID"]]) != uuid_set([value["candidateID"]]):
        errors.append("candidateIdentityMismatch")
    protected = uuid_set(context.get("manuallyEditedSegmentIDs", []))
    for choice in value["choices"]:
        if choice["decision"] != "acceptCandidate":
            continue
        if value["mode"] == "preserveCalibrated" and uuid_set(choice["existingSegmentIDs"]) & protected:
            errors.append("calibratedSegmentReplacement")
        if candidate:
            drafts = {item["draftID"].lower(): item for item in candidate["drafts"]}
            for draft_id in choice["draftIDs"]:
                draft = drafts.get(draft_id.lower())
                if draft is None:
                    errors.append("unknownCandidateDraft")
                elif value["mode"] == "preserveCalibrated" and draft["mapping"]["status"] != "stable":
                    errors.append("mappingNeedsReview")
                elif not _subset(draft["sourceRanges"], [choice["range"]]):
                    errors.append("adoptionOutsideChoiceRange")
    return errors


def _history(value, context):
    errors = []
    if not valid_relative_path(value["canonicalPath"]):
        errors.append("invalidManagedPath")
    if "canonicalBytesUTF8" in context:
        digest = hashlib.sha256(context["canonicalBytesUTF8"].encode("utf-8")).hexdigest()
        if digest != value["source"]["sha256"]:
            errors.append("sourceBytesMismatch")
    if "parentSource" in context and value["parentSource"] is not None and not source_equal(value["parentSource"], context["parentSource"]):
        errors.append("historyParentMismatch")
    if context.get("tombstoned"):
        errors.append("sourceDeleted")
    return errors


def _deletion(value, context):
    errors = []
    policy = value["policy"]
    if policy["raw"] != "delete" or policy["systemItems"] != "keep":
        errors.append("deletionPolicyInvalid")
    objects = value["objects"]
    raw_archives = uuid_set(context.get("rawArchiveObjectIDs", []))
    if len(uuid_set([item["objectID"] for item in objects])) != len(objects):
        errors.append("duplicateDeletionObjectID")
    for item in objects:
        if item["locator"] is not None and not valid_relative_path(item["locator"]):
            errors.append("invalidManagedPath")
        if item["state"] == "kept" and item["dataClass"] == "derived":
            if policy["derived"]["mode"] != "keepSelected" or item["artifactType"] not in policy["derived"]["keptTypes"]:
                errors.append("derivedRetentionNotSelected")
        if item["state"] == "kept" and (item["dataClass"] in ("raw", "index")
                                        or item["containsRawArchive"] or uuid_set([item["objectID"]]) & raw_archives):
            errors.append("rawArchiveRetained")
    if value["state"] == "completed":
        present = uuid_set([item["objectID"] for item in objects])
        if not uuid_set(context.get("requiredObjectIDs", [])) <= present:
            errors.append("deletionInventoryIncomplete")
        if context.get("activeProducerIDs"):
            errors.append("deletionProducersActive")
        if any(item["state"] not in ("deleted", "rebuilt", "kept") for item in objects):
            errors.append("deletionIncomplete")
    return errors


def validate(definition, value, context=None):
    """Return deterministic error codes; absence of context is not proof of IO."""
    context = context or {}
    handlers = {"completeness": _completeness, "preflight": _preflight,
                "candidate": _candidate, "adoption": _adoption,
                "history": _history, "deletion": _deletion}
    if definition == "transcriptEvidence":
        errors = _completeness(value["completeness"], context)
        errors.extend(_bounds_errors([item["range"] for item in value["audioAvailability"]["sources"]]))
        if "source" in context and not source_equal(value["source"], context["source"]):
            errors.append("evidenceSourceMismatch")
        return sorted(set(errors))
    if definition == "observedRange":
        return sorted(set(range_errors(value["range"]) + _evidence_errors(value)))
    if definition == "sampleBounds":
        return sorted(set(range_errors(value)))
    if definition == "processingScope":
        return sorted(set(range_errors(value["range"])))
    if definition in handlers:
        return sorted(set(handlers[definition](value, context)))
    return []
