# notes — Notes

Read and write Apple Notes: list folders, search, read full note content, and
create or append notes. Note bodies are authored and returned as Markdown.

**Access:** read/write
**Permissions:** Automation (AppleScript control of Notes) for `folders`,
`read`, `create`, and `append`; Full Disk Access for `search` and for the
link/checklist recovery on `read`, which read `NoteStore.sqlite` directly.

## Actions

- **folders** — list every folder with `id`, `name`, `note_count`, and (for
  nested folders) a `/`-separated `path`. Recently-Deleted folders are excluded.
- **search** — find notes by keyword (`query`), newest first, with `offset` /
  `limit` pagination (default 20, max 50). Matches titles only by default; pass
  `full_text=true` to also scan note bodies. Optional `folder` narrows to a
  folder by name. Returns snippets, not full bodies — use `read` for content.
- **read** — full note content by `id` (an `x-coredata://` URI) or `title`.
  Returns `folder`, `created`/`modified` timestamps, and the body as Markdown.
- **create** — new note from `title` and Markdown `body`. Optional `folder`
  takes a name or `/`-separated path; an existing folder is used as-is, a path
  with missing segments creates them nested.
- **append** — add Markdown `text` to the end of an existing note found by `id`
  or `title`.

Run `apple-tools notes --help` for the exact parameters of each action.

## Examples

```bash
apple-tools notes folders
apple-tools notes search --query "meeting" --full_text --limit 10
apple-tools notes read --title "Grocery list"
apple-tools notes create --title "Trip plan" --body "# Trip plan\n- book flights" --folder "Travel/2026"
apple-tools notes append --title "Grocery list" --text "- olive oil"
```

## Shortcomings

- **No delete, rename, or move.** The only actions are folders/search/read/
  create/append (`NotesTool.handle`); there is no way to delete a note, rename
  it, or move it between folders.
- **Append-only editing.** `append` sets `body of theNote` to
  `existingBody & theContent` — content can only be added to the end. There is
  no replace, insert, or edit of existing text, and no way to remove content.
- **Links and checkboxes can't be stored.** On write, `[text](url)` is flattened
  to `text (url)` and `- [ ]` becomes a plain bullet (per the tool description);
  Apple Notes can't persist link hrefs or checkbox state via this API. On `read`,
  URLs and checked-state are recovered best-effort from the protobuf store
  (`linkLookup` / `checklistLookup`) and may be stale.
- **Search is not real-time.** `search` reads the on-disk `NoteStore.sqlite`,
  which Notes flushes on its own cadence — a just-created or just-renamed note
  may not match yet (comment in `NotesStoreSearch`). For freshness, `read` by
  id/title (AppleScript) instead.
- **`full_text` skips encrypted notes.** Bodies that won't gunzip (encrypted
  notes) are silently skipped under `full_text` rather than matched; any
  store-access failure returns an empty result rather than an error.
- **Folder lookup is flattened.** On `create`, an exact folder-name match
  *anywhere* in the hierarchy wins before the path walk (`liveFolderByName`), so
  two folders sharing a name in different parents are ambiguous — the first live
  match is used. The `search` folder filter likewise matches a folder by exact
  title (`ZTITLE2 =`), not by path.
- **Recently-Deleted detection is English-only.** Deleted folders/notes are
  filtered by matching the literal name "Recently Deleted" (`isDeletedFolder`)
  / `ZMARKEDFORDELETION`; macOS localizes that container name, so on non-English
  systems a deleted folder can leak into listings or receive a created note.
- **`create` derives the title from the body.** It never sets the note's `name`;
  it prepends `# <title>` as the first line and lets Notes promote it, dropping a
  leading body heading that just repeats the title (`composeBodyWithTitle`) to
  avoid a doubled header. A body whose intended first line coincidentally equals
  the title will have that line swallowed.
- **`read` folder resolution is a linear scan.** The note's folder is found by
  scanning every folder for the note id and reports `"unknown"` if none contains
  it, which can be slow on large stores.
