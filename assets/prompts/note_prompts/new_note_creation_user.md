Use the provided note context (previous message) and the instruction below to create new notes.

User Prompt: "{{{userInstruction}}}"

Return a single JSON object with the following structure:
{{{jsonSchema}}}

Critical JSON rules:
1. The response must be valid JSON with no additional commentary.
2. Escape all quotes, backslashes, newlines, and control characters.
3. When using LaTeX (e.g., \( E = mc^2 \)), double-escape backslashes (\\) to keep JSON valid.
4. Preserve arrays even when empty (e.g., "tags": []).

Additional requirements:
- Calculate relative dates (e.g., "next Wednesday") using the current date/time provided in the system message.
- Ensure each generated note relates to the user prompt and the supplied context hierarchy.
- Reference note relationships (answers, causality, related, etc.) when deciding how new notes connect.
- Follow the LaTeX formatting guidance from the system message when including formulas.
{{#hasAddendum}}

{{{addendum}}}
{{/hasAddendum}}
