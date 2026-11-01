// SCM-JP / kakehashi — indexes for query workloads

// F1, F5: homophone scan by reading
CREATE INDEX lexeme_phonology IF NOT EXISTS
  FOR (l:Lexeme) ON (l.phonology);

// F3: concept lens
CREATE INDEX concept_gloss IF NOT EXISTS
  FOR (c:Concept) ON (c.gloss);
