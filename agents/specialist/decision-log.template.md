# <subsystem> — decision log

> The living memory of one subsystem. The specialist role reads this before
> every review and appends to it whenever a review or reproduction settles
> something new. Keep entries dated and evidence-bearing — an unsourced claim
> here is worse than a gap. Replace every `<placeholder>` below; delete this
> blockquote once the log has real content.

## Objectives

What this subsystem is *for* — the one or two outcomes it must deliver, stated
concretely enough that a proposed change can be judged against them.

- <objective — e.g. "keep p99 request latency under <N>ms for payloads < <N>KB">
- <objective>

## Choices & rationale

The decisions that are settled, each with WHY. This is what a fresh context
will otherwise re-litigate.

- **<decision>** — <why it was chosen; what it is measured against>. (<date>)
- **<decision>** — <rationale>. (<date>)

## Tried & rejected

Approaches that were evaluated and ruled out, with the reason. A change that
re-introduces one of these should cite this section and stop.

- **<approach>** — rejected because <evidence / measured result>. (<date>)
- **<approach>** — rejected because <reason>. (<date>)

## Invariants

Properties that must hold. Breaking one is a `block`, not a preference.

- <invariant — e.g. "no write path runs without the <X> guard">
- <invariant>

## Open tensions

Unresolved trade-offs the subsystem is currently living with — not yet a
decision, but the next reviewer should know they exist.

- <tension — e.g. "<A> favours throughput, <B> favours simplicity; unresolved">
- <tension>
