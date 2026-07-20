defmodule LongpiWeb.AshTypescriptRpcController do
  use LongpiWeb, :controller

  def run(conn, params) do
    result = AshTypescript.Rpc.run_action(:longpi, conn, params)
    json(conn, result)
  end

  def validate(conn, params) do
    result = AshTypescript.Rpc.validate_action(:longpi, conn, params)
    json(conn, result)
  end
end
