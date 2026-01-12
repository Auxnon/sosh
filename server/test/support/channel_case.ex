defmodule SoshWeb.ChannelCase do
  @moduledoc """
  This module defines test case to be used by
  channel tests.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures and query the channel layer.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SoshWeb.Endpoint

      use SoshWeb, :verified_routes

      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import Phoenix.Socket
      import SoshWeb.ChannelCase
      require Phoenix.ChannelTest
    end
  end

  # Setup hooks for channel tests
  setup _tags do
    :ok = Application.ensure_started(:sosh)
    {:ok, socket: Phoenix.ChannelTest.connect(SoshWeb.UserSocket, %{}, %{})}
  end
end
