# Cartograph — "Move to…", an explicit reparent

> **Status: built.** 93 module assertions and 87 app-level assertions pass.

## Why

Reparenting exists today, but only by **dragging a node onto another**. That
covers one case well and three cases badly:

- Both nodes must be on screen at once. Moving something into a branch on the
  other side of a phone-sized map means dragging across a zoomed canvas.
- Dragging is deliberately **off in select mode**, so it cannot combine with a
  multi-selection.
- **Outline mode has no dragging at all** — only indent / outdent, one step per
  tap, which cannot cross to a different parent.

So: an explicit destination picker, reachable from both views.

## What gets added

| Where | Action |
|---|---|
| **More ▸ Move to…** | move the selected node |
| **Select mode ▸ Move** | move everything selected, in one step |

The picker lists the note's outline as indented rows, with a search box for
long notes and **Top level** pinned first. Destinations that are not valid —
the node itself, anything inside it, and its current parent — are simply not
listed, rather than offered and then refused.

Nodes land as the **last child** of the destination. Ordering within a parent
is already served by the up/down buttons, so the picker does not try to be a
reordering tool as well.

## Lifting the heading-under-bullet restriction

v1 refused to move a section under a bullet, because the conversion was
undefined. It is defined now: `edit.reshape`, written for **import**, already
turns any outline into the shape its destination requires — headings stay
headings while there is depth left, and become bullets once the destination is
a bullet or the level would pass `######`.

So `canMove` drops that rule and keeps only the two that are actually
impossible: a node cannot hold itself, and cannot move inside its own branch.

`edit.move` keeps its existing fast path — a pure indent or heading-level shift
— for same-kind moves, so drag, indent and outdent behave exactly as before.
Reshape is a **fallback**, taken only when the kinds differ. A move that will
change a node's kind says so on the row: *"becomes a bullet"*.

## Moving several nodes at once

Two things have to be right:

- **Nested selections must not duplicate.** If a node and its own child are
  both selected, the child travels inside its parent's block; moving it
  separately as well would copy it. Any node that is a descendant of another
  selected node is dropped from the move.
- **One splice, not N moves.** All the removals and the single insertion are
  computed against the *original* document and applied as one splice set, so no
  offset ever has to be re-resolved against a document that has already shifted
  under it. The insertion point skips any child that is itself being moved,
  which is the only way it could land inside a range about to be removed.

The whole move is therefore one undo step.

## After the move

The moved node is selected and its branch framed with `fitBranch`, so you can
see where it went, with a toast naming the destination and pointing at undo.

## Testing

- a section moved under a bullet becomes bullets, nested correctly
- a bullet moved under a section becomes a top-level bullet there
- a same-kind move still takes the fast path and preserves markers
- moving into a node's own branch is refused
- a multi-move keeps document order and does not duplicate nested selections
- the rest of the note is byte-identical afterwards, and coverage stays clean
- app level: picker omits invalid destinations, move is one undo step


---

## What shipped

Built as designed. Two things worth recording:

- **"Top level" needed a clearer label.** When a lone `#` heading is hoisted to
  be the map's centre, moving something to the top level means putting it
  *outside* that centre — creating a second one and changing the shape of the
  whole map. The row now says `Top level — outside "<centre>"` in that case,
  rather than sitting innocently above the real top.

- **A v1 test was passing for the wrong reason.** The assertion that a section
  could not nest inside a bullet used a bullet that was *itself inside* that
  section, so the own-branch rule was what actually refused it — the kind rule
  was never exercised. Replacing it meant picking a bullet in a different
  branch, and adding a second assertion so both rules are now tested separately.
