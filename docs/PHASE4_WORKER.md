# SysInput v0.2 Phase 4: Prediction Worker

Completed on 2026-08-18 on the `gld2005` branch. This phase moves prediction
and accepted-word learning out of the low-level keyboard-hook path while
preserving the existing suggestion window and acceptance behavior.

## Runtime boundary

The keyboard hook now performs only a bounded submission:

- Copy the current text and word into fixed-capacity storage.
- Record the foreground target window.
- Replace the single pending prediction with the newest request.
- Increment a monotonic request version and wake one worker thread.

There is no prediction-engine call, candidate allocation, or learning mutation
in this submission path. The request slot is deliberately latest-only so fast
typing cannot create an unbounded backlog.

The worker owns prediction-engine access after startup. It computes candidates
into a fixed-capacity result, discards obsolete versions, and posts a private
Windows thread message. The main message thread then copies the result into the
manager's stable storage and updates the existing UI.

## Stale-result protection

A result is applied only when both conditions remain true:

- Its version is still the most recently submitted version.
- The foreground window is still the window that originated the request.

This prevents an older prediction from flashing after newer typing and prevents
a delayed result from following the user into another application.

## Learning queue

Accepted-word learning uses a fixed queue of 16 items and runs on the same
worker as prediction. If the queue is full, the oldest pending learning item is
replaced instead of blocking the hook or growing memory without a bound.

The project does not yet write learned data to disk. This phase establishes the
worker boundary that future persistence can use; adding a profile format or
disk writes belongs to its separately planned phase.

## Preserved behavior

- Existing suggestion window, styling, placement, and maximum of five results.
- Existing dictionary and in-memory personal-frequency ranking.
- Existing word acceptance and insertion fallback methods.
- Existing Tab, Right Arrow, Enter, Up, and Down behavior.
- No phrase or sentence prediction was added.
- No progressive chunk acceptance was enabled.
- No startup, tray, settings, or disk persistence was added.

Suggestion insertion itself and text-field focus synchronization remain on the
message/hook path. They are outside this phase's prediction-and-learning worker
scope and remain visible follow-up latency risks.

## Verification

```text
Debug build: passed
Debug characterization checks: 12/12 passed
ReleaseSafe characterization checks: 12/12 passed
git diff --check: passed
```

The worker check covers owned request copies, latest-request coalescing,
accepted-word queue delivery, main-thread result dispatch, and stale-version
rejection. Hook-side submission was also timed while the fake worker was active:

```text
ReleaseSafe: 0.027 us average over 10,000 submissions
Debug:       0.051 us average over 10,000 submissions
```

These are local microbenchmarks of the fixed-capacity submission boundary, not
end-to-end prediction latency. The existing ReleaseFast prediction benchmark
after this phase was:

```text
dictionary_words=9974
dictionary_load_ms=1.298
learn_1000_words_ms=0.131
suggestion_queries=1000
suggestion_avg_ms=0.020
suggestion_min_ms=0.003
suggestion_max_ms=0.137
working_set_mib=5.270
```

ReleaseFast hidden-start smoke sample:

```text
running=true
executable_bytes=672768
working_set_bytes=6897664
private_memory_bytes=19070976
cpu_seconds_over_500ms=0
threads=5
handles=61
```

The process initialized the manager and worker, installed its hook, remained
alive for the sample, and was terminated by exact process ID.
