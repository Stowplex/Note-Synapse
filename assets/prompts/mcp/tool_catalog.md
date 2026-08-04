{{#includeHeader}}

=== MCP TOOLS AVAILABLE ===

{{/includeHeader}}
{{#includeWrapperIntro}}
{{#preferDirectCalls}}
Call tools directly by their declared function name when a declaration exists (preferred — arguments are checked as you write them). For tools without their own declaration, use call_tool with {service_name, tool_name, params}, putting every tool argument inside params. If a required value is missing, ask the user.

{{/preferDirectCalls}}
{{^preferDirectCalls}}
Call external tools only through call_tool with {service_name, tool_name, params}.
Put every tool argument inside params. If a required value is missing, ask the user.
Example: call_tool({service_name: "{{{exampleService}}}", tool_name: "{{{exampleTool}}}", params: {}})

{{/preferDirectCalls}}
{{/includeWrapperIntro}}
{{{toolDetails}}}
