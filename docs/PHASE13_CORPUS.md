# Phase 13: Local corpus prediction

Phase 13 adds a separate local corpus source for English word, next-word,
phrase, and repeated sentence continuation. It does not add grammar correction,
a generative model, network access, telemetry, or cloud storage.

## Supported input

- UTF-8 `.txt`
- UTF-8 `.md`
- One file
- A folder tree containing supported files

PDF, Word, web pages, and cloud corpora are intentionally not supported in this
phase.

## Import and runtime architecture

Import runs on a dedicated background thread:

```text
source files
-> ASCII English token cleanup
-> word frequency
-> 2-5 word context transitions
-> repeated phrase/sentence continuation
-> compact versioned index with CRC
-> atomic index replacement
```

The keyboard hook only submits input snapshots. It never opens corpus files,
walks folders, builds indexes, waits for import, or queries process paths.
Runtime prediction reads the loaded in-memory index and never scans source
files. Source text is not copied into the personal profile.

## Candidate policy

Candidate source priority is:

```text
accepted/personal learning
> imported corpus
> built-in dictionary
```

- A continuation must occur at least twice before context prediction.
- Confidence below 60% remains hidden.
- Competing continuations within 80% of the leading count cause the result to
  stop at the next word.
- Highly unique continuations can extend to a phrase and then a maximum of 12
  words for a repeated sentence continuation.
- Repeatedly shown and ignored corpus text receives a runtime score penalty;
  accepting it resets that penalty.

## Management

Open **Settings > Corpus > Manage**. The native window supports:

- Import file
- Import folder
- Background progress
- Cancel indexing
- Enable/disable a corpus
- Rebuild from its original source path
- Delete the local corpus index

Deleting a corpus never deletes its original source file and never changes the
personal profile. Each corpus keeps its source path, file count, index time,
enabled state, and index status in `corpus/manifest.bin`.

## Bounds

- Maximum 32 corpus sources
- Maximum 30,000 indexed tokens per corpus
- Maximum 60,000 context records per corpus
- Maximum source file size: 64 MiB
- Maximum compact index size: 32 MiB
- Runtime word-prefix lookup uses a sorted token index
- Runtime context lookup uses exact bounded hash keys

## Manual verification

1. Create a UTF-8 file containing the same English sentence twice.
2. Open **Settings > Corpus**, enable corpus prediction, and select **Manage**.
3. Import the file and verify its state reaches `ready` without typing lag.
4. Type the first two or more words and verify a corpus continuation appears.
5. Import a folder containing `.txt`, `.md`, and unrelated files; verify only
   supported files are counted.
6. Disable the corpus and verify its candidates disappear immediately.
7. Re-enable and rebuild it; verify prediction returns.
8. Delete it; verify the candidate disappears while the original files remain.
9. Start a larger import and press **Cancel indexing**; verify input remains
   responsive and the previous ready index is not replaced.
10. Restart SysInput and verify ready corpora reload without rescanning sources.
