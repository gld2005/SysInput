# SysInput v0.2 Phase 3: Structured Candidates

Completed on 2026-08-18 on the `gld2005` branch. This phase introduces the
internal `Candidate` and `Chunk` contract while retaining the current string
list as a presentation-only adapter for the existing suggestion window.

## Candidate contract

Each candidate now carries:

- `kind`: word completion, next word, phrase completion, or sentence completion.
- `source`: dictionary, personal frequency, spelling, learned phrase, or
  repeated sentence.
- `display_text`: borrowed text shown by the existing UI.
- `insert_text`: borrowed text intended for insertion.
- `replace_length`: number of existing bytes the candidate expects to replace.
- `score`: engine ranking value.
- `confidence`: normalized value from 0 through 1,000.
- Up to 12 ordered, contiguous chunks.
- The active chunk index for future progressive acceptance.

Chunks carry a byte range and are classified as word, phrase, or punctuation.
The model validates bounds, contiguity, total coverage, confidence, and active
chunk state without allocating memory.

## Current integration

The current autocomplete engine still produces word strings. The suggestion
manager now converts every result to a structured `word_completion` candidate:

- Results found in the personal frequency table use `personal_frequency`.
- Other current results use `dictionary`.
- The current partial-word length becomes `replace_length`.
- The complete word is represented by one word chunk.

The manager's structured candidate list is the source of truth for selection,
navigation, count, and acceptance. A borrowed `[][]const u8` view containing
only `display_text` is passed to the unchanged UI.

Acceptance resolves the selected structured candidate and currently permits
only `word_completion`. Future candidate kinds are explicitly rejected until
their insertion semantics are implemented in later phases.

## Ownership safety

The current autocomplete cache previously borrowed slices owned by a result
list. Clearing that list could leave the cache pointing at freed memory. The
cache now copies at most five suggestions into fixed internal buffers.

The manager owns raw generated strings. Structured candidates and the UI view
borrow those strings only until the next candidate generation. Cleanup order is
explicit: candidate/view lists are cleared first, followed by owned raw strings.

## Preserved behavior

- Existing suggestion window and styling.
- Maximum of five displayed suggestions.
- Existing word ranking and generated results.
- Existing Tab, Right Arrow, Enter, Up, and Down behavior.
- Existing word replacement and insertion fallback methods.
- No phrases or sentence candidates are generated.
- No progressive chunk acceptance is enabled.
- No worker thread, persistence, startup, tray, or new settings were added.

## Verification

```text
Debug build: passed
Characterization checks: 11/11 passed
ReleaseFast prediction benchmark: passed
git diff --check: passed
```

New checks cover:

- Candidate metadata and confidence clamping.
- Word-completion chunk creation.
- Multi-chunk phrase ranges and progression.
- Candidate structural validation.
- Cache reuse after the previous result strings are freed.

Measured prediction microbenchmark after the model adapter:

```text
dictionary_words=9974
dictionary_load_ms=1.599
learn_1000_words_ms=0.133
suggestion_queries=1000
suggestion_avg_ms=0.018
suggestion_min_ms=0.003
suggestion_max_ms=0.154
working_set_mib=5.266
```

This microbenchmark measures the existing autocomplete engine and not the UI
adapter. End-to-end hook work remains synchronous until its separately planned
worker phase.

ReleaseFast hidden-start smoke sample:

```text
running=true
executable_bytes=681472
working_set_bytes=6791168
private_memory_bytes=2076672
cpu_seconds_over_500ms=0
threads=4
handles=60
```

The process initialized the structured candidate manager, installed its hook,
remained alive for the sample, and was terminated by exact process ID.
