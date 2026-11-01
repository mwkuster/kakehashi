// SCM-JP / kakehashi — period-homophony set classification (curated)
// :HomophoneSet reifies a reading's set with its OJ-etymon / period-homophony
// classification (see Tool — Roadmap: period-homophony typology).

CREATE CONSTRAINT homophoneset_reading_unique IF NOT EXISTS
  FOR (hs:HomophoneSet) REQUIRE hs.reading IS UNIQUE;
