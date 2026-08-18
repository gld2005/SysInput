# Phase 8: Repeated sentence prediction and chunking

Phase 8 adds local repeated-sentence prediction. It does not generate text and
does not implement Phase 9 progressive acceptance.

## Learning gate

A sentence becomes eligible only when all of the following are true:

- it contains at least three English word tokens;
- its normalized body has completed at least twice;
- the current sentence prefix matches from its first three words;
- a non-empty continuation remains;
- ignored-display penalties have not reduced confidence below the threshold.

Case, whitespace, and the final `.`, `!`, or `?` are ignored when deciding
whether two occurrences are the same. Internal commas, semicolons, and colons
remain part of the sequence. This recognizes formatting-level near matches
without making risky semantic guesses. The first confirmed spelling is retained
for output, so personal casing such as `Alice` or `NASA` is preserved.

## Bounded data and lookup

- At most 2,000 sentence records are retained.
- A sentence contains at most 32 stored word/punctuation tokens.
- The token interner is capped at 10,000 tokens.
- A three-word prefix index points to at most eight sentence variants.
- Prediction reads only the matching prefix bucket and never scans all records.
- Full stores replace a weak, old record selected from a bounded sample.

The first observation is retained only as a possible future repeat and is not
predicted. Only records seen at least twice are written to disk.

## Prediction and chunking

- Repeated-sentence candidates have kind `sentence_completion` and source
  `repeated_sentence`.
- At most 12 following words are displayed.
- Each chunk contains one to four words.
- A comma, semicolon, or colon closes the current chunk.
- If no reliable sentence continuation exists, the normal Phase 7 context
  predictor remains the fallback.

The chunks are structural metadata in this phase. `Tab` and `Right Arrow` hide
the sentence candidate and retain their normal application behavior; they do
not accept the entire sentence. Chunk-by-chunk acceptance is Phase 9.

## Persistence and privacy

Repeated records are saved beside the executable as `data/sentences.bin` by
the existing worker maintenance task every 60 seconds and during shutdown.
Writes use a flushed temporary file, atomic rename, a versioned bounded format,
and CRC32 validation.

This file contains normalized repeated sentence tokens and counters. It does
not contain complete documents, raw input buffers, application names, or
window handles. Invalid files are ignored safely.

## Verification

The characterization suite covers the two-occurrence threshold, case and final
punctuation normalization, ignored-candidate suppression, the 12-word maximum,
one-to-four-word chunks, punctuation chunk boundaries, profile round-trip, and
corruption rejection.
