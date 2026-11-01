// SCM-JP / kakehashi — schema constraints
// See docs/data-model.md

CREATE CONSTRAINT sign_codepoint_unique IF NOT EXISTS
  FOR (s:Sign) REQUIRE s.codepoint IS UNIQUE;

CREATE CONSTRAINT lexeme_key_unique IF NOT EXISTS
  FOR (l:Lexeme) REQUIRE (l.phonology, l.orthography) IS UNIQUE;

CREATE CONSTRAINT concept_id_unique IF NOT EXISTS
  FOR (c:Concept) REQUIRE c.id IS UNIQUE;

CREATE CONSTRAINT reading_key_unique IF NOT EXISTS
  FOR (r:Reading) REQUIRE (r.value, r.type) IS UNIQUE;

CREATE CONSTRAINT alignment_id_unique IF NOT EXISTS
  FOR (a:Alignment) REQUIRE a.id IS UNIQUE;
