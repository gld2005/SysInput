# Custom data directory

SysInput's **Settings > Data** page supports a custom runtime-data directory in
installed mode. The default remains `%LOCALAPPDATA%\SysInput`; portable mode is
unchanged and always uses `data` beside `SysInput.exe`.

## Startup resolution

The fixed default directory contains a small `data-location.bin` locator. The
startup order is:

1. `--portable` uses the executable's adjacent `data` directory.
2. Installed mode loads a valid custom locator.
3. Missing, damaged, or unsupported locators fall back to the default directory.

The locator is bounded, versioned, protected by CRC32, and replaced through a
temporary file. It contains only the selected local path.

## Safe change and migration

Applying a change writes `data-location.pending`; it does not redirect live
stores. The current process continues using its original directory and saves
its final personal profile during normal shutdown. On the next launch SysInput:

1. reads and validates the pending request;
2. optionally copies the complete data tree into an empty destination;
3. preserves the entire source tree;
4. updates the active locator only after a successful copy;
5. continues with the previous directory if any step fails.

Users can clear **Copy existing data** to activate a directory that already
contains data. SysInput never merges a migration into a non-empty directory.

The folder browser and path edit use the Unicode Win32 APIs. The selected path
must be absolute and writable.

## Uninstall boundary

The installer continues to manage only SysInput's standard local application
data. It must not recursively delete an arbitrary custom directory. Custom data
is retained and can be removed manually after the user verifies it is no longer
needed.

## Verification

Automated checks cover locator persistence, Unicode paths, non-destructive
copying, and rejection of a non-empty copy target. Manual acceptance should
also cover:

- choosing a new directory on another local drive;
- closing normally and confirming the new location after restart;
- restoring the default directory;
- selecting an existing data directory with copying disabled;
- an unwritable destination;
- portable-mode controls remaining disabled;
- uninstall preserving a custom directory.
