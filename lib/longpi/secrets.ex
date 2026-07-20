defmodule Longpi.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Longpi.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:longpi, :token_signing_secret)
  end
end
