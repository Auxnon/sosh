defmodule SoshWeb.ChannelCase do
  @moduledoc """
  This module defines test case to be used by
  channel tests.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures and query the channel layer.
  """

  use ExUnit.CaseTemplate

  # `connect/3` is a macro that reads @endpoint from the calling module, so the
  # setup below needs both here, not just inside `using`.
  require Phoenix.ChannelTest
  @endpoint SoshWeb.Endpoint

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

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Sosh.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  # Setup hooks for channel tests
  setup tags do
    :ok = Application.ensure_started(:sosh)
    # Universes, Sosh.Lobby and Sosh.Players are app-wide processes, so the
    # sandbox is shared and channel tests must not be async. Every test
    # starts with a fresh grid: (0, 0), the plaza, and (1, 0) east of it.
    Sosh.Sim.stop_all()
    SoshWeb.ChannelCase.setup_sandbox(tags)
    Enum.each(Sosh.Lobby.list(), &Sosh.Lobby.delete(&1.user_id))
    Sosh.Players.reset()
    Sosh.Universes.create({0, 0}, "sea", 7)
    Sosh.Universes.create({1, 0}, "land", 7)
    {:ok, socket} = Phoenix.ChannelTest.connect(SoshWeb.UserSocket, %{})
    {:ok, socket: socket}
  end
end
