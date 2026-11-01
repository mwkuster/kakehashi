// SCM-JP / kakehashi — Sinitic source-language layer (Phase 2)
// See docs/data-model.md (SiniticSense)

CREATE CONSTRAINT sinitic_id_unique IF NOT EXISTS
  FOR (ss:SiniticSense) REQUIRE ss.id IS UNIQUE;
