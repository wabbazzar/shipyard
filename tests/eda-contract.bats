#!/usr/bin/env bats

setup() {
  SKILL="$BATS_TEST_DIRNAME/../skills/eda/SKILL.md"
  METHODS="$BATS_TEST_DIRNAME/../skills/eda/references/methods.md"
  UI_SKILL="$BATS_TEST_DIRNAME/../skills/ui-design/SKILL.md"
}

@test "guard: the established shared-skill frontmatter precedent is present" {
  [ -f "$UI_SKILL" ]
  grep -Fxq 'roles: [design, build, release, human]' "$UI_SKILL"
  grep -Fxq 'disposition: adapted' "$UI_SKILL"
  grep -Fxq 'kind: shared' "$UI_SKILL"
}

@test "eda is a discoverable shared skill with project-aware frontmatter" {
  [ -f "$SKILL" ]
  grep -Fxq 'name: eda' "$SKILL"
  grep -Fxq 'roles: [design, build, release, human]' "$SKILL"
  grep -Fxq 'disposition: adapted' "$SKILL"
  grep -Fxq 'kind: shared' "$SKILL"
  grep -Fq 'exploratory data analysis' "$SKILL"
}

@test "entrypoint is finished, neutral, and routes one focused method reference" {
  [ -f "$METHODS" ]
  grep -Fq '[references/methods.md](references/methods.md)' "$SKILL"
  ! grep -Eqi 'TODO|TBD|placeholder|Maydown|Aurora|FPY|Streamlit' "$SKILL" "$METHODS"
  ! grep -Eqi 'always use (linear regression|a decision tree)|must use (linear regression|a decision tree)' "$SKILL" "$METHODS"
}

@test "workflow starts with a declared question and reproducibility record" {
  grep -Fq 'question or decision' "$SKILL"
  grep -Fq 'typed schema' "$SKILL"
  grep -Fq 'population and slice' "$SKILL"
  grep -Fq 'privacy constraints' "$SKILL"
  grep -Fq 'source fingerprint' "$SKILL"
  grep -Fq 'software versions' "$SKILL"
  grep -Fq 'seed' "$SKILL"
}

@test "every result is tied to backing evidence and explicit absence" {
  grep -Fq 'backing frame' "$SKILL"
  grep -Fq 'missing and excluded' "$SKILL"
  grep -Fq 'method and parameters' "$SKILL"
  grep -Fq 'unavailable' "$SKILL"
  grep -Fq 'Never invent, silently impute, or silently drop' "$SKILL"
}

@test "typed profiles cover required numeric and categorical evidence" {
  for term in count missing distinct mean median mode 'standard deviation' min max p95 skew kurtosis; do
    grep -Fqi "$term" "$SKILL" "$METHODS"
  done
  grep -Fq 'mode frequency' "$SKILL" "$METHODS"
  grep -Fq 'rare-level' "$SKILL" "$METHODS"
  grep -Fq 'units' "$SKILL" "$METHODS"
}

@test "distribution and relationship guidance exposes eligibility and pair support" {
  grep -Fq 'histogram' "$SKILL" "$METHODS"
  grep -Fq 'ECDF' "$SKILL" "$METHODS"
  grep -Fq 'KDE' "$SKILL" "$METHODS"
  grep -Fq 'constant' "$SKILL" "$METHODS"
  grep -Fq 'pair counts' "$SKILL" "$METHODS"
  grep -Fq 'missing-data policy' "$SKILL" "$METHODS"
  grep -Fq 'covariance' "$SKILL" "$METHODS"
  grep -Fq 'correlation' "$SKILL" "$METHODS"
}

@test "feature recommendations are ranked decisions rather than importance claims" {
  for term in eligibility leakage missingness association redundancy collinearity recommended rejected; do
    grep -Fqi "$term" "$SKILL" "$METHODS"
  done
  grep -Fq 'ranked evidence table' "$SKILL" "$METHODS"
  grep -Fq 'causal' "$SKILL" "$METHODS"
}

@test "interpretable models and statistical tests expose uncertainty and limits" {
  for term in baseline 'split or resampling' 'actual versus predicted' residual error hypothesis assumptions 'effect size' uncertainty multiplicity; do
    grep -Fqi "$term" "$SKILL" "$METHODS"
  done
  grep -Fq 'p-value' "$SKILL" "$METHODS"
  grep -Fq 'target type' "$SKILL" "$METHODS"
}

@test "interpretations are deterministic and claims remain correctly separated" {
  grep -Fq 'deterministic interpretation' "$SKILL"
  grep -Fq 'displayed values' "$SKILL"
  grep -Fq 'descriptive association' "$SKILL"
  grep -Fq 'inferential evidence' "$SKILL"
  grep -Fq 'prediction' "$SKILL"
  grep -Fq 'causal' "$SKILL"
  grep -Fq 'free-form' "$SKILL"
}

@test "UI-bearing EDA requires rendered and backing-value proof" {
  for term in contrast keyboard focus scrolling overflow responsive viewport; do
    grep -Fqi "$term" "$SKILL"
  done
  grep -Fq 'rendered' "$SKILL"
  grep -Fq 'backing values' "$SKILL"
}

@test "synthetic mixed-type planning fixture reports honest unavailable states" {
  local fixture="$BATS_TEST_TMPDIR/mixed.csv"
  cat >"$fixture" <<'CSV'
record,measure,constant,segment,outcome
r1,1,5,alpha,
r2,2,5,alpha,10
r3,,5,beta,
r4,4,5,,
CSV

  run python3 - "$fixture" "$SKILL" <<'PY'
import csv
import json
import statistics
import sys
from pathlib import Path

source, skill_path = sys.argv[1:]
rows = list(csv.DictReader(open(source, newline="", encoding="utf-8")))
skill = Path(skill_path).read_text(encoding="utf-8")
required = ["backing frame", "KDE", "unavailable", "target type", "effect size"]
assert all(term in skill for term in required), "skill cannot support fixture plan"

numeric = ("measure", "constant", "outcome")
profiles = []
distributions = []
for column in numeric:
    values = [float(row[column]) for row in rows if row[column] != ""]
    profiles.append({
        "column": column,
        "type": "numeric",
        "n": len(values),
        "missing": len(rows) - len(values),
    })
    variance = statistics.variance(values) if len(values) > 1 else None
    if len(values) < 5:
        kde = {"status": "unavailable", "reason": f"n={len(values)} < declared minimum 5"}
    elif variance == 0:
        kde = {"status": "unavailable", "reason": "constant values"}
    else:
        kde = {"status": "available", "reason": "n and variance support estimation"}
    distributions.append({"column": column, "kde": kde})

segment = [row["segment"] for row in rows if row["segment"]]
profiles.append({
    "column": "segment",
    "type": "categorical",
    "n": len(segment),
    "missing": len(rows) - len(segment),
    "distinct": len(set(segment)),
})
target_n = next(item["n"] for item in profiles if item["column"] == "outcome")
plan = {
    "backing_frame": {"source": Path(source).name, "rows": len(rows)},
    "profiles": profiles,
    "distributions": distributions,
    "relationships": {"status": "unavailable", "reason": "fewer than two complete target pairs"},
    "feature_recommendations": {"status": "unavailable", "reason": "target support is insufficient"},
    "model": {"status": "unavailable", "reason": f"only {target_n} observed target value"},
    "test": {"status": "unavailable", "reason": "group outcome samples are insufficient"},
    "interpretation": "Outcome model unavailable: 1 observed value; no estimate reported.",
}
print(json.dumps(plan, sort_keys=True))
PY
  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys
plan = json.loads(sys.argv[1])
assert plan["backing_frame"] == {"rows": 4, "source": "mixed.csv"}
assert {p["type"] for p in plan["profiles"]} == {"numeric", "categorical"}
assert all(d["kde"]["status"] == "unavailable" for d in plan["distributions"])
assert plan["model"]["status"] == "unavailable"
assert plan["test"]["status"] == "unavailable"
assert plan["feature_recommendations"]["status"] == "unavailable"
assert plan["interpretation"].endswith("no estimate reported.")
PY
}
