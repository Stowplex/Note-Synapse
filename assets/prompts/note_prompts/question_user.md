Question: "{{{question}}}"
{{#hasContextNotes}}
Base your answer on the supplied note context.
{{/hasContextNotes}}
{{^hasContextNotes}}
No note context is provided. Use the system guidance to determine how to answer.
{{/hasContextNotes}}
{{#useOwnKnowledge}}
Supplement with general knowledge only when it clarifies gaps, and identify assumptions.
{{/useOwnKnowledge}}
{{^useOwnKnowledge}}
Do not rely on information outside the provided materials.
{{/useOwnKnowledge}}
If the answer cannot be found, state explicitly that the information is unavailable.
