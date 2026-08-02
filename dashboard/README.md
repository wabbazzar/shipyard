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

`graphs` is the canonical visualization contract; the legacy `topology` object
remains additive compatibility data. The first graph is fleet architecture and
uses only declared role/skill edges plus the controlled delivery outcome;
telemetry-only skill observations cannot add or replace architecture nodes.
Each installed, named fleet project gets its own runtime graph. Event project
IDs and labels are accepted only when they resolve to that installed inventory;
ambiguous, unknown, or invalid claims stay in the explicit unattributed graph.
An otherwise projectless event may inherit scope only through an unambiguous
explicit run ID whose project was established by another event in that run.
Delivery graphs use explicit proposal, incident, work, upstream-work, run, and
recorded outcome identifiers only. They never infer lineage from timestamps,
titles, paths, service-name prefixes, or prose;
controlled `missing_stage` nodes make absent ask, ticket, pull-request, deploy,
or usage evidence visible.

Every graph supplies its scope, nodes, exact edges, deterministic Kahn `ranks`,
state, reasons, evidence counts, and limitations. IDs and endpoints are unique,
every edge advances one or more ranks, and project graphs reject cross-project
nodes. Bounds are 32 nodes/64 edges for architecture, 8/8 for each project
runtime graph, and 12/16 for each of at most 50 delivery graphs. The browser
draws one SVG path per supplied edge and renders the same edge set as a semantic
connection table; positional adjacency is not a connection.

Repeated observations of the same supplied edge retain the total evidence
count and the first 20 distinct evidence IDs in event order. Rejected delivery
graphs report only a controlled failure class (`cycle`, `dangling_endpoint`,
`duplicate_id`, `project_isolation`, `bound`, or `invalid`); event content and
validator detail never enter public limitations.

`metadata.source_revision` is captured when the server starts. The digest
covers the dashboard producer and static assets, the inspector entry point and
implementation, the delegation reporter, and the loaded topology data. Direct
content checks detect producer drift across later inspection refreshes and
report the changed digest with `source_state: modified`. Requests perform no
provenance Git, shell, or network work, and an observed after-start change is
never relabeled clean until the server restarts.

A branch or open pull request is not evidence that an installed dashboard is
running that code. `source_revision`, `source_state`, and `source_digest`
describe the checkout and producer assets captured by the running server. A
Python producer change requires the installed service to be restarted from the
intended checkout; a modified digest makes that mismatch visible meanwhile.
