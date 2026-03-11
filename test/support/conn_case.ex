defmodule ElixirNawalaWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ElixirNawalaWeb.Endpoint

      use Phoenix.VerifiedRoutes,
        endpoint: ElixirNawalaWeb.Endpoint,
        router: ElixirNawalaWeb.Router,
        statics: ElixirNawalaWeb.static_paths()

      import Plug.Conn
      import Phoenix.ConnTest
      import ElixirNawalaWeb.ConnCase
    end
  end

  setup tags do
    ElixirNawala.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
