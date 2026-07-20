defmodule Longpi.Accounts do
  use Ash.Domain, otp_app: :longpi, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Longpi.Accounts.Token
    resource Longpi.Accounts.User
    resource Longpi.Accounts.ApiKey
  end
end
