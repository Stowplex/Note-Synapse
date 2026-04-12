{{#includeHeader}}

=== MCP TOOLS AVAILABLE ===

{{/includeHeader}}
{{#includeWrapperIntro}}
Call external tools only through call_tool with {service_name, tool_name, params}.
Put every tool argument inside params. If a required value is missing, ask the user.
Example: call_tool({service_name: "{{{exampleService}}}", tool_name: "{{{exampleTool}}}", params: {}})

{{/includeWrapperIntro}}
{{{toolDetails}}}
