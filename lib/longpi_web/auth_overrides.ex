defmodule LongpiWeb.AuthOverrides do
  use AshAuthentication.Phoenix.Overrides

  # configure your UI overrides here

  # First argument to `override` is the component name you are overriding.
  # The body contains any number of configurations you wish to override
  # Below are some examples

  # For a complete reference, see https://hexdocs.pm/ash_authentication_phoenix/ui-overrides.html

  # Longpi branding instead of the default Ash Framework banner.
  override AshAuthentication.Phoenix.Components.Banner do
    set :image_url, nil
    set :dark_image_url, nil
    set :text, "π Longpi"
    set :text_class, "text-3xl font-semibold tracking-wide text-base-content"
  end

  # Password sign-in is the only visible strategy; the trailing "or" divider
  # (rendered for the api_key strategy, which has no form) is just noise.
  override AshAuthentication.Phoenix.Components.HorizontalRule do
    set :root_class, "hidden"
  end
end
