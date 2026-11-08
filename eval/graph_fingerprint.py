"""Content fingerprint of the graph, to check that two graphs are equal.

Dumps every node (labels, properties) and every relationship (type, start key,
end key, properties) over Neo4j's HTTP endpoint, writes one canonical JSON line
per item (object keys sorted) into one file per label and per relationship
type, sorts the lines and hashes each file with SHA-256. A node's key is its
natural key from the schema in cypher/, so the result does not depend on
internal ids or the order of creation, on the driver that built the graph, or
on the Neo4j version (no APOC needed). Used to check that the switch from
hasbolt to bolty, and from Neo4j 4.4 to 5.26, leaves the graph unchanged.

Compare two runs with `diff A/SUMMARY.txt B/SUMMARY.txt`; for a label or type
that differs, `diff A/<file> B/<file>` shows the items.

Connection: KAKEHASHI_NEO4J_HOST (default 127.0.0.1), KAKEHASHI_NEO4J_HTTP_PORT
(default 7474), KAKEHASHI_NEO4J_USER and KAKEHASHI_NEO4J_PASSWORD (defaults as
for kakehashi itself).

    python3 eval/graph_fingerprint.py [--out data/fingerprint]
"""

import argparse
import base64
import hashlib
import json
import os
import urllib.request
from pathlib import Path

# Natural key of a node, by label (the uniqueness constraints of cypher/).
KEY = """CASE labels({v})[0]
  WHEN 'Sign' THEN 'S' + toString({v}.codepoint)
  WHEN 'Lexeme' THEN 'L' + {v}.phonology + '|' + {v}.orthography
  WHEN 'Concept' THEN 'C' + {v}.id
  WHEN 'Reading' THEN 'R' + {v}.value + '|' + {v}.type
  WHEN 'SiniticSense' THEN 'X' + {v}.id
  WHEN 'Alignment' THEN 'A' + {v}.id
  WHEN 'HomophoneSet' THEN 'H' + {v}.reading
  ELSE 'unknown:' + labels({v})[0] END"""


def connection(args):
    url = f"http://{args.host}:{args.port}/db/neo4j/tx/commit"
    user = os.environ.get("KAKEHASHI_NEO4J_USER", "neo4j")
    password = os.environ.get("KAKEHASHI_NEO4J_PASSWORD", "changeme-on-first-run")
    auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    def cypher(stmt):
        body = json.dumps({"statements": [{"statement": stmt}]}).encode()
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "Authorization": auth})
        with urllib.request.urlopen(req, timeout=3600) as r:
            d = json.load(r)
        if d["errors"]:
            raise SystemExit(f"{d['errors']}\n{stmt}")
        return [row["row"] for row in d["results"][0]["data"]]

    return cypher


def canon(x):
    return json.dumps(x, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/fingerprint", help="output directory")
    ap.add_argument("--host", default=os.environ.get("KAKEHASHI_NEO4J_HOST", "127.0.0.1"))
    ap.add_argument("--port", default=os.environ.get("KAKEHASHI_NEO4J_HTTP_PORT", "7474"), help="HTTP port")
    args = ap.parse_args()
    cypher = connection(args)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    files = []
    for (label,) in cypher("CALL db.labels() YIELD label RETURN label ORDER BY label"):
        rows = cypher(f"MATCH (n:`{label}`) RETURN labels(n), properties(n)")
        files.append((f"node {label}", f"node_{label}.jsonl", sorted(canon(r) for r in rows)))
    for (rtype,) in cypher("CALL db.relationshipTypes() YIELD relationshipType "
                           "RETURN relationshipType ORDER BY relationshipType"):
        rows = cypher(f"MATCH (a)-[r:`{rtype}`]->(b) "
                      f"RETURN {KEY.format(v='a')}, {KEY.format(v='b')}, properties(r)")
        files.append((f"rel {rtype}", f"rel_{rtype}.jsonl", sorted(canon(r) for r in rows)))

    summary = []
    for name, fname, lines in files:
        text = "\n".join(lines) + "\n"
        (out / fname).write_text(text, encoding="utf-8")
        summary.append(f"{name} {len(lines)} {hashlib.sha256(text.encode()).hexdigest()[:20]}")
    unknown = cypher(f"MATCH (n) WITH {KEY.format(v='n')} AS k WHERE k STARTS WITH 'unknown:' RETURN count(*)")[0][0]
    summary.append(f"nodes without a known key: {unknown}")
    (out / "SUMMARY.txt").write_text("\n".join(summary) + "\n", encoding="utf-8")
    print("\n".join(summary))
    if unknown:
        print("warning: relationships of these nodes are keyed by label only; extend KEY")


if __name__ == "__main__":
    main()
