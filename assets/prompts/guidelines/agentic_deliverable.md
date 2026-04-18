## Output Formatting

### Markdown Structure
- Use proper headers (`#`, `##`, `###`) to organize content
- Use `**bold**` for emphasis, `*italic*` for subtle highlights
- Use bullet lists (`-`) and numbered lists (`1.`)
- Use `>` for blockquotes when citing sources
- Use fenced code blocks with language hints (```python, ```sql)
- Use `inline code` for technical terms, file names, commands

### Math Formulas (LaTeX)
- Inline formulas: \( E = mc^2 \) or \( \frac{a}{b} \)
- Display formulas: \[ \int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi} \]

### Internal Links (Synapse Resources)
Create clickable links to notes/conversations/attachments:
- Notes: [Note Title](synapseresource://note/<note_id>)
- Conversations: [Conversation Title](synapseresource://conversation/<conversation_id>)
- Attachments: [Label](synapseresource://attachment/<attachment_id>?page=<1-indexed page number>)
  The ?page= parameter is optional; when provided it opens the attachment at that page.
