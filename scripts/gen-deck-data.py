#!/usr/bin/env python3
"""Generate docs/shipyard-data.json for the deck.

STRUCTURE is a function of the implementation: which skills exist, which crews
invoke each skill, and each skill's graph kind all come from the skill files'
YAML frontmatter (skills/<id>/SKILL.md) and install.sh's GENERIC_SKILLS line.
Authored PROSE (labels, summaries, details, sources, display-disposition
strings, phase gists, install/adaptation copy, the graph note/roles/edges) is
merged in from docs/deck-editorial.json.

Editing prose in the editorial file cannot leave the structure stale: add a
skill file (+ list it in GENERIC_SKILLS) or flip a `roles:` line in a SKILL.md
and re-running this script updates crew membership and the interdependency
graph automatically.

Round-trip contract: running this script must reproduce docs/shipyard-data.json
byte-for-byte against its committed state. scripts/check-deck-fresh.sh enforces
it.
"""
import collections
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EDITORIAL = os.path.join(REPO, "docs", "deck-editorial.json")
INSTALL_SH = os.path.join(REPO, "install.sh")
SKILLS_DIR = os.path.join(REPO, "skills")
OUT = os.path.join(REPO, "docs", "shipyard-data.json")

# Canonical ordering. The crews are the five loops; `human` is the operator and
# is NOT a crew (it never gets a crew[] block), but it is a graph role.
CREW_ORDER = ["design", "build", "release", "medic", "scribe"]
ROLE_ORDER = ["human"] + CREW_ORDER


def read_generic_skills(path):
    """Extract the skill ids from install.sh's GENERIC_SKILLS= line."""
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'\s*GENERIC_SKILLS="([^"]*)"', line)
            if m:
                return m.group(1).split()
    raise SystemExit("gen-deck-data: GENERIC_SKILLS not found in %s" % path)


def parse_frontmatter(path):
    """Parse the leading `---` YAML block for roles/disposition/kind.

    Frontmatter is deliberately simple: `key: value` scalars and one inline
    list `roles: [a, b, c]`. No third-party YAML dependency.
    """
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    if not lines or lines[0].strip() != "---":
        raise SystemExit("gen-deck-data: %s has no frontmatter" % path)
    fm = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"([A-Za-z_][\w-]*):\s*(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if key not in ("roles", "disposition", "kind"):
            continue
        if key == "roles":
            val = val.strip()
            if val.startswith("[") and val.endswith("]"):
                val = val[1:-1]
            fm["roles"] = [r.strip() for r in val.split(",") if r.strip()]
        else:
            fm[key] = val
    for req in ("roles", "disposition", "kind"):
        if req not in fm:
            raise SystemExit("gen-deck-data: %s frontmatter missing `%s:`" % (path, req))
    return fm


def load_skills():
    """id -> {roles, disposition, kind} from the frontmatter of every skill in
    GENERIC_SKILLS."""
    ids = read_generic_skills(INSTALL_SH)
    skills = collections.OrderedDict()
    for sid in ids:
        p = os.path.join(SKILLS_DIR, sid, "SKILL.md")
        if not os.path.isfile(p):
            raise SystemExit("gen-deck-data: GENERIC_SKILLS lists %s but %s is missing" % (sid, p))
        skills[sid] = parse_frontmatter(p)
    return skills


def member_crews(roles):
    """Which crew[] blocks a skill appears under: its roles intersected with the
    five crews (human excluded), in canonical order."""
    return [c for c in CREW_ORDER if c in roles]


def graph_roles(fm):
    """Roles shown on the interdependency graph node. Front doors are drawn
    hanging off the human operator, so a `frontdoor` kind collapses to [human]
    regardless of which crew also invokes it; every other kind shows its full
    frontmatter roles in canonical order."""
    if fm["kind"] == "frontdoor":
        return ["human"]
    return [r for r in ROLE_ORDER if r in fm["roles"]]


def crew_skill_entry(e):
    """Editorial crew entry -> output crew skill object (drop the _file marker)."""
    return collections.OrderedDict(
        (k, e[k]) for k in ("name", "disposition", "source", "summary", "detail")
    )


def main():
    skills = load_skills()
    with open(EDITORIAL, encoding="utf-8") as f:
        ed = json.load(f, object_pairs_hook=collections.OrderedDict)

    members = {sid: member_crews(fm["roles"]) for sid, fm in skills.items()}

    # Default prose per file-backed skill (first authored occurrence), used only
    # when a frontmatter change places a skill in a crew the editorial has no
    # prose for.
    default_prose = {}
    for c in ed["crew"]:
        for e in c["skills"]:
            fid = e.get("_file")
            if fid and fid not in default_prose:
                default_prose[fid] = crew_skill_entry(e)

    out = collections.OrderedDict()
    out["meta"] = ed["meta"]
    if "cast" in ed:
        out["cast"] = ed["cast"]

    out_crew = []
    for c in ed["crew"]:
        oc = collections.OrderedDict()
        for k in ("id", "name", "was", "loop", "status", "tagline", "headline", "gate"):
            oc[k] = c[k]
        skills_out = []
        authored = set()
        for e in c["skills"]:
            fid = e.get("_file")
            if fid is not None:
                if fid not in skills:
                    raise SystemExit(
                        "gen-deck-data: editorial references unknown skill '%s'" % fid)
                if c["id"] in members[fid]:
                    skills_out.append(crew_skill_entry(e))
                    authored.add(fid)
                # frontmatter dropped this crew from the skill's roles -> omit
            else:
                skills_out.append(e)  # non-file crew capability, passed through
        # frontmatter added this crew but editorial has no prose for it here
        for sid in skills:
            if c["id"] in members[sid] and sid not in authored:
                skills_out.append(default_prose[sid])
        oc["skills"] = skills_out
        out_crew.append(oc)
    out["crew"] = out_crew

    out["phases"] = ed["phases"]
    out["install"] = ed["install"]
    out["adaptation"] = ed["adaptation"]

    g = ed["graph"]
    og = collections.OrderedDict()
    og["note"] = g["note"]
    og["roles"] = g["roles"]
    nodes = []
    for n in g["skills"]:
        fid = n.get("_file")
        node = collections.OrderedDict()
        if fid is not None:
            if fid not in skills:
                raise SystemExit(
                    "gen-deck-data: editorial graph references unknown skill '%s'" % fid)
            node["id"] = fid
            node["label"] = n["label"]
            node["roles"] = graph_roles(skills[fid])
            node["kind"] = skills[fid]["kind"]
        else:
            node["id"] = n["id"]
            node["label"] = n["label"]
            node["roles"] = n["roles"]
            node["kind"] = n["kind"]
        nodes.append(node)
    og["skills"] = nodes
    og["edges"] = g["edges"]
    out["graph"] = og

    if "glossary" in ed:
        out["glossary"] = ed["glossary"]

    # NOTE: the committed docs/shipyard-data.json has no trailing newline, so we
    # match it byte-for-byte (a trailing newline would make the deck-coupling
    # gate perpetually red). Normalize the committed file + this line together if
    # a trailing newline is ever wanted.
    text = json.dumps(out, indent=2, ensure_ascii=False)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
