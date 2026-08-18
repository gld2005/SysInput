# Phase 9: Progressive candidate acceptance

> **Current behavior:** Phase 9.1 supersedes the original plain-arrow mapping.
> Plain arrows now remain application cursor keys, `Ctrl+Right Arrow` accepts
> one word, and `Alt+Up/Down` changes the highlighted candidate.

Phase 9 changes only how an existing candidate is accepted. It does not add a
new prediction model or enter Phase 10 compatibility and release work.

## Key contract

| Candidate state | `Tab` | `Right Arrow` |
| --- | --- | --- |
| unfinished current word | complete the word | complete the word |
| next-word prediction | accept one word | accept one word |
| phrase prediction | accept the current phrase chunk | accept one word |
| repeated-sentence prediction | accept the current phrase chunk | accept one word |

`Enter` passes through to the target application and never accepts a
candidate. `Esc` only hides the candidate window. Up and Down retain their
existing candidate-navigation behavior.

## Acceptance pipeline

For phrase and sentence candidates, a successful acceptance performs these
steps on the UI thread:

1. derive the requested prefix without allocating;
2. insert only that prefix and one separating space;
3. update the shadow input buffer with the injected text;
4. queue accepted feedback for only the committed prefix;
5. immediately rebuild and display the uncommitted remainder;
6. submit the updated input snapshot to the prediction worker.

The retained remainder prevents the window from disappearing between two
successive presses. It is optimistic: the normal monotonically versioned
worker result replaces it as soon as the updated context has been checked.
Older results still cannot overwrite newer input.

## Chunk rebuilding

Remainders reuse the fixed candidate buffers. Chunk rebuilding performs no
heap allocation, keeps ranges contiguous, limits a normal chunk to four words,
and closes a chunk at comma, semicolon, or colon. If no usable remainder is
left, the candidate window closes normally.

Word completion remains a replacement operation, so it is never split into
individual letters or partial suffixes. A next-word prediction is already one
word and therefore behaves identically for both acceptance keys.

## Learning behavior

Context feedback already walks accepted tokens in order, so partial phrase
acceptance rewards only the committed continuation. Repeated-sentence feedback
now accepts a complete prediction prefix at a word boundary; shown feedback
still requires an exact candidate match. This resets ignore penalties only for
a prefix the user actually accepted.

## Verification

The characterization suite covers:

- the `Tab`, `Right Arrow`, `Enter`, and `Esc` mapping;
- whole-word completion under both acceptance modes;
- phrase chunk versus single-word acceptance;
- sentence remainder rebuilding and punctuation boundaries;
- partial repeated-sentence feedback and invalid-prefix rejection;
- the existing input, worker, profile, context, and sentence regressions.

The standalone benchmark also measures allocation-free acceptance splitting
over 100,000 alternating chunk and word operations.
