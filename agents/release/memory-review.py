#!/usr/bin/env python3
"""Validate exact-diff project-memory reviews and their reusable receipts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any


SEVERITIES = {"note": 1, "warn": 2, "block": 3}
DISPOSITIONS = {
    "applies",
    "requires_evidence",
    "falsified",
    "informational",
    "superseded",
}
HEX64 = re.compile(r"^[0-9a-f]{64}$")
RULE_ID = re.compile(r"^[A-Z][A-Z0-9_-]{1,63}$")
RFC3339_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
IMPLICIT_IDENTITY = "<implicit-unresolved>"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    return digest(path.read_bytes()) if path.is_file() else digest(b"")


def file_identity(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise ValueError(f"identity input must not be a symlink: {path}")
    if not path.exists():
        return {"state": "missing", "digest": None, "bytes": None}
    if not path.is_file():
        raise ValueError(f"identity input must be a regular non-symlink file: {path}")
    data = path.read_bytes()
    return {"state": "present", "digest": digest(data), "bytes": len(data)}


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path.name} must contain one JSON object")
    return value


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
        parent_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(name)
        except OSError:
            pass
        raise


def diff_paths(text: str, project: Path) -> list[str]:
    paths: list[str] = []
    root_forms = {str(project.absolute()), str(project.resolve())}
    root_forms |= {item[len("/private") :] for item in tuple(root_forms) if item.startswith("/private/")}
    prior = ""
    for line in text.splitlines():
        if line.startswith("--- "):
            prior = line[4:].split("\t", 1)[0]
            continue
        if not line.startswith("+++ "):
            continue
        raw = line[4:].split("\t", 1)[0]
        if raw == "/dev/null":
            raw = prior
        prior = ""
        if raw.startswith(("a/", "b/")):
            raw = raw[2:]
        for root in sorted(root_forms, key=len, reverse=True):
            if raw.startswith(root + "/"):
                raw = raw[len(root) + 1 :]
                break
        if raw.startswith("/"):
            raise ValueError("diff contains an absolute path outside the project")
        parsed = PurePosixPath(raw)
        if not raw or "\\" in raw or any(part in {"", ".", ".."} for part in parsed.parts):
            raise ValueError("diff contains an unsafe path")
        if raw and raw not in paths:
            paths.append(raw)
    return paths


def citation(candidate: dict[str, Any], ledger_path: str, line_count: int) -> str:
    value = candidate.get("citation")
    if not isinstance(value, dict):
        raise ValueError("candidate citation is missing")
    ledger = value.get("ledger_path")
    line = value.get("line")
    if (
        ledger != ledger_path
        or not isinstance(line, int)
        or line < 1
        or line > line_count
    ):
        raise ValueError("candidate citation is invalid")
    return f"{ledger}:{line}"


def requested_reviewer(args: argparse.Namespace) -> dict[str, Any]:
    harness = args.harness.strip()
    if not harness:
        raise ValueError("reviewer harness must be explicit")
    model = args.model.strip()
    provider = args.provider.strip()
    return {
        "harness": harness,
        "model": model or IMPLICIT_IDENTITY,
        "provider": provider or IMPLICIT_IDENTITY,
        "model_explicit": bool(model),
        "provider_explicit": bool(provider),
        "contract_version": "rules-memory-review-v1",
    }


def make_context(args: argparse.Namespace) -> dict[str, Any]:
    query = load_json(args.query_file)
    diff_bytes = args.diff_file.read_bytes()
    project = args.project.resolve()
    if query.get("schema_version") != 1 or query.get("state") != "ready" or query.get("valid") is not True:
        raise ValueError("memory query is not ready and valid")
    if query.get("errors") != []:
        raise ValueError("ready memory query cannot carry errors")
    if query.get("configured") is not True or query.get("mode") not in {"advisory", "required"}:
        raise ValueError("memory query policy binding is invalid")
    if not isinstance(query.get("ledger_path"), str) or not query["ledger_path"]:
        raise ValueError("memory query ledger path is invalid")
    if not isinstance(query.get("ledger_digest"), str) or not HEX64.fullmatch(query["ledger_digest"]):
        raise ValueError("memory query ledger digest is invalid")
    for key in ("record_count", "active_count", "superseded_count"):
        if not isinstance(query.get(key), int) or query[key] < 0:
            raise ValueError(f"memory query {key} is invalid")
    if query["active_count"] + query["superseded_count"] != query["record_count"]:
        raise ValueError("memory query record counts are inconsistent")
    if query.get("project_root") != str(project):
        raise ValueError("memory query belongs to another project")
    ledger_relative = PurePosixPath(query["ledger_path"])
    if ledger_relative.is_absolute() or any(
        part in {"", ".", ".."} for part in ledger_relative.parts
    ):
        raise ValueError("memory query ledger path is unsafe")
    ledger_file = project.joinpath(*ledger_relative.parts)
    if ledger_file.is_symlink() or not ledger_file.is_file():
        raise ValueError("memory query ledger source is unavailable")
    try:
        ledger_file.resolve().relative_to(project)
    except ValueError as exc:
        raise ValueError("memory query ledger source escapes the project") from exc
    ledger_bytes = ledger_file.read_bytes()
    ledger_line_count = len(ledger_bytes.splitlines())
    if ledger_line_count != query["record_count"]:
        raise ValueError("memory query ledger line layout is inconsistent")
    ledger_layout_digest = digest(ledger_bytes)
    query_input = query.get("query_input")
    if (
        not isinstance(query_input, dict)
        or query_input.get("kind") != "diff"
        or query_input.get("digest") != digest(diff_bytes)
        or query_input.get("bytes") != len(diff_bytes)
    ):
        raise ValueError("memory query is not bound to the exact diff")
    candidates = query.get("candidates")
    count = query.get("candidate_count")
    limits = query.get("limits")
    if not isinstance(candidates, list) or count != len(candidates) or not isinstance(limits, dict):
        raise ValueError("memory query candidate shape is invalid")
    if not isinstance(query.get("query_features"), dict):
        raise ValueError("memory query features are invalid")
    for key in ("max_channel_candidates", "max_fused_candidates", "max_prompt_records"):
        if not isinstance(limits.get(key), int) or limits[key] < 1:
            raise ValueError("memory query limits are invalid")
    if count > limits["max_fused_candidates"]:
        raise ValueError("memory query exceeds its fused-candidate bound")
    maximum = limits.get("max_prompt_records")
    if not isinstance(maximum, int) or maximum < 1:
        raise ValueError("memory query prompt limit is invalid")
    ids: list[str] = []
    index = query.get("index")
    if isinstance(index, dict) and index.get("source_layout_digest") != ledger_layout_digest:
        raise ValueError("memory index does not match the validated ledger layout")
    for candidate in candidates:
        if (
            not isinstance(candidate, dict)
            or not isinstance(candidate.get("id"), str)
            or not RULE_ID.fullmatch(candidate["id"])
        ):
            raise ValueError("memory query candidate is invalid")
        if candidate["id"] in ids:
            raise ValueError("memory query contains duplicate candidate IDs")
        if candidate.get("severity") not in SEVERITIES or candidate.get("status") != "active":
            raise ValueError("memory query candidate severity/status is invalid")
        channels = candidate.get("channels")
        if not isinstance(channels, dict) or not channels:
            raise ValueError("memory query candidate channels are invalid")
        for name, explanation in channels.items():
            if name not in {"exact", "fts", "vector"} or not isinstance(explanation, dict):
                raise ValueError("memory query channel explanation is invalid")
        citation(candidate, query["ledger_path"], ledger_line_count)
        sources = candidate.get("citation", {}).get("sources")
        if not isinstance(sources, list):
            raise ValueError("memory query candidate sources are invalid")
        ids.append(candidate["id"])
    review = candidates[:maximum]
    if candidates and not isinstance(index, dict):
        raise ValueError("memory query candidates require an index identity")
    if isinstance(index, dict):
        for key in ("digest", "source_layout_digest"):
            if not isinstance(index.get(key), str) or not HEX64.fullmatch(index[key]):
                raise ValueError(f"memory index {key} is invalid")
        if not isinstance(index.get("schema_version"), int) or index["schema_version"] < 1:
            raise ValueError("memory index schema version is invalid")
        for key in ("normalizer_version", "vector_backend", "fts_backend", "shipyard_version"):
            if not isinstance(index.get(key), str) or not index[key]:
                raise ValueError(f"memory index {key} is invalid")
    config_identity = file_identity(args.config)
    gates_identity = file_identity(args.gates)
    binding = {
        "project_root": str(project),
        "project_identity": digest(str(project).encode()),
        "diff_digest": digest(diff_bytes),
        "base_identity": args.base,
        "diff_mode": args.diff_mode,
        "ledger_digest": query.get("ledger_digest"),
        "source_layout_digest": ledger_layout_digest,
        "ledger_line_count": ledger_line_count,
        "index_digest": index.get("digest") if isinstance(index, dict) else None,
        "index_schema_version": index.get("schema_version") if isinstance(index, dict) else None,
        "normalizer_version": index.get("normalizer_version") if isinstance(index, dict) else None,
        "vector_backend": index.get("vector_backend") if isinstance(index, dict) else None,
        "config_identity": config_identity,
        "config_digest": config_identity["digest"],
        "config_state": config_identity["state"],
        "gates_identity": gates_identity,
        "gates_digest": gates_identity["digest"],
        "gates_state": gates_identity["state"],
        "policy_mode": query.get("mode"),
        "query_features": query.get("query_features"),
        "limits": limits,
        "reviewer": requested_reviewer(args),
    }
    candidate_evidence = []
    for candidate in candidates:
        candidate_evidence.append(
            {
                "id": candidate["id"],
                "severity": candidate.get("severity"),
                "status": candidate.get("status"),
                "citation": citation(candidate, query["ledger_path"], ledger_line_count),
                "sources": candidate.get("citation", {}).get("sources", []),
                "channels": candidate.get("channels", {}),
                "excerpt": candidate.get("excerpt", {}),
            }
        )
    packet = candidate_evidence[:maximum]
    prompt = """HISTORICAL RULES MEMORY REVIEW

This is a fresh, review-only invocation. Do not write files or mutate state. Retrieval is candidate
generation, not proof. Decide every REVIEW SET rule against the EXACT CURRENT DIFF and cite only its
provided ledger citation. Emit exactly one disposition per review-set ID, zero or one finding for
that ID, then exactly one TOKENS_HINT sentinel. No prose or Markdown.

Allowed lines:
disposition|RULE_ID|applies|requires_evidence|falsified|informational|superseded is NOT a literal form.
Use: disposition|RULE_ID|STATE|CURRENT_PATH|LEDGER_PATH:LINE|one-line current evidence
Finding: block|CURRENT_PATH|RULE_ID|one-line finding (warn and note also allowed)
TOKENS_HINT|<none>

Rules: unknown IDs/paths/citations are forbidden. applies or requires_evidence must include exactly
one finding at the ledger severity. falsified, informational, and superseded must include none.

REVIEW SET JSON:
""" + json.dumps(packet, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n\nEXACT CURRENT DIFF:\n" + diff_bytes.decode("utf-8")
    return {
        "schema_version": 1,
        "binding": binding,
        "retrieved_ids": ids,
        "review_set_ids": [item["id"] for item in review],
        "omitted_ids": ids[maximum:],
        "review_set": packet,
        "candidate_evidence": candidate_evidence,
        "diff_paths": diff_paths(diff_bytes.decode("utf-8"), project),
        "prompt": prompt,
        "prompt_digest": digest(prompt.encode()),
    }


def cmd_prepare(args: argparse.Namespace) -> int:
    context = make_context(args)
    atomic_json(args.output, context)
    sys.stdout.write(context["prompt"])
    return 0


def validate_cache(args: argparse.Namespace) -> int:
    context = load_json(args.context)
    receipt = load_json(args.receipt)
    if receipt.get("schema_version") != 1 or receipt.get("state") != "complete":
        return 1
    if receipt.get("binding") != context.get("binding"):
        return 1
    for key in (
        "retrieved_ids",
        "review_set_ids",
        "omitted_ids",
        "candidate_evidence",
        "prompt_digest",
    ):
        if receipt.get(key) != context.get(key):
            return 1
    reviewer = receipt.get("reviewer")
    if not isinstance(reviewer, dict) or reviewer.get("requested") != context["binding"]["reviewer"]:
        return 1
    requested = reviewer["requested"]
    if requested.get("model_explicit") is not True or requested.get("provider_explicit") is not True:
        return 1
    invocation = reviewer.get("invocation")
    resolved = reviewer.get("resolved")
    if not isinstance(invocation, dict) or not isinstance(resolved, dict):
        return 1
    if context["review_set_ids"]:
        if (
            invocation.get("state") != "complete"
            or not isinstance(invocation.get("identity"), str)
            or not HEX64.fullmatch(invocation["identity"])
            or invocation.get("rc") != 0
            or invocation.get("identity_source") != "spawn-dispatcher-v1"
            or not isinstance(invocation.get("tokens"), int)
            or invocation["tokens"] < 0
            or not isinstance(invocation.get("started_at"), str)
            or not RFC3339_UTC.fullmatch(invocation["started_at"])
            or not isinstance(invocation.get("ended_at"), str)
            or not RFC3339_UTC.fullmatch(invocation["ended_at"])
            or invocation["started_at"] > invocation["ended_at"]
            or not isinstance(resolved.get("model"), str)
            or not resolved["model"]
            or not isinstance(resolved.get("provider"), str)
            or not resolved["provider"]
            or resolved["model"] != requested.get("model")
            or resolved["provider"] != requested.get("provider")
        ):
            return 1
    elif invocation != {
        "state": "not_required",
        "identity": "rules-memory-zero-candidate-v1",
        "started_at": None,
        "ended_at": None,
        "tokens": 0,
        "rc": None,
        "identity_source": "not_applicable",
    }:
        return 1
    delivery = receipt.get("delivery")
    if not isinstance(delivery, dict) or delivery.get("status") not in {"pending", "delivery", "deferred", "deposited"}:
        return 1
    if receipt.get("findings_digest") != file_digest(args.findings):
        return 1
    return 0


def cmd_validate_cache(args: argparse.Namespace) -> int:
    return validate_cache(args)


def receipt_base(context: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "binding": context["binding"],
        "retrieved_ids": context["retrieved_ids"],
        "review_set_ids": context["review_set_ids"],
        "omitted_ids": context["omitted_ids"],
        "candidate_evidence": context["candidate_evidence"],
        "prompt_digest": context["prompt_digest"],
        "reviewer": {
            "requested": context["binding"]["reviewer"],
            "resolved": {"model": None, "provider": None},
            "invocation": {
                "state": "not_started",
                "identity": None,
                "started_at": None,
                "ended_at": None,
                "tokens": 0,
                "rc": None,
                "identity_source": None,
            },
        },
    }


def parse_response(context: dict[str, Any], response: str) -> tuple[list[dict[str, str]], list[dict[str, str]], list[str]]:
    allowed_ids = context["review_set_ids"]
    if (
        not isinstance(allowed_ids, list)
        or len(set(allowed_ids)) != len(allowed_ids)
        or any(not isinstance(item, str) or not RULE_ID.fullmatch(item) for item in allowed_ids)
    ):
        raise ValueError("review set IDs are invalid")
    review_set = context.get("review_set")
    if not isinstance(review_set, list) or [item.get("id") for item in review_set if isinstance(item, dict)] != allowed_ids:
        raise ValueError("review set packet does not match its IDs")
    for item in review_set:
        if item.get("severity") not in SEVERITIES or item.get("status") != "active":
            raise ValueError("review set severity/status is invalid")
    by_id = {item["id"]: item for item in context["review_set"]}
    paths = set(context["diff_paths"])
    dispositions: dict[str, dict[str, str]] = {}
    findings: dict[str, dict[str, str]] = {}
    sentinel = 0
    for raw in response.splitlines():
        if not raw:
            continue
        if raw == "TOKENS_HINT|<none>":
            sentinel += 1
            continue
        parts = raw.split("|")
        if len(parts) == 6 and parts[0] == "disposition":
            _, rule_id, state, path, cite, evidence = (item.strip() for item in parts)
            if rule_id not in by_id or rule_id in dispositions or state not in DISPOSITIONS:
                raise ValueError("invalid or duplicate disposition")
            if path not in paths or cite != by_id[rule_id]["citation"] or not evidence:
                raise ValueError("disposition path/citation/evidence is invalid")
            dispositions[rule_id] = {"id": rule_id, "state": state, "path": path, "citation": cite, "evidence": evidence}
            continue
        if len(parts) == 4 and parts[0] in SEVERITIES:
            severity, path, rule_id, message = (item.strip() for item in parts)
            if rule_id not in by_id or rule_id in findings or path not in paths or not message:
                raise ValueError("finding ID/path/message is invalid")
            findings[rule_id] = {"severity": severity, "path": path, "id": rule_id, "message": message}
            continue
        raise ValueError("reviewer output contains an invalid line")
    if sentinel != 1 or set(dispositions) != set(allowed_ids):
        raise ValueError("reviewer output must contain one sentinel and one disposition per ID")
    normalized: list[str] = []
    ordered_findings: list[dict[str, str]] = []
    for rule_id in allowed_ids:
        disposition = dispositions[rule_id]
        finding = findings.get(rule_id)
        if disposition["state"] in {"applies", "requires_evidence"}:
            if finding is None or finding["severity"] != by_id[rule_id]["severity"]:
                raise ValueError("applicable rule requires one ledger-severity finding")
            normalized.append(f'{finding["severity"]}|{finding["path"]}|[{rule_id}] {finding["message"]}')
            ordered_findings.append(finding)
        elif finding is not None:
            raise ValueError("non-applicable disposition cannot emit a finding")
    return [dispositions[item] for item in allowed_ids], ordered_findings, normalized


def cmd_normalize(args: argparse.Namespace) -> int:
    context = load_json(args.context)
    response = args.response.read_text(encoding="utf-8")
    dispositions, findings, normalized = parse_response(context, response)
    output = ("\n".join(normalized) + ("\n" if normalized else "")).encode()
    receipt = receipt_base(context)
    if (
        not RFC3339_UTC.fullmatch(args.started_at)
        or not RFC3339_UTC.fullmatch(args.ended_at)
        or args.started_at > args.ended_at
        or not args.resolved_model.strip()
        or not args.resolved_provider.strip()
        or args.resolved_model.strip() == IMPLICIT_IDENTITY
        or args.resolved_provider.strip() == IMPLICIT_IDENTITY
        or args.rc != 0
        or args.tokens < 0
    ):
        raise ValueError("reviewer invocation identity is invalid or incomplete")
    invocation_material = json.dumps(
        {
            "prompt_digest": context["prompt_digest"],
            "response_digest": digest(response.encode()),
            "requested": context["binding"]["reviewer"],
            "resolved_model": args.resolved_model,
            "resolved_provider": args.resolved_provider,
            "started_at": args.started_at,
            "ended_at": args.ended_at,
            "tokens": args.tokens,
            "rc": args.rc,
            "identity_source": args.identity_source,
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    receipt["reviewer"] = {
        "requested": context["binding"]["reviewer"],
        "resolved": {
            "model": args.resolved_model.strip(),
            "provider": args.resolved_provider.strip(),
        },
        "invocation": {
            "state": "complete",
            "identity": digest(invocation_material),
            "started_at": args.started_at,
            "ended_at": args.ended_at,
            "tokens": args.tokens,
            "rc": args.rc,
            "identity_source": args.identity_source,
        },
    }
    receipt.update(
        state="complete",
        coverage="bounded" if context["omitted_ids"] else "full",
        dispositions=dispositions,
        findings=findings,
        verdict=max((item["severity"] for item in findings), key=lambda item: SEVERITIES[item], default="clean"),
        response_digest=digest(response.encode()),
        findings_digest=digest(output),
        delivery={"status": "pending"},
        reviewed_at=args.ended_at,
    )
    atomic_json(args.receipt, receipt)
    sys.stdout.buffer.write(output)
    return 0


def cmd_zero(args: argparse.Namespace) -> int:
    context = load_json(args.context)
    receipt = receipt_base(context)
    receipt["reviewer"] = {
        "requested": context["binding"]["reviewer"],
        "resolved": {
            "model": context["binding"]["reviewer"]["model"],
            "provider": context["binding"]["reviewer"]["provider"],
        },
        "invocation": {
            "state": "not_required",
            "identity": "rules-memory-zero-candidate-v1",
            "started_at": None,
            "ended_at": None,
            "tokens": 0,
            "rc": None,
            "identity_source": "not_applicable",
        },
    }
    receipt.update(
        state="complete",
        coverage="full",
        dispositions=[],
        findings=[],
        verdict="clean",
        response_digest=None,
        findings_digest=digest(b""),
        delivery={"status": "pending"},
        reviewed_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    atomic_json(args.receipt, receipt)
    return 0


def cmd_degraded(args: argparse.Namespace) -> int:
    context = load_json(args.context)
    receipt = receipt_base(context)
    receipt.update(
        state="degraded",
        coverage="incomplete",
        dispositions=[],
        findings=[],
        verdict="incomplete",
        findings_digest=None,
        error={"code": args.code, "message": args.message[:512]},
        delivery={"status": "not_delivered"},
    )
    atomic_json(args.receipt, receipt)
    return 0


def cmd_degrade_receipt(args: argparse.Namespace) -> int:
    """Mark a complete review degraded without erasing its audit evidence."""
    receipt = load_json(args.receipt)
    binding = receipt.get("binding")
    if (
        receipt.get("schema_version") != 1
        or receipt.get("state") != "complete"
        or not isinstance(binding, dict)
        or not isinstance(binding.get("reviewer"), dict)
    ):
        raise ValueError("only a complete memory receipt can be degraded")
    receipt.update(
        state="degraded",
        error={"code": args.code, "message": args.message[:512]},
        delivery={
            "status": args.delivery_status,
            "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        },
    )
    atomic_json(args.receipt, receipt)
    return 0


def write_degraded_input(
    args: argparse.Namespace, diff_bytes: bytes, query: dict[str, Any]
) -> int:
    project = args.project.resolve()
    index = query.get("index") if isinstance(query.get("index"), dict) else {}
    ledger_digest = query.get("ledger_digest")
    if not isinstance(ledger_digest, str) or not HEX64.fullmatch(ledger_digest):
        ledger_digest = None
    config_identity = file_identity(args.config)
    gates_identity = file_identity(args.gates)
    context = {
        "schema_version": 1,
        "binding": {
            "project_root": str(project),
            "project_identity": digest(str(project).encode()),
            "diff_digest": digest(diff_bytes),
            "base_identity": args.base,
            "diff_mode": args.diff_mode,
            "ledger_digest": ledger_digest,
            "source_layout_digest": index.get("source_layout_digest"),
            "index_digest": index.get("digest"),
            "index_schema_version": index.get("schema_version"),
            "normalizer_version": index.get("normalizer_version"),
            "vector_backend": index.get("vector_backend"),
            "config_identity": config_identity,
            "config_digest": config_identity["digest"],
            "config_state": config_identity["state"],
            "gates_identity": gates_identity,
            "gates_digest": gates_identity["digest"],
            "gates_state": gates_identity["state"],
            "policy_mode": args.mode,
            "query_features": query.get("query_features"),
            "limits": query.get("limits"),
            "reviewer": requested_reviewer(args),
        },
        "retrieved_ids": [],
        "review_set_ids": [],
        "omitted_ids": [],
        "candidate_evidence": [],
        "review_set": [],
        "diff_paths": diff_paths(diff_bytes.decode("utf-8"), project),
        "prompt_digest": digest(b"rules-memory-no-review-prompt-v1"),
    }
    receipt = receipt_base(context)
    receipt.update(
        state="degraded",
        coverage="incomplete",
        dispositions=[],
        findings=[],
        verdict="incomplete",
        findings_digest=None,
        error={"code": args.code, "message": args.message[:512]},
        delivery={"status": "not_delivered"},
    )
    atomic_json(args.receipt, receipt)
    return 0


def cmd_degraded_input(args: argparse.Namespace) -> int:
    query: dict[str, Any] = {}
    if args.query_file.is_file():
        try:
            query = load_json(args.query_file)
        except (OSError, ValueError, json.JSONDecodeError):
            query = {}
    return write_degraded_input(args, args.diff_file.read_bytes(), query)


def cmd_degraded_raw(args: argparse.Namespace) -> int:
    diff_bytes = sys.stdin.buffer.read(4 * 1024 * 1024 + 1)
    if len(diff_bytes) > 4 * 1024 * 1024:
        raise ValueError("raw degraded diff exceeds 4 MiB")
    return write_degraded_input(args, diff_bytes, {})


def cmd_delivery(args: argparse.Namespace) -> int:
    receipt = load_json(args.receipt)
    if receipt.get("schema_version") != 1:
        raise ValueError("receipt schema is invalid")
    delivery = receipt.setdefault("delivery", {})
    delivery["status"] = args.status
    delivery["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    atomic_json(args.receipt, receipt)
    return 0


def cmd_bind_findings(args: argparse.Namespace) -> int:
    receipt = load_json(args.receipt)
    if receipt.get("schema_version") != 1 or receipt.get("state") != "complete":
        raise ValueError("only a complete receipt can bind merged findings")
    receipt["findings_digest"] = file_digest(args.findings)
    atomic_json(args.receipt, receipt)
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare")
    prepare.add_argument("--project", type=Path, required=True)
    prepare.add_argument("--query-file", type=Path, required=True)
    prepare.add_argument("--diff-file", type=Path, required=True)
    prepare.add_argument("--base", required=True)
    prepare.add_argument("--diff-mode", required=True)
    prepare.add_argument("--config", type=Path, required=True)
    prepare.add_argument("--gates", type=Path, required=True)
    prepare.add_argument("--harness", required=True)
    prepare.add_argument("--model", default="")
    prepare.add_argument("--provider", default="")
    prepare.add_argument("--output", type=Path, required=True)
    prepare.set_defaults(func=cmd_prepare)
    cache = commands.add_parser("validate-cache")
    cache.add_argument("--context", type=Path, required=True)
    cache.add_argument("--receipt", type=Path, required=True)
    cache.add_argument("--findings", type=Path, required=True)
    cache.set_defaults(func=cmd_validate_cache)
    normalize = commands.add_parser("normalize")
    normalize.add_argument("--context", type=Path, required=True)
    normalize.add_argument("--response", type=Path, required=True)
    normalize.add_argument("--receipt", type=Path, required=True)
    normalize.add_argument("--resolved-model", required=True)
    normalize.add_argument("--resolved-provider", required=True)
    normalize.add_argument("--started-at", required=True)
    normalize.add_argument("--ended-at", required=True)
    normalize.add_argument("--tokens", type=int, required=True)
    normalize.add_argument("--rc", type=int, required=True)
    normalize.add_argument(
        "--identity-source", choices=("spawn-dispatcher-v1",), required=True
    )
    normalize.set_defaults(func=cmd_normalize)
    zero = commands.add_parser("zero")
    zero.add_argument("--context", type=Path, required=True)
    zero.add_argument("--receipt", type=Path, required=True)
    zero.set_defaults(func=cmd_zero)
    degraded = commands.add_parser("degraded")
    degraded.add_argument("--context", type=Path, required=True)
    degraded.add_argument("--receipt", type=Path, required=True)
    degraded.add_argument("--code", required=True)
    degraded.add_argument("--message", default="")
    degraded.set_defaults(func=cmd_degraded)
    degrade_receipt = commands.add_parser("degrade-receipt")
    degrade_receipt.add_argument("--receipt", type=Path, required=True)
    degrade_receipt.add_argument("--code", required=True)
    degrade_receipt.add_argument("--message", default="")
    degrade_receipt.add_argument(
        "--delivery-status",
        choices=("deposited", "expired", "failed"),
        required=True,
    )
    degrade_receipt.set_defaults(func=cmd_degrade_receipt)
    degraded_input = commands.add_parser("degraded-input")
    degraded_input.add_argument("--project", type=Path, required=True)
    degraded_input.add_argument("--query-file", type=Path, required=True)
    degraded_input.add_argument("--diff-file", type=Path, required=True)
    degraded_input.add_argument("--base", required=True)
    degraded_input.add_argument("--diff-mode", required=True)
    degraded_input.add_argument("--config", type=Path, required=True)
    degraded_input.add_argument("--gates", type=Path, required=True)
    degraded_input.add_argument("--mode", choices=("advisory", "required"), required=True)
    degraded_input.add_argument("--harness", required=True)
    degraded_input.add_argument("--model", default="")
    degraded_input.add_argument("--provider", default="")
    degraded_input.add_argument("--receipt", type=Path, required=True)
    degraded_input.add_argument("--code", required=True)
    degraded_input.add_argument("--message", default="")
    degraded_input.set_defaults(func=cmd_degraded_input)
    degraded_raw = commands.add_parser("degraded-raw")
    degraded_raw.add_argument("--project", type=Path, required=True)
    degraded_raw.add_argument("--base", required=True)
    degraded_raw.add_argument("--diff-mode", required=True)
    degraded_raw.add_argument("--config", type=Path, required=True)
    degraded_raw.add_argument("--gates", type=Path, required=True)
    degraded_raw.add_argument("--mode", choices=("advisory", "required"), required=True)
    degraded_raw.add_argument("--harness", required=True)
    degraded_raw.add_argument("--model", default="")
    degraded_raw.add_argument("--provider", default="")
    degraded_raw.add_argument("--receipt", type=Path, required=True)
    degraded_raw.add_argument("--code", required=True)
    degraded_raw.add_argument("--message", default="")
    degraded_raw.set_defaults(func=cmd_degraded_raw)
    delivery = commands.add_parser("delivery")
    delivery.add_argument("--receipt", type=Path, required=True)
    delivery.add_argument("--status", choices=("pending", "delivery", "deferred", "deposited", "failed", "expired"), required=True)
    delivery.set_defaults(func=cmd_delivery)
    bind = commands.add_parser("bind-findings")
    bind.add_argument("--receipt", type=Path, required=True)
    bind.add_argument("--findings", type=Path, required=True)
    bind.set_defaults(func=cmd_bind_findings)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except (OSError, UnicodeError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(f"memory review invalid: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
