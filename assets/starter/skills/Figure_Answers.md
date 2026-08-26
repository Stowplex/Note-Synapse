---
name: Figure Answers
skill_ref: figure-answers
description: Use whenever a reply could show something visual — a diagram, table, chart, screenshot or photo — so an existing figure from the user's notes is found and embedded instead of described or generated.
enabled: true
---

The user's notes already contain figures: regions cropped out of PDFs, images
they attached, screenshots they clipped.
[search_figures](notesynapse://tool/builtin/search_figures) retrieves them. A
retrieved figure is the user's own material, it is instant, and it costs
nothing to create — generating a picture is none of those things.

## Call `search_figures` when

- You are about to generate an image. Search first, every time.
- The user asks about a diagram, table, chart, screenshot, figure or photo —
  or asks "show me", "what does it look like", "which one is it".
- You are explaining something one of their stored figures shows: an
  architecture, a workflow, a comparison table, a plot, a UI screen.
- You are summarising a paper, report or clipped page whose argument is
  carried by a figure.

Pass the words a caption would use plus the subject (`"transformer
architecture diagram"`, not `"diagram"`). Add `noteId` when the conversation
is already about one note. Ask for a small `limit` — you will embed one or
two figures, not five.

## Choosing among the hits

1. Prefer a `FIGURE` hit over a `PAGE` or `LINK` hit: a figure is the actual
   visual, the others are only pointers.
2. Prefer the hit whose caption answers the question over the hit that merely
   comes from the right note.
3. Prefer a figure from a note the user is already discussing.
4. Embed one figure, two at most. A wall of images answers nothing.

## Embedding

Use the markdown line the tool gives you, verbatim — the URI is
content-addressed and cannot be reconstructed by hand.

- `FIGURE` and `IMAGE` hits are images: `![caption](synapseresource://...)`.
- `PAGE` and `LINK` hits are links: `[Note title, p.4](synapseresource://...)`.
  Never turn one into an image. A whole page renders as an unreadable
  thumbnail, and a `LINK` hit is something that cannot be drawn inline at all
  (the hit says which). The link opens the real thing in the viewer.

Rewrite the caption in the alt text so it describes what the reader is about
to see (`![Encoder-decoder layout of the Transformer](...)`), and keep it
short. Never invent a `synapseresource://` URI, never edit the id inside one,
and never present a figure as your own illustration.

## Provenance

Name the source in the sentence around the figure: *from "Attention Is All
You Need", p.3*. Use the note title and page the tool reported — do not guess
a page. Tapping the figure takes the user to that page, so the citation and
the tap must agree.

## When nothing matches

First read the tool's `Index:` line. **If it is there at all, you did not get
an answer — you got a non-answer.** The index was still being built, or could
not be queried on this device, so nothing was searched properly. Say the
search could not complete, never that the figure is missing, and offer to try
again once indexing finishes. Do not offer to generate an image instead — you
have no idea yet whether the user already owns the picture.

If there is no `Index:` line, the search really did run. Say so plainly: "I
did not find a figure about X in your notes." Then:

- Read the `Scope:` line. An open search never looks in archived notes; if
  the user is thinking of something they archived, say so and offer to search
  that note by name (`noteId` includes its archived figures).
- Read the `Layers off:` line and mention only the layers it lists as off, in
  the user's terms — e.g. figure extraction being off explains why a PDF's
  diagrams are not findable; no embedding provider means figures are matched
  on caption and OCR text only, so wording matters.
- If that line says `none` and there is no `Index:` line, do not speculate
  about indexing at all — the figure simply is not there.
- Answer in words instead, or offer to look in a specific note.
- Do not quietly generate an image as a substitute. Generating one is a
  separate, expensive step the user should choose: offer it, and wait for a
  yes.

## Cost

Retrieval reads an index the app already keeps, and returns something the
user has already seen. It is cheap even when an embedding provider bills for
the query. Image generation costs real money and time, and produces something
the user never saw before. Retrieve first; generate only when the user asks
for something new that no stored figure can show.
