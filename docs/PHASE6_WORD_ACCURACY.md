# Phase 6: Deterministic word prediction and personal profile

Phase 6 changes only current-word completion. It does not add next-word,
phrase, sentence, or generative prediction.

## Base dictionary

- `resources/dictionary.txt` line order is preserved as the frequency rank.
- The loaded vocabulary becomes read-only after startup.
- A lexical index provides a binary-search prefix range.
- Completion inspects only that prefix range, not the whole dictionary.
- Ties are resolved lexically, so the same state always returns the same order.

## Personal ranking

Each normalized English word stores:

- typed count;
- shown count;
- accepted count;
- last-used sequence;
- last-accepted sequence;
- consecutive ignored displays.

Ranking combines the base rank, typed and accepted frequency, recency, casing,
ignored-display penalty, and a small length penalty. Personal words use their
own sorted prefix index. The store is capped at 10,000 words; the weakest and
oldest low-value entry is evicted when the cap is reached.

Prediction snapshots learn only a newly completed word appended in the same
target window. Recomputing an unchanged buffer does not increase its count.

## Persistence and privacy

The profile is stored beside the executable at `data/profile.bin`. With the
normal project build this is under `G:\SysInput\zig-out\bin\data`, not the
system drive.

- Saves run on the prediction worker, never in the keyboard hook.
- Dirty data is saved at most once per 60 seconds and once during shutdown.
- A temporary file is flushed and atomically renamed over the previous file.
- The binary format has a magic value, version, bounded record count, payload
  length, and CRC32 checksum.
- Invalid, truncated, oversized, or unsupported profiles are ignored safely.
- Only normalized words and counters are persisted. Full input buffers,
  phrases, sentences, application names, and window handles are never saved.

## Verification

The characterization suite covers ranked prefix lookup, deterministic results,
personal priority, duplicate-learning prevention, profile round-trip, corrupt
profile rejection, the 10,000-word bound, and worker shutdown maintenance.
