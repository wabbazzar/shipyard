# Operator schema-v1 producer contract

`GET /api/operator?window=24h|7d|30d` is additive within schema v1. Clients
must preserve core order and treat unknown members and enum values as
unavailable, never healthy.

Every promise carries controlled `reason_code`, `reason`, `impact`, and
`action` fields. Every fleet role node carries the same explanation fields,
an explicit fleet `scope`, a named `reduction_rule`, and its
`constituent_projects`. `topology.runtime_nodes` keys lifecycle evidence by
one installed `project_id` and role. Runtime terminal reasons are restricted to
the producer whitelist; `abort` is a recorded early stop and is not presented
as an outage.

`metadata.scope` names the current-user fleet population without exposing
paths. Each project has separate inspection and event coverage; unattributed
and ambiguous event counts remain in a separate bucket. The globally bounded
outcome event page does not bound project lifecycle observations. Runtime
lifecycle collection has separate finite scan, identity, total-row, and
per-identity bounds. Hitting one is reported through metadata and the
`runtime_lifecycle` coverage row rather than silently dropping evidence.

A project-role runtime node reduces to one controlling service identity: the
worst known service state, with deterministic recency tie-breaking. Its
terminal fields, activity, counts, and evidence all come from that same
service; sibling-service rows are omitted and explicitly limited.

`metadata.source_revision` is captured when the server starts. The digest
covers the dashboard producer and static assets, the inspector entry point and
implementation, the delegation reporter, and the loaded topology data. Direct
content checks detect producer drift across later inspection refreshes and
report the changed digest with `source_state: modified`. Requests perform no
provenance Git, shell, or network work, and an observed after-start change is
never relabeled clean until the server restarts.
