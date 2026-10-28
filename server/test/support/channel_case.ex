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

      # Import conveniences for testing with channels; subscribe_and_join
      # is ours, signing the socket in first (below)
      import Phoenix.ChannelTest, except: [subscribe_and_join: 3, subscribe_and_join: 4]
      import Phoenix.Socket
      import SoshWeb.ChannelCase
      require Phoenix.ChannelTest
    end
  end

  @doc """
  `Phoenix.ChannelTest.subscribe_and_join/4`, signed in first: as the
  account the params' `"name"` names (made if needed, confirmed), or as
  whoever the socket is already signed in as, or as "tester".
  """
  defmacro subscribe_and_join(socket, channel, topic, payload \\ Macro.escape(%{})) do
    quote do
      payload = unquote(payload)

      Phoenix.ChannelTest.subscribe_and_join(
        SoshWeb.ChannelCase.as_named(unquote(socket), payload),
        unquote(channel),
        unquote(topic),
        payload
      )
    end
  end

  def as_named(socket, payload) do
    case payload do
      %{"name" => name} -> as(socket, name)
      _ -> if socket.assigns[:account], do: socket, else: as(socket, "tester")
    end
  end

  @doc "The socket signed in as `handle` (trimmed, at most 16), made if new."
  def as(socket, handle) do
    handle =
      case handle |> to_string() |> String.trim() |> String.slice(0, 16) do
        "" -> "guest"
        h -> h
      end

    Phoenix.Socket.assign(socket, :account, account(handle))
  end

  @doc "A confirmed account, made if there isn't one (no real password: tests sign in by assigning)."
  def account(handle) do
    Sosh.Accounts.get_by_handle(handle) ||
      Sosh.Repo.insert!(%Sosh.Accounts.User{
        email: "#{String.downcase(handle)}@test.local",
        handle: handle,
        hashed_password: "x",
        confirmed_at: DateTime.utc_now(:second)
      })
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
    Sosh.RateLimit.reset()
    Sosh.Universes.create({0, 0}, "sea", 7)
    Sosh.Universes.create({1, 0}, "land", 7)
    {:ok, socket} = Phoenix.ChannelTest.connect(SoshWeb.UserSocket, %{})
    {:ok, socket: socket}
  end
end
