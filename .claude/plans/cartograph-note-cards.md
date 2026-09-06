# Cartograph — attached notes as first-class citizens

> **Status: built.** 135 module assertions and 138 app-level assertions pass.

Three things, one theme: an attached note card stops being a dead end.

| | |
|---|---|
| Attach several notes at once | several notes → one node, one undo step |
| Relink | **move a card to a different node**, and **link one card to another** |
| Casual links from cards | a card may link to any node, or to another card |
| Cards in select mode | selectable, but only for the operations that mean something |

## A bug to fix first

`Synapse.pickNotes` takes **`multiSelect`**; Cartograph passes **`multiple`**,
which is not a recognised option. The host picker has therefore always opened in
multi-select mode, and the code silently keeps `notes[0]`.

So today you can select five notes and four disappear without a word. This
affects *attach*, *import a map here*, and *open a note as a map*. Fixing the
name makes multi-attach nearly free, and makes the two genuinely-single flows
actually single.

## Where a card's links live

Chosen: **in this note, on the same line as the attachment.**

```markdown
- Colors

  [Interview script](synapseresource://note/abc) → [Design](#design)
  [Recruiting plan](synapseresource://note/def) → [Interview script](synapseresource://note/abc)
```

The rule is positional, not cosmetic: **a body line whose first link is a note
link is that card's line, and any further links on it belong to the card.** The
`→` is decoration — deleting it changes nothing, exactly as the `[→ Name]`
labels on node links are decoration.

This keeps every write inside the note you opened, keeps one undo step per
action, and needs no new file format. The cost, accepted: the relationship
exists only in this map. Open the other note on its own and there is no sign of
it.

### What this forces in the parser

Today every link found in a node's body becomes a link *of that node* — so
`[A](note/abc) → [B](#design)` would draw a cross-link from the **node** to
Design, which is wrong: it belongs to the card.

So links need line attribution. `md.parse` will record each extracted link's
line start, and `view.build` will group body links by line: a line starting with
a note link yields a card plus that card's outgoing links; every other line
keeps today's behaviour and belongs to the node.

### Resolving a card→card link

`[Recruiting plan](synapseresource://note/def)` on a card's line means "the card
for note def" — and that note may be attached in several places. The **nearest
card wins**, by tree distance, exactly as the same-name rule already works for
`#slug` anchors. A link to a note attached nowhere draws no edge, as a dangling
anchor already does.

## Moving a card to a different node

A card is one body line, so moving it is a line move: remove it from one node's
body, append it to another's, in a single splice set computed against the
original document — the pattern `moveMany` already uses. The whole line travels,
so the card keeps its own links.

The **Move to…** picker is reused unchanged; only the thing being moved differs.

## Attaching several notes

`attachExisting` drops the bogus option, takes every note that comes back, and
appends one body line per note in **one splice**, so N attachments are one undo
step. The blank-line rule already needed for a single attachment (a line
directly under a bullet is a paragraph continuation, not body) applies once to
the block rather than per line.

## Cards in select mode

Cards become tappable in select mode and join `S.multi`. Which buttons appear is
decided by what is selected:

| Selection | Offered |
|---|---|
| nodes only | Merge, Group, Split, Move, Link |
| cards only | Move, Link |
| a mix | Link only |

**Merge, Group and Split are withheld from cards** because they rewrite markdown
labels, and a card is a reference to another note, not text this note owns.
Asking an AI to merge a note reference into a bullet has no coherent meaning and
would destroy the attachment.

**Move is withheld from a mixed selection.** Nodes move as subtrees among a
node's children; cards move as lines into a node's body. Both in one splice set
is possible but fragile, and the failure would be silent. A mixed selection gets
a plain refusal: *move nodes and attached notes separately*.

### Linking with a card involved

When a card is in the pair, **the card is the source** — its links live on its
own line. Card→node and card→card both work; two cards use the earlier one in
document order as the source. Unlink strips that link from the card's line.

## Drawing

Card links use the same dashed curve and the same counter-scaled handle as node
links, so there is one visual language for "this crosses the hierarchy". Tapping
the handle selects both ends, whatever kind they are.

## Risks

| Risk | Mitigation |
|---|---|
| A card's line grows long in the raw markdown | It is still one line of ordinary links; the map is where it is meant to be read |
| Links on an attachment line are misread as the node's | The line-attribution change is the fix, and is directly tested |
| Card→card resolves to the wrong copy of a note attached twice | Nearest-by-distance, the rule already used for anchors |
| A mixed selection silently does the wrong thing on Move | Refused with a reason, not attempted |
| The picker bug hides notes people selected | Fixed first, and covered by a test that asserts several notes come back |

## Testing

Deterministic:

- links on an attachment line belong to the card, not to the node
- a plain body link still belongs to the node
- several notes attach in one splice, and one undo restores all of them
- moving a card carries its own links with it, and the rest of the note is
  byte-identical
- moving a card onto the node it is already on is refused
- card→card resolves to the nearest of two copies, in both directions
- a card link to a note attached nowhere draws no edge and does not throw
- attach → unlink → detach round-trips the markdown exactly

App level: the picker returns several notes and all arrive; a card can be
selected; Merge and Group are absent for a card selection and present for nodes;
Move is refused for a mixed selection; tapping a card-link handle selects the
card and its target.


---

## What shipped

Built as designed. The picker bug was real and is fixed; the line-attribution
change landed as planned and is where both new bugs turned up.

### Bugs found while building
- **Removing a card's line ate the blank line that made the REST of the body
  body.** With two attachments, detaching the first left the second folded back
  into the node's label — the same CommonMark continuation trap that
  `appendBodyLine` already had to avoid, arriving from the removal side. The
  rule now keeps that blank when unstructured indented text remains below, and
  drops it when what follows is a nested bullet or heading, which never needed
  it.
- **Detaching would have stranded a card's links.** Stripping only the note link
  left `→ [Type](#type)` on the line; the line's first link would then be an
  anchor, quietly promoting the card's links to the node's. Detach now takes the
  whole line.

### A test that was checking stale DOM
`closeSheet` only hides the sheet, so a previous picker's rows stay in the DOM.
An assertion that "no picker opened" by counting rows passed or failed on
leftovers. It now asserts the sheet never gained its `open` class.

### Testing
- **135 module assertions**: line attribution both ways; a note link in a label
  still making a card (v1 behaviour, guarded); several notes attaching in one
  edit; a moved card carrying its links while the node it left keeps its own;
  card-to-card resolving to the nearest copy; a card link to a note attached
  nowhere; and attach → link → unlink → detach returning the note byte-exactly.
- **138 app-level assertions**: every picked note arriving rather than just the
  first; a card being selectable; Merge and Group absent for a card selection;
  Move refused on a mixed one; moving a card through the picker; linking a card
  to a node; tapping a card-link handle selecting the card and its target.
