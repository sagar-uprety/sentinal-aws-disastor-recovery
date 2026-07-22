## Stack

- **Infrastructure**: Terraform (AWS provider ~6.0)
- **Language**: Go

- Use Context7 MCP for latest docs when needed: syntax, latest version information, implementation details, and when stuck on a persistent error, an unexpected tool/CLI/API result, or before assuming something "just doesn't work." Verify the exact command/argument/endpoint against docs before concluding it's broken, rather than guessing or retrying blindly. If Context7 is unavailable or outdated, use web search for official docs.

- YOU MUST LOAD ALL MCP available to you at the start of the session and use the relevent one when needed. PREFER MCP over context7 when the MCP covers the official info of the tool.

- AWS MCP is read-only. AWS mutations are allowed only through reviewed repository Terraform GitHub Actions workflows or guarded scripts with explicit user approval. One explicit approval may cover a documented multi-step drill such as M6; stop and ask again only when observed state is unsafe, unexpected, or materially differs from the runbook.


- always work on feature branch and use conventional commits, commit message should be short and to the point human readable.

- You must always ask the user confirmation to check for code changes before committing

- Create PR using gh actions after each milestone is completed.

- Use single line comment for code blocks, functions, terraform resources etc. which you think needs explanation. super obvious things do not need any comment

- Use terraform style guide skill to understand terraform writing pattern!

- Always ask user if something is really off/confusing
