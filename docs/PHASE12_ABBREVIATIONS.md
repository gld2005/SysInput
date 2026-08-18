# Phase 12: Abbreviation expansion

Phase 12 adds local abbreviation expansion without adding a language model or
changing the existing suggestion window.

## Candidate mode

1. Open **SysInput Settings > Abbreviations > Manage**.
2. Add a trigger and expansion, for example `sig` and `Best regards, Alex`.
3. Enable **Enable abbreviation expansion**.
4. Type the exact trigger. The expansion appears as the first candidate.
5. Press `Tab` for the full expansion or `Ctrl+Right` for one word at a time.

Showing or selecting the candidate never edits text. Abbreviation output is
excluded from personal word, phrase, and sentence learning.

## Explicit automatic mode

Automatic expansion is off by default. Enable **Auto with prefix** and choose a
single punctuation prefix (default `;`). With an `addr` entry, typing `;addr`
followed by Space replaces only that explicit token. Standard Windows controls
retain native Undo, so `Ctrl+Z` immediately restores the trigger.

Automatic expansion remains disabled while SysInput is paused, in excluded
applications, and in protected or password input.

## Storage and limits

- `abbreviations.bin` lives in the selected standard or portable data directory.
- Maximum 2,000 entries; triggers are at most 32 ASCII bytes and expansions 256 bytes.
- Exact trigger lookup uses deterministic `O(log n)` binary search.
- Trigger identity is case-insensitive; case-sensitive entries require exact casing.
- Usage statistics remain separate from personal input learning.
- Writes use the existing background maintenance worker and are forced at shutdown.

## Manager and TSV

The native manager supports search, add/update, enable/disable, case-sensitive
matching, delete, background TSV import/export, and clearing usage statistics.

```text
trigger<TAB>expansion<TAB>enabled<TAB>case_sensitive
```

Lines beginning with `#` are comments. The first TSV format skips expansions
containing tabs or line breaks during export.

## Manual verification

- Add `sig -> Best regards, Alex`; verify `sig` displays it first.
- Use `Tab`; verify the whole trigger is replaced once.
- Use `Ctrl+Right`; verify the expansion is accepted word by word.
- Navigate without accepting; verify target text remains unchanged.
- Restart; verify the entry remains.
- Enable auto mode; verify `addr ` does not expand but `;addr ` does.
- Press `Ctrl+Z` immediately after automatic expansion in Notepad.
- Repeat in an excluded app and password field; verify nothing is suggested,
  learned, or replaced.
