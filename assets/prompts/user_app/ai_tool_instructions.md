
 AI TOOL APP SPECIFIC INSTRUCTIONS:
 This application must expose reusable tools that the AI can call headlessly and that users can try in an interactive playground.

 REQUIRED STRUCTURE:
 1. Put as the first <script></script> element of the <head> tag, a CDATA block that starts with `<![CDATA[tool_spec` and ends with `]]>`. Place the YAML array that describes every tool inside this block so that any characters (even `-->` or backticks) are preserved verbatim.

    Example:
    <!DOCTYPE HTML>
    <html>
      <head>
        <script type='text/javascript'>
        <![CDATA[tool_spec
        - name: example_tool
          description: |
            Describe what the tool does succinctly
          input_params:
            - query:
                type: string
                description: |
                  The search text
          output_params:
            - results:
                type: array
                items: string
        ]]>
	</script>
        <!-- The HTML, css and JavaScript in <head> tag goes there -->
      </head>
      <!-- body tag -->
    </html>

    IMPORTANT: the <![CDATA[tool_spec ]]> block MUST inside the first <script> tag.

 2. For every tool include:
    - name: Tool identifier (string, snake_case recommended)
    - description: |
	Concise explanation of what the tool does. IMPORTANT: Description should be placed with YAML quotation block. For example:
      <example>
      Good:
      description: |
        this is the descirption line so that I don't need to worry about special characters.

      Bad:
      description: the content is on the same line. Special character like {}, [] is a concern to the parser.
      </example>
    
   - input_params: Keys and schemas for accepted arguments (describe type, optional flag, enum values, etc.)
     * Mark optional parameters explicitly with `optional: true` (omit this field for required params). Do NOT rely on the description text to say "Optional".
    - output_params: Keys and schemas for returned fields the tool produces

 3. The YAML must be valid and free of extra commentary so it can be parsed automatically.

 RUNTIME BEHAVIOUR:
 1. Register each tool implementation in JavaScript as `window.Synapse.tool.registered.<tool_name> = (params) => { ... }`.
 2. Every registered function must return a JSON-serialisable object matching the declared output parameters.
 3. Detect `window.Synapse.tool.env.isInteractive`:
    - When `true`, render a UI playground that lets the user call the tools manually (forms, buttons, result display, etc.).
    - When `false`, skip the UI and only expose the tool functions for headless execution.
 4. Use `console` logging judiciously for debugging key steps.
 5. If user's intention requires manual configurations, such as setting up an API KEY, the playground is the right place to allow the
    uesr to set it up, and save to the application state, so that in AI headless calls, it can be loaded and used. AI tool call
    should NOT require user to input API KEY, unless directed by user. The playground should explicitly provide UI for user to test
    saving and loading app state.

 GENERAL REQUIREMENTS:
 - Keep the HTML fully self-contained (inline JS/CSS, or use provided Synapse user libraries only).
 - Validate user inputs, surface errors gracefully, and ensure return objects never throw.
 - Document tool usage and parameter expectations in comments or the interactive UI.
 - Use `Synapse.proxyFetch` when you must contact external HTTP APIs; remember to decode base64 results for non-text MIME types.
 - Tool functions are called with a single object parameter. The fields of the object MUST NOT be named `param` or `params`
   to avoid confusion to the caller. The param object has fields corresponding to the tool spec:

    <example>
    For the following tool spec:

    - name: example_tool
      description: |
        Describe what the tool does succinctly
      input_params:
        - query:
            type: string
            description: |
              The search text
        - year:
            type: int
            descirption: |
              The year to query
	    optional: true
      output_params:
        - results:
            type: array
            items: string

    It maps to the following function:

    window.Synapse.tool.registered.example_tool = (params) => { 
      const query = params.query;
      const year = params.year ? params.year : 1960;
      // code handling query and year...
    }
    </example>
 