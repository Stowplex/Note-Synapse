Create a single-page self-contained HTML application based on the following requirements:

App Name: {{{name}}}
Description: {{{description}}}
Steps: 
- {{{stepsJoined}}}

{{#uiLanguageTag}}
Current Note Synapse UI language: {{{uiLanguageTag}}}
Write your explanation in this language and make its dictionary entry complete.
{{/uiLanguageTag}}

{{{librariesSection}}}
{{{noteContextSection}}}

IMPORTANT - REQUIREMENTS:
1. The HTML must be completely self-contained with embedded CSS and JavaScript
2. Do not reference any external resources
3. Document the purpose, requirements, and approach in comments
4. Use the following APIs to interact with the Flutter app, generated code should strictly follow the API parameter types.
{{{apiDocumentation}}}

{{{librariesFromService}}}
{{{requirementsSection}}}

{{{databaseSchema}}}

{{{typeSpecificInstructions}}}

Generate the complete HTML application now.

IMPORTANT: Your response must be formatted as follows:
1. First, provide a brief explanation of the application and its features
2. Then, provide the complete HTML code wrapped in ```html code blocks

Example format:
Here's the complete HTML application:

[Brief explanation of the application and its features]

```html
<!DOCTYPE html>
<html>
<head>
    <!-- Complete HTML code here -->
</head>
<body>
    <!-- Complete HTML code here -->
</body>
</html>
```
{{#hasAddendum}}

User-defined guidance:
{{{addendum}}}
{{/hasAddendum}}
