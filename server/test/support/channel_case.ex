defmodule ChatTestWeb.ChannelCase do
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
      @endpoint ChatTestWeb.Endpoint

      use ChatTestWeb, :verified_routes

      # Import conveniences for testing with channels
      import Phoenix.ChannelTest
      import Phoenix.Socket
      import ChatTestWeb.ChannelCase
      require Phoenix.ChannelTest
    end
  end

  # Setup hooks for channel tests
  setup _tags do
    :ok = Application.ensure_started(:chat_test)
    {:ok, socket: Phoenix.ChannelTest.connect(ChatTestWeb.UserSocket, %{}, %{})}
  end
end
