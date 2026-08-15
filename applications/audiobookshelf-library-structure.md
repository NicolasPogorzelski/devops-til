# Audiobookshelf: Library Folder Structure

## Recommended structure

ABS supports two layouts:

```
Author/
└── Book/                        # flat - works, ABS detects metadata from tags

Author/
└── Series Name/
    └── NN - Book Title/         # preferred for series - ABS reads series from folder name
```

Mixed is fine: series books in subfolders, standalones directly under the author dir.

## Why the series subfolder matters

ABS resolves series name and sequence number from the folder path when no explicit
metadata is set. `Author/Series/01 - Title/` is unambiguous. `Author/Series 01 - Title/`
requires ABS to parse the series name out of the book folder - less reliable.

## Common source format (Audible downloads)

Files often arrive as:
```
Author Name - Series Name NN - Book Title/
```

The author prefix is redundant once the book lives inside `Author Name/`. Strip it
and sort into series subfolders for a clean library.

## Reorganization script pattern

`snippets/audiobook-reorganize.py` in the homelab repo handles this automatically.
Key design decisions:

**Dry-run by default.** Never mutate without an explicit `--execute` flag. Always
verify the plan before applying.

**Prefix stripping via split, not regex.** Split on the first ` - `, check if the
leading segment matches a known author prefix. Handles co-author variants like
`Author, Co-Author - Title` naturally.

**Series detection via two regex passes:**
1. Keyword pattern: `Series - Folge/Band/Teil NN - Title` (German episode naming)
2. Plain pattern: `Series NN - Title`

Minimum series name length of 3 chars avoids false positives (e.g. a title starting
with a number like `10 Minuten...` does not trigger series detection).

**Conflict detection before execute.** Track proposed targets in a dict; warn and
skip if two source folders would map to the same destination.

## Privacy note

The `AUTHOR_PREFIXES` mapping in the script reveals what you own. Commit only an
empty template to public repos - populate locally on the machine running the script.
