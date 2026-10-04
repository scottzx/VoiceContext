"""Reference business checks for the unapproved C00 Reminder proposal.

This module validates fixtures only. It is not a production confirmation,
permission, persistence, locking, EventKit, or notification service. External
facts come from the independent fixture context; a payload cannot prove them.
"""

from datetime import date, datetime, timezone
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from recording_ai_contract_common import payload_hash, source_equal, uuid_set


def _instant(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("missingOffset")
    return parsed


def _wall_instants(wall, zone):
    """Round-trip both folds: zero=gap, one=unique, two=ambiguous."""
    instants = set()
    for fold in (0, 1):
        instant = wall.replace(tzinfo=zone, fold=fold).astimezone(timezone.utc)
        if instant.astimezone(zone).replace(tzinfo=None) == wall:
            instants.add(instant)
    return instants


def _due_errors(value):
    if value is None:
        return []
    try:
        day = date.fromisoformat(value["date"])
        zone = ZoneInfo(value["timezone"])
        if value["time"] is not None:
            hour, minute = map(int, value["time"].split(":"))
            wall = datetime(day.year, day.month, day.day, hour, minute)
            if len(_wall_instants(wall, zone)) != 1:
                return ["invalidPayload"]
    except (KeyError, TypeError, ValueError, ZoneInfoNotFoundError):
        return ["invalidPayload"]
    return []


def _alarm_errors(value):
    if value is None:
        return []
    try:
        instant = _instant(value["at"])
        zone = ZoneInfo(value["timezone"])
        if instant.utcoffset() != instant.astimezone(zone).utcoffset():
            return ["invalidPayload"]
    except (KeyError, TypeError, ValueError, ZoneInfoNotFoundError):
        return ["invalidPayload"]
    return []


def _payload_errors(value, context):
    errors = _due_errors(value["due"]) + _alarm_errors(value["alarm"])
    if value["title"] != value["title"].strip() or not value["listID"].strip():
        errors.append("invalidPayload")
    target = context.get("targetList")
    if target is not None:
        if target["id"] != value["listID"] or not target["exists"]:
            errors.append("listMissing")
        elif not target["writable"]:
            errors.append("listReadOnly")
    if context.get("fullAccess") is False:
        errors.append("permissionDenied")
    if context.get("toolAllowed") is False:
        errors.append("toolPolicyDenied")
    return errors


def _actual_errors(value):
    errors = []
    for key in ("due", "start"):
        actual = value[key]
        if actual is None:
            continue
        parts = actual["components"]
        timed = any(parts[name] is not None for name in ("hour", "minute", "second", "nanosecond"))
        if actual["hasTime"] != timed:
            errors.append("invalidPayload")
        if parts["calendar"] == "gregorian" and all(parts[name] is not None for name in ("year", "month", "day")):
            try:
                date(parts["year"], parts["month"], parts["day"])
            except ValueError:
                errors.append("invalidPayload")
        if actual["timezone"]["kind"] == "iana":
            try:
                ZoneInfo(actual["timezone"]["identifier"])
            except (ValueError, ZoneInfoNotFoundError):
                errors.append("invalidPayload")
    timed_alarm = any(alarm["structuredLocation"] is None
                      and (alarm["absoluteDate"] is not None or alarm["relativeOffsetSeconds"] is not None)
                      for alarm in value["alarms"])
    if value["hasTimedAlarm"] != timed_alarm:
        errors.append("invalidPayload")
    for alarm in value["alarms"]:
        location = alarm["structuredLocation"]
        if location is not None and (location["latitude"] is None) != (location["longitude"] is None):
            errors.append("invalidPayload")
    expected = value.get("requestID")
    if expected is not None and UUID(expected) != UUID(value["confirmationID"]):
        errors.append("invalidPayload")
    return errors


def _receipt_errors(value, context):
    errors = _actual_errors(value)
    if context.get("readbackSucceeded") is False:
        errors.append("needsReconciliation")
    if context.get("saveSucceeded") is False:
        errors.append("invalidPayload")
    expected = context.get("actualReminder")
    if expected is not None and any(value[name] != expected[name] for name in expected):
        errors.append("invalidPayload")
    requested = context.get("confirmedPayload")
    if requested is not None:
        matches = _matches_payload(value, requested)
        marker = context.get("expectedMarkerURL")
        if marker is not None and value["URL"] != marker:
            matches = False
        if (value["verification"] == "matchesConfirmedPayload") != matches:
            errors.append("invalidPayload")
    return errors


def _matches_payload(actual, requested):
    for name in ("title", "listID", "notes", "priority"):
        if actual[name] != requested[name]:
            return False
    due = requested["due"]
    if due is None:
        if actual["due"] is not None or actual["start"] is not None:
            return False
    else:
        day = date.fromisoformat(due["date"])
        time_parts = [None, None] if due["time"] is None else list(map(int, due["time"].split(":")))
        expected_parts = {"year": day.year, "month": day.month, "day": day.day,
                          "hour": time_parts[0], "minute": time_parts[1],
                          "second": None if due["time"] is None else 0,
                          "nanosecond": None if due["time"] is None else 0,
                          "calendar": "gregorian"}
        for name in ("due", "start"):
            actual_date = actual[name]
            if actual_date is None or actual_date["components"] != expected_parts:
                return False
            if actual_date["timezone"]["kind"] != "iana" or actual_date["timezone"]["identifier"] != due["timezone"]:
                return False
    alarm = requested["alarm"]
    if alarm is None:
        return not actual["alarms"]
    return (len(actual["alarms"]) == 1 and actual["alarms"][0]["structuredLocation"] is None
            and actual["alarms"][0]["absoluteDate"] is not None
            and _instant(actual["alarms"][0]["absoluteDate"]) == _instant(alarm["at"]))


def _confirmation_errors(value, context):
    errors = _payload_errors(value["payload"], context)
    if value["payloadHash"] != payload_hash(value):
        errors.append("payloadConflict")
    if context.get("existingPayloadHash", value["payloadHash"]) != value["payloadHash"]:
        errors.append("payloadConflict")
    expected_source = context.get("expectedSource")
    if expected_source is not None and not source_equal(value["source"], expected_source):
        errors.append("sourceUnavailable")
    known_segments = context.get("sourceSegmentIDs")
    for citation in value["citations"]:
        if not source_equal(value["source"], citation["source"]):
            errors.append("sourceUnavailable")
        ids = uuid_set(citation["segmentIDs"])
        if len(ids) != len(citation["segmentIDs"]):
            errors.append("invalidPayload")
        if known_segments is not None and not ids.issubset(uuid_set(known_segments)):
            errors.append("sourceUnavailable")
        if "startSample" in citation and citation["endSample"] <= citation["startSample"]:
            errors.append("invalidPayload")
    state = value["state"]
    created = _instant(value["createdAt"])
    confirmed = _instant(value["confirmedAt"]) if value["confirmedAt"] is not None else None
    attempted = _instant(value["attemptStartedAt"]) if value["attemptStartedAt"] is not None else None
    if confirmed is not None and created > confirmed:
        errors.append("invalidPayload")
    if attempted is not None and (confirmed is None or confirmed > attempted):
        errors.append("invalidPayload")
    receipt = value["receipt"]
    if receipt is not None:
        errors.extend(_receipt_errors(receipt, {**context, "confirmedPayload": value["payload"]}))
        if UUID(receipt["confirmationID"]) != UUID(value["confirmationID"]) or UUID(receipt["actionID"]) != UUID(value["actionID"]):
            errors.append("identityConflict")
        if receipt["reminderID"] != value["reminderID"]:
            errors.append("identityConflict")
    if state == "saving" and (context.get("intentPersisted") is False or context.get("exclusiveReservation") is False):
        errors.append("journalUnavailable")
    if context.get("saveAttempted") is True and state == "failedBeforeSave":
        errors.append("needsReconciliation")
    if context.get("priorState") in ("saving", "needsReconciliation", "saved", "savedWithDifferences") and state in ("confirmed", "failedBeforeSave", "cancelled"):
        errors.append("needsReconciliation")
    if context.get("sourceDeleted") is True and state in ("prepared", "confirmed", "failedBeforeSave"):
        errors.append("sourceUnavailable")
    if context.get("attemptCreate") is True:
        if state == "prepared" or context.get("trustedConfirmation") is False:
            errors.append("invalidPayload")
        elif state not in ("confirmed", "failedBeforeSave"):
            errors.append("needsReconciliation")
        if context.get("priorState") in ("saving", "needsReconciliation", "saved", "savedWithDifferences"):
            errors.append("needsReconciliation")
    existing_binding = context.get("existingActionBinding")
    if existing_binding is not None and UUID(existing_binding) != UUID(value["confirmationID"]):
        errors.append("identityConflict")
    return errors


def validate(definition, value, context):
    """Return reference error codes after JSON Schema has accepted the value.

    Missing context means the external condition was not assessed, never that
    this fixture module has granted production permission or proved no write.
    """
    context = context or {}
    try:
        if definition == "due":
            errors = _due_errors(value)
        elif definition == "alarm":
            errors = _alarm_errors(value)
        elif definition == "payload":
            errors = _payload_errors(value, context)
        elif definition == "confirmation":
            errors = _confirmation_errors(value, context)
        elif definition in ("receipt", "actualReminder"):
            errors = _receipt_errors(value, context)
        elif definition == "externalObservation":
            errors = _actual_errors(value["reminder"]) if value["reminder"] is not None else []
            if value["observedState"] == "deleted" and not context.get("deletionEvidenceVerified", False):
                errors.append("identityConflict")
            if context.get("attemptCreate") is True:
                errors.append("needsReconciliation")
            expected = context.get("actualReminder")
            if expected is not None and value["reminder"] != expected:
                errors.append("invalidPayload")
        elif definition == "minimalIdentity":
            errors = ["sourceUnavailable"] if context.get("attemptCreate") is True else []
        else:
            errors = []
    except (KeyError, TypeError, ValueError, OverflowError):
        errors = ["invalidPayload"]
    return list(dict.fromkeys(errors))
