# Phase 7: Next-word and phrase prediction

Phase 7 adds bounded English context prediction while keeping the existing
candidate window. It does not add repeated-sentence prediction, phrase
chunking, or progressive acceptance from Phases 8 and 9.

## Context model

- Context keys contain the most recent 2–5 normalized token IDs.
- Each key retains at most three possible continuations.
- The complete model is capped at 20,000 transitions and 10,000 tokens.
- New observations and feedback run only on the prediction worker.
- Full-table scans never occur during prediction. A query performs at most four
  hash lookups, from the longest context to the shortest.
- When full, learning replaces weak alternatives locally or evicts a weak entry
  from a bounded 64-record sample.

A small built-in seed covers common English continuations such as `please let
→ me know`, `as soon → as possible`, and `looking forward → to hearing from
you`. Personal observations use the same scoring table and can outrank seeds.

## Confidence behavior

- A single unambiguous personal observation can produce only the next word.
- A continuation becomes a phrase only when each step has at least two
  observations and high confidence.
- Ambiguous or repeatedly ignored contexts fall below the display threshold
  and produce no candidate.
- Ordering is deterministic. Observation count, accepted count, recency, and
  ignored displays affect ranking.

Context candidates appear only at a word boundary, normally immediately after
a space. Current-word completion from Phase 6 continues to handle a partially
typed word.

## Acceptance

`Tab` and `Right Arrow` accept the currently selected next-word or phrase
candidate and append one trailing space. Injected events remain filtered from
the keyboard hook; SysInput updates only its shadow buffer and immediately
requests the next prediction.

At this phase a displayed phrase is one phrase chunk. Right Arrow accepting
only one word and recalculating smaller chunks remains Phase 9 work.

## Persistence and privacy

The context table is saved beside the executable as `data/context.bin` using
the same 60-second worker maintenance and shutdown flush as the personal word
profile. Writes use a flushed temporary file, atomic rename, a bounded binary
format, version field, and CRC32 validation.

The file stores only normalized 2–5 word contexts, continuation words, and
their counters. It never stores complete input buffers, complete documents,
window handles, or application names. Invalid profiles are ignored safely.

## Verification

The characterization suite covers seeded phrases, one-observation next-word
prediction, accepted feedback, ambiguity suppression, ignored-prediction
suppression, bounded transition count, and context-profile round-trip and
corruption rejection.
