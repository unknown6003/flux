# Native migration groundwork

The new core reads the existing app's 34 settings and saved formats. It is not yet the app's active persistence layer. The old executable still builds from Sources/Flux.

## Settings

Preferences defines typed keys using the original stored names. PreferenceMigration takes the persistent domain, not registered factory defaults. Any saved Flux key, owned status-item position, existing Flux data or valid updater launch identifies an upgrade. The app must inspect that evidence before creating a new session file or writing analytics settings.

An upgrade fills missing settings with the old defaults. A new profile starts Clipboard collection, clipboard saving and Lock Screen off. An explicit value wins in both cases. The origin marker is written before missing defaults, so a stopped first launch keeps the new-profile defaults on retry. Writes affect missing owned keys only. They do not replace the whole domain or remove unknown settings, saved positions or content.

Malformed values stay on disk for recovery. The reader uses safe typed defaults. A malformed collection, clipboard-saving or Lock Screen switch cannot enable that feature. The store does not register global defaults, poll, start services or send analytics. UI controllers must apply changes after the write, rather than depend on the old willSet publication pattern.

## Saved files

ShelfArchive reads the old JSON array with its reference-date epoch. It preserves UUIDs, basenames, duplicate names and folder references. It does not move, reconcile or delete payloads. Traversal names and duplicate UUIDs fail the read. The 8 MiB metadata bound returns an error without pruning user files.

ClipboardArchive keeps version-one ISO8601 records, newest first, within the existing 50-entry, 30-day and 1,000,000-byte limits. Only text, URL and color records can persist. URLs are never truncated. The old writer could append an ellipsis after taking 32,000 characters. That 32,001-character legacy form is accepted and preserved exactly for text and color. New truncation fits within 32,000 characters.

ClipboardHistoryFile is an actor. Construction and disabled reads do no file work. Enabled reads stop at the byte limit. Saving validates an existing file before replacing it, so a failed load cannot silently erase a damaged or future-format file. Explicitly disabling persistence or clearing history removes the owned file. Writes are atomic, the containing directory is mode0700, and the file is mode0600. The service refuses symlink files and directories and files owned by another user. The application must still enforce a single writer instance. These checks are not a cross-process compare-and-swap protocol.

## Updater receipt

UpdateLaunch accepts one UUID token and one startup path in the updater's temporary workspace. It writes the installed helper's exact four-line format: token, PID, resolved app path and started or ready. The workspace must be owned by the current user with no group or other permissions. A symlink receipt is refused. No UI, network, feature or telemetry setup belongs before started. Ready follows successful startup. The signed full-app upgrade and rollback path remain untested.

## Review

The reviewed delta was b8c3d8f..41dce23. Standards found no issue. Spec and Risk independently found the same clipboard ellipsis compatibility gap. The parent checked the old writer and accepted the finding. The fix keeps the exact legacy text and adds a literal version-one fixture. The old-failure control was established from source, not an executed red test. A test fixture quoting error was also fixed before the archive tests could run.

Mac CI passed 27 core tests at411d407 and 30 at4c290fa. Native file-service tests and the new legacy regression are a later delta and require their own run. No result here proves physical hiding, the new interface, a real upgrade, complete data migration, or final memory use.
