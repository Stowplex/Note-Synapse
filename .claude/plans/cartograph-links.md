# Cartograph — linking two unrelated nodes

> **Status: built.** 117 module assertions and 112 app-level assertions pass.

A dashed edge between any two nodes, independent of the hierarchy. Tapping it
selects both ends, which is what turns it into a way of *doing* something: with
two nodes selected, Merge, Group and Move are already there.

## What already exists

Half of this shipped in v1 and can be reused rather than rebuilt:

- `[label](#heading-slug)` inside a node is already parsed as an `anchor` link
  (`md.extractLinks`), already resolved to a target node (`view.build`), and
  already **drawn as a dashed curve** (`drawEdges`).

What is missing is a way to create one without typing markdown, and any means of
touching the edge — today it is a `pointer-events: none` path with no hit
target at all.

## Decisions

| | |
|---|---|
| Creating | **Both** — `More ▸ Link to…` picker, and a **Link** button when exactly two nodes are selected |
| Storage | An **indented body line** under the source node |
| Direction | **One way in the markdown, drawn without direction** |
| Ambiguous label | **Link anyway, warn, resolve to the nearest** |

## The markdown

The source node keeps its label and gains one line beneath it:

```markdown
- Colors
  [→ Type](#type)
- Type
```

This is an ordinary markdown anchor link. Anything else reading the note sees a
link; Cartograph sees an edge. Nothing new is invented, and the `¶` body chip
already tells you the node carries something.

The `→` prefix is cosmetic — it makes the line read as a reference rather than a
stray link when the note is read as text. Resolution is by the URL, never the
label.

## Resolving the target

`anchors` is currently `slug → id`, last write wins, so two nodes labelled
"Colors" silently collide. It becomes `slug → [ids]`, resolved **per source** by
tree distance: the number of edges between the source and each candidate, via
their lowest common ancestor. Nearest wins; ties break on document order.

At creation time, if the chosen target's label is not unique, the link is still
written and a toast says so — the edge may point at the wrong twin until one is
renamed. That is the answer given: never block, but never be silent either.

## Keeping links alive through a rename

A link is bound to the target's text, so renaming the target breaks it. Renames
made **inside Cartograph** will carry their links: when a node's label changes,
any `](#old-slug)` in the note is rewritten to the new slug, and a `[→ Old]`
label to the new text.

Renames made in another editor still break the link — the slug simply stops
matching. That is inherent to text-addressed anchors, and the alternative
(invisible id anchors in the markdown) was rejected in v1 for good reasons. A
link whose target has vanished draws no edge; the line stays in the note as an
ordinary link.

## Touching the edge

Two hit targets, because a 1.5px curve is not tappable on a phone:

1. **A midpoint handle** — a small circle drawn at the curve's midpoint. This is
   the primary affordance: it makes links visible as *things* rather than
   decoration, and it is a comfortable 28px target.
2. **The curve itself** — a transparent ~22px stroke beneath the visible dash,
   with `pointer-events: stroke`. (`#edges` stays `pointer-events: none`; a
   child re-enabling its own pointer events still receives them.)

Tapping either: **enter select mode with both endpoints selected**, and frame
them both. The bottom bar is then the existing one — Merge, Group, Move, Split
— plus **Unlink**, which appears only when the two selected nodes are linked.

## Where the actions live

| Surface | Action |
|---|---|
| `More ▸ Link to…` | destination picker, same component as *Move to…* |
| Select mode, exactly 2 nodes | **Link** button |
| Select mode, 2 nodes already linked | **Unlink** replaces it |
| Tap a link handle | select both ends |

The picker excludes the node itself and any node it is already linked to;
unlike *Move to…* it does **not** exclude descendants or the parent, because
linking to your own child is meaningful even though moving there is not.

## Drawing

Visually distinct from hierarchy without becoming noisy: the existing dashed
curve, at a lower opacity than tree edges, in a neutral colour rather than the
branch tint — so it reads as crossing the structure rather than belonging to a
branch. The handle carries the same colour, filled, with a link glyph.

Cross-link edges dim with search filtering when neither end survives the filter,
which they currently do not.

## Risks

| Risk | Mitigation |
|---|---|
| A link silently points at the wrong twin | Warned at creation; nearest-match resolution makes the common case right |
| Renaming elsewhere breaks links | In-app renames carry their links; broken ones degrade to a plain link line, never an error |
| Deleting a node leaves a dangling link line | No edge is drawn; the line remains as ordinary markdown. Unlink from the surviving end cleans it up |
| Edges become clutter on a dense map | Neutral colour, low opacity, handles only at midpoints; links dim with filtering |
| Tap target fights panning | The handle is a discrete element; the fat invisible stroke only covers the curve itself |

## Testing

Deterministic first, as ever:

- link line written under the right node, label and slug correct
- a duplicate link is refused rather than written twice
- ambiguous slug resolves to the nearest of two same-named nodes, both directions
- tree distance is symmetric and correct across branches
- unlink removes exactly the link line and nothing else
- an in-app rename rewrites both the slug and the label
- a link to a deleted node draws no edge and does not throw
- a self-link is refused
- coverage stays clean after every one of the above

App level: create from the picker, create from a two-node selection, tap the
handle and confirm both ends end up selected with Merge available, unlink from
the bar, and confirm a link survives a rename made on the map.


---

## What shipped

Built as designed, with two deviations and two bugs found on the way.

### Deviations
- **No fat invisible stroke along the curve.** The plan called for the curve
  itself to be a second hit target, but `#edges` is a 1×1 SVG box relying on
  overflow, and hit-testing content outside an SVG viewport is not dependable
  across engines. The midpoint handle is the only target — and it is the better
  one on touch anyway.
- **Handles counter-scale.** Not in the plan, and necessary: the stage is
  scaled, so a 26px handle renders 16px at a readable zoom of 0.62 — below any
  touch-target guideline. Handles and collapse chips now hold a constant size on
  screen, clamped so they do not balloon when zoomed far out.

### Bugs found
- **`appendBodyLine` was folding links into the node's LABEL.** A line placed
  directly under a bullet with no blank line between is a CommonMark paragraph
  continuation, so it joined the label rather than becoming body. This was
  already happening to every attached note link — the label carried the raw
  markdown and only looked clean because the renderer stripped it back out.
  Items now get a blank line first.
- **A test asserted 26×26 and got 16×16**, which is what surfaced the scaling
  problem. Worth noting that measuring the *rendered* size rather than the CSS
  size is what caught it.

### Testing
- **117 module assertions**: link written to the body not the label; duplicate
  and self-links refused; link→unlink byte-exact in three shapes; a
  whitespace-only line inside a code fence surviving an unlink; nearest-twin
  resolution in both directions; distance symmetric; rename repointing anchors
  while leaving hand-written labels and same-named twins alone; a link to a
  deleted node drawing no edge.
- **112 app-level assertions**: the link picker's exclusions (which
  deliberately differ from Move to…), creating from the picker and from a
  two-node selection, tapping the handle through the real pointer path and
  confirming both ends end up selected with Merge available, unlinking from the
  bar, and a rename on the map carrying its link.
