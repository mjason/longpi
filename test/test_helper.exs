Mox.defmock(Longpi.Agent.LLM.Mock, for: Longpi.Agent.LLM)

# :live_llm tests hit real provider APIs; run with: mix test --include live_llm
ExUnit.start(exclude: [:live_llm])
Ecto.Adapters.SQL.Sandbox.mode(Longpi.Repo, :manual)
