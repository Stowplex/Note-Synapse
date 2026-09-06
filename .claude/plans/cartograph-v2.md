# Cartograph v2 — AI generation, import, refactor, and a standalone home

> **Status: built.** All four features shipped as designed. 77 module
> assertions and 66 app-level assertions pass. See *What shipped* at the end.

Builds on the shipped Cartograph (`contrib/cartograph/`, uuid
`96d13a4a-…`). Everything here keeps the v1 contract: **the note is the source
of truth, and every change is a splice into markdown.** The AI proposes
markdown; it never gets a private data format of its own.

## Decisions taken

| | |
|---|---|
| Packaging | Ship **both** registrations from one HTML — a `normal` app and the existing `note_action` app |
| Companion link | **Source → companion only.** The map note stays a plain note |
| AI generation | **Restructure faithfully, never invent** |
| Refactor review | **Ghost preview on the map**, then apply |

---

## 0. What the platform actually gives us (verified, not assumed)

- **`Synapse.chatAI` returns plain text.** There is no JSON or schema mode —
  `response_type` only chooses string vs. multi-part. So the AI contract is
  *"emit a markdown outline"*, which the v1 parser already consumes. No new
  format, no schema validation, and a malformed answer still parses into
  something recoverable.
- **App types decide entry points.** `note_action` gets the note's action menu
  and block selection, and from the Apps list it pops a note picker before
  opening. `normal` opens straight away with `Synapse.Notes === []`, and is the
  only type that can be pinned as a **multi-function home tab**.
- **`synapseresource://note/<id>?via=cartograph` parses correctly** — the id
  comes from the path and query parameters are preserved and ignored by
  navigation. So the marker is safe, and greppable with SQL `LIKE`.
- **`saveNotes` returns no id**; v1's nonce round-trip in `host.createNote`
  already solves this and is reused throughout.

---

## 1. Two registrations, one source file

`build.sh` emits two yamls from the same HTML, differing only in name, uuid and
`app_type`. **No build flag and no code fork are needed**: the app already knows
which it is, because a `normal` launch arrives with `Synapse.Notes` empty.

```
Synapse.Notes.length ? open that note's map : show the home screen
```

Cartograph keeps no app state in v1, so a second registration costs one extra
row in the Apps list and nothing else. (v2 adds a small *recents* list to app
state; recents are per-registration, which is harmless.)

**Open question — naming.** Two rows called "Cartograph" would be confusing.
Proposal: the `normal` app is **Cartograph**, and the existing uuid becomes
**Cartograph: this note**. That renames the app committed today, which is safe
now and would not be later.

---

## 2. The home screen (`normal` launch)

Three sections:

1. **Recent** — from app state. The only way a map made by hand, and never
   linked from anywhere, stays reachable.
2. **Maps** — discovered in two SQL passes, since the companion is a plain note
   and holds no backlink:
   ```sql
   SELECT id, title, content FROM notes WHERE content LIKE '%?via=cartograph%'
   ```
   gives every *source* note; the companion ids are parsed out of their links
   and read in one follow-up query. Each row shows the map title and the note it
   came from.
3. **Browse** — `Synapse.pickNotes()` to open any note as a map.

Plus the primary action: **Generate a map from a note…**.

> **Accepted trade-off of "source links to companion only":** a map note that
> nothing links to is invisible to pass 2. Recents and Browse cover it. The
> alternative was a backlink or tag in the companion, which was explicitly not
> wanted.

---

## 3. Generate a map with AI

Available from both registrations. In the note action it targets the current
note; on the home screen you pick one.

**Flow:** pick source → generate → **preview the map** → Save / Regenerate /
Discard → companion note written → link appended to the source.

### The prompt contract

The model is asked for a markdown outline and nothing else:

- `#`/`##`/`-` only; no prose, no preamble, no code fences around the answer.
- One `#` heading, the map's centre (v1 hoists a lone H1 to the centre).
- **Restructure only.** Group, order and promote what the note already says.
  Introduce no facts, names, numbers or conclusions that are not in the source.
- Reuse the note's own wording for labels wherever it reads well, so branches
  stay traceable to the text they came from.
- Carry `- [ ]` / `- [x]` through unchanged where the source has tasks.

Because the answer is just markdown, it goes straight through `md.parse` and is
rendered with the ordinary renderer for preview. A response with stray prose
degrades to a node with a long label — visible and fixable, never fatal.

### Long notes

`note.content` can be very large. Above a threshold (~12k chars) the note is
split on its top-level headings, each section mapped in its own call, and the
results concatenated under one root. Sections keep their own headings, so the
join is a string concatenation rather than a merge. The preview says how many
calls it took.

### The companion note

- Title: `<source title> — map`
- Content: the generated outline, starting with `# <source title>`.
- An ordinary note in every way: editable, searchable, exportable.

### The link written back to the source

One line appended to the end of the source note:

```markdown
[🗺 Mind map](synapseresource://note/<companion-id>?via=cartograph)
```

Undoable like any other write. **Regeneration is idempotent:** if the source
already carries a `?via=cartograph` link, the offer is *"regenerate into the
existing map"* — the companion's content is replaced and no second note or
second link appears.

---

## 4. Import a map from another note, at a node

The exact inverse of v1's *promote branch to a note*, and it reuses that
machinery.

**Flow:** select a node → `Note ▾` → **Import a map here…** → pick a note →
optionally pick which branch of it → **Copy in** or **Link**.

- **Copy in** (default) grafts the other note's outline under the target node:
  headings re-levelled and bullets re-indented to fit, using the same transforms
  as `edit.move`. Headings that would fall past `######` become bullets instead
  of being clamped, so nesting is never silently flattened.
- **Link** is the existing attach-a-note behaviour, producing a transclusion
  card. Offered because it is one tap away and sometimes what you meant.

Copy is the default because *import* implies bringing the content in, and
linking already had a home on the menu.

---

## 5. AI refactor, with a ghost preview

### Prerequisite: multi-select

Today exactly one node is selected. Merging needs several, and overloading drag
would fight panning, so selection becomes an explicit **mode**: a *Select*
button on the action bar, then tap to add or remove, with a count in the top
bar. Escape or Done leaves the mode. Dragging is disabled while selecting.

### Operations

Single node or branch: **Regroup** (reorganise a messy branch), **Split**
(break an overloaded node into siblings), **Tidy labels** (make wording
consistent). Multi-select: **Merge** (combine into one node, keeping every
child), **Group under a new parent**.

### The contract

Only the affected subtree's markdown is sent, with the instruction, and the
model returns replacement markdown for **that subtree only**. The reply is
spliced over exactly that span — the rest of the note is not in the request and
cannot be touched. The no-invention rule from §3 applies here too.

### The ghost preview

The proposal is parsed into a tree and matched against the current one with
`sidecar.match` — the matcher already written for re-finding nodes after an
outside edit, reused here to classify what the AI did:

| Classification | Drawn as |
|---|---|
| unchanged | normal |
| renamed | new label, old shown faintly beneath |
| moved / reparented | ghost edge to the proposed parent |
| merged away | faded, with an arrow into its survivor |
| new | dashed accent outline |

A summary line states the shape of the change — *"4 nodes merged into 2, 1
branch regrouped"* — with **Apply** and **Discard**. Apply is one splice and one
undo entry, so a bad result is one tap from gone.

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| Generation invents content and it looks authoritative | Prompt forbids it; preview before save; the map is a companion, never a replacement for the source |
| A refactor quietly drops content | Only a subtree is ever in play; ghost preview names the counts; single-step undo |
| Appending a link edits a note the user did not ask to change | It is the chosen design, it is one line, and it is undoable |
| Very long notes exceed the model's context | Section-wise generation, with the call count surfaced |
| Multi-select fights panning and dragging | An explicit mode, not a gesture |
| Two "Cartograph" rows confuse the Apps list | Distinct names; see the open question in §1 |

---

## 7. Testing

The deterministic half is where the risk actually lives, and all of it is
testable without a model:

- **Import grafting** — re-levelling and re-indentation for every combination of
  heading/bullet source and target, including overflow past `######`.
- **Diff classification** — a fixed before/after pair must produce exactly the
  expected kept / renamed / moved / merged / new sets.
- **Companion linking** — link written once, regeneration replaces rather than
  duplicates, and the marker survives a round trip.
- **Discovery queries** — sources found, companion ids extracted, missing
  companions handled.
- **Section splitting** — a long note splits and rejoins into the same outline.

For the AI half, the dev mock host gains a **scripted `chatAI`** returning
canned markdown — including deliberately bad answers (prose, a code fence
around the outline, an empty reply, a subtree that deletes everything) so the
degradation paths are covered end to end in `dev/app_smoke.html`, with no model
and no network.


---

## What shipped, and where it diverged

All four features were built as designed. Naming was approved as proposed:
**Cartograph** (`normal`, new uuid `00713e85-…`) and **Cartograph: this note**
(`note_action`, keeping `96d13a4a-…`).

### Confirmed in the build
- **One HTML, two registrations, no code fork.** The runtime test is simply
  whether a note arrived, so `build.sh` differs only in name, uuid and app_type.
- **`sidecar.match` really is the ghost preview.** The matcher written for
  re-finding nodes after an outside edit classifies an AI proposal unchanged.
- **The markdown-as-AI-contract held up.** Every malformed answer tried —
  fenced, chatty, headless, multi-headed, empty, prose-only — normalises or is
  refused, and none can corrupt the note.

### Decisions taken during the build
- **Merge detection is word overlap, not substring containment.** Merging
  "API docs" into "API design and docs" preserves every word but breaks the
  substring, so containment reported a deletion where a merge had happened.
- **A proposal frames its own branch.** Fitting the whole map after a refactor
  left the changed part off the side of the screen. `fitBranch()` frames the
  scope instead, and an import frames what it just brought in.
- **The proposal summary gets its own full-width row.** Squeezed between the
  Apply and Discard buttons it truncated — and it is the entire basis for
  approving the change.
- **Body-text loss is counted and surfaced.** The model is told to keep indented
  paragraphs, code and tables, but cannot be trusted to; the preview says
  "N blocks of text dropped" when the proposed branch holds fewer.
- **The refactor scope is the lowest common ancestor of the selection**, and if
  a selected node *is* the LCA the scope walks up one, so nothing is ever asked
  to rewrite itself.
- **Import defaults to copy, with link one tap away.** Import implies bringing
  content in; linking already had a home on the menu.

### Bugs found by the checks
- **`name: Cartograph: this note` is invalid YAML** — a colon in a plain scalar
  is a mapping indicator, and it made the whole app file unparseable. Caught by
  round-tripping every starter yaml through a real YAML parser after building.
  `build.sh` now emits properly escaped double-quoted scalars.
- Grafted sections were welded to the line above with no blank line.
- The node picker used `prompt()`, which cannot run in a headless test; the mock
  is now scriptable through `window.__CG_PICK__`.

### Testing
- **77 module assertions** (`node dev/run.js`, no browser): import re-levelling
  including `######` overflow, diff classification across merge/rename/move/
  remove/add, AI answer sanitising for six malformed shapes, long-note chunking
  including a heading inside a code fence, and companion-link round trips.
- **66 app-level assertions** (`dev/app_smoke.html`): the real app driven
  through import → undo, generate → preview → save, regenerate → replaces
  rather than duplicates, select → merge → ghost → apply, discard → note
  unchanged, and two bad AI answers refused without touching the note.
