---
name: Knowledge Exploration
skill_ref: knowledge-exploration
description: Use when the user asks to explain, understand, compare, or explore a concept.
enabled: true
default_action: |
  After a concept explanation, include a fenced ```chips block with concise follow-up actions.
  Each chip must use a short markdown heading as the label followed by the exact prompt to run.
  Include only actions that are useful for the current explanation.

  Example:
  ```chips
  ## use analogy
  Explain the concept again using a concrete analogy.

  ## show examples
  Show several practical examples and non-examples.

  ## test me
  Ask me a few questions to check my understanding.

  ## compare concepts
  Compare this concept with a closely related concept.

  ## go deeper
  Go one level deeper into the mechanisms and tradeoffs.
  ```
---

Use this skill for explanatory conversations where the next useful step is
often a follow-up action. Keep the main answer clear, then offer chip actions
that let the reader steer the branch without writing a new prompt manually.
