
Analyze the following list of tags and suggest deduplication rules to consolidate similar or redundant tags. 

Tags: {{{tagsJoined}}}{{#hasProtectedTags}}
        
PROTECTED TAGS (filter tags - must NOT appear as leftTag in any rule):
{{{protectedTagsJoined}}}

CRITICAL: These protected tags are used by filters and MUST NOT be replaced. They can only appear as rightTag (the replacement target), never as leftTag (the tag being replaced).{{/hasProtectedTags}}

Please suggest rules in the format "leftTag -> rightTag" where:
- leftTag is the tag that should be replaced
- rightTag is the tag that should replace it

Rules to follow:
1. No tag should appear as leftTag in multiple rules (each tag can only be replaced once)
2. No tag should appear as both leftTag in one rule and rightTag in another rule (no cross-references)
3. Do not suggest self-replacement (A -> A)
4. It IS allowed for a tag to appear as rightTag in multiple rules (consolidating multiple tags into one)
5. Focus on consolidating similar tags, typos, or variations
6. Prefer shorter, more standard tag names
7. Consider semantic similarity (e.g., "work" and "job" could be consolidated)
{{#hasProtectedTags}}8. PROTECTED TAGS must NEVER appear as leftTag - they can only appear as rightTag{{/hasProtectedTags}}

Please respond with a JSON array of objects in this format:
[
  {"leftTag": "old_tag_name", "rightTag": "new_tag_name"},
  {"leftTag": "another_old_tag", "rightTag": "another_new_tag"}
]

IMPORTANT: Ensure all tag names are properly escaped for valid JSON (escape special characters like backslashes and quotes).

Only suggest rules that would genuinely improve tag organization. If no meaningful consolidations are possible, return an empty array.
