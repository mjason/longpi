<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->

<!-- Custom project rules below (outside the usage_rules block so they survive `mix usage_rules` regeneration). -->

## Frontend UI: shadcn/ui + assistant-ui only — do NOT hand-roll

The web UI (`assets/js`, React + TypeScript + Tailwind, bundled by esbuild) is built from **two component libraries and nothing else**. Hand-rolling one-off components is the main cause of visual inconsistency — don't do it. Before building any UI, find the component that already exists.

- **shadcn/ui** — base primitives. Vendored in `assets/js/components/ui/*` (button, dialog, popover, command, tooltip, input, scroll-area, avatar, collapsible, skeleton, textarea, …). These are **Radix-based** (`asChild`, NOT base-ui `render`).
- **assistant-ui** — everything chat/agent: thread, composer, messages, tool calls, attachments, reasoning, model selector, context display, diff viewer, markdown/streamdown. Vendored in `assets/js/components/assistant-ui/*`.

**Rules**
- Need a primitive (button, menu, dialog, popover, tabs, …)? Use or add a **shadcn** component. Never build your own.
- Need chat/agent UI (tool group, attachment tile, reasoning block, model picker, context meter, …)? Use an **assistant-ui** component. If it needs a runtime, feed data via **props/adapters** — do not rebuild the component.
- If a suitable component doesn't exist, **vendor the official one**, then adapt it — don't write from scratch.
- **No hard/black 1px borders** on floating surfaces or tiles (they read as stark lines, especially in dark mode). Use a soft `ring-1 ring-black/[0.06] dark:ring-white/[0.08]` + a diffuse shadow, matching `model-selector.tsx`. Structural layout borders (sidebar edge, header bottom, form inputs) are fine.
- **`render` vs `asChild` gotcha**: this project's `components/ui/*` are Radix. Passing a base-ui `render={<.../>}` prop to a Radix `Trigger` leaks `render="[object Object]"` to the DOM and drops the element's classes (breaks styling/alignment). Vendored assistant-ui components that use base-ui tooltips must be converted to `<Trigger asChild><el …/></Trigger>`.

### Adding / discovering components

**shadcn** (CLI, docs, registry, MCP):
- Add: `npx shadcn@latest add <component>` (e.g. `button`, `dropdown-menu`, `tabs`).
- Docs: `https://ui.shadcn.com/docs/components/<name>` ; registry JSON: `https://ui.shadcn.com/r/styles/new-york/<name>.json`.
- MCP (browse/search/install by prompt): `.mcp.json` server `shadcn` → `npx shadcn@latest mcp` (already configured; run `/mcp` to verify).

**assistant-ui** (AI docs, registry, skills, MCP):
- Full docs for LLMs: `https://www.assistant-ui.com/llms-full.txt` ; per page: append `.md` to any docs URL.
- Vendor a component: `curl -s https://r.assistant-ui.com/base/<name>.json` (then place under `components/assistant-ui/`).
- **Claude Code skills**: `npx skills add assistant-ui/skills` → `/assistant-ui`, `/primitives`, `/runtime`, `/tools`, `/streaming`, `/thread-list`, `/setup`, `/update`.
- MCP (docs + examples): `.mcp.json` server `assistant-ui` → `npx -y @assistant-ui/mcp-docs-server` (already configured; tools `assistantUIDocs`, `assistantUIExamples`). Or `claude mcp add assistant-ui -- npx -y @assistant-ui/mcp-docs-server`.

Prefer the MCP servers / skills to look up the right component and its API before writing code.
