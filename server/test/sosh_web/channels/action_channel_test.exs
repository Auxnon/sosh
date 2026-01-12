defmodule SoshWeb.ActionChannelTest do
  use SoshWeb.ChannelCase, async: true

  describe "join" do
    test "joins actions:lobby successfully with authenticated user", %{socket: socket} do
      socket = assign(socket, :user_id, UUID.uuid4())

      {:ok, _, socket} =
        socket
        |> subscribe_and_join(SoshWeb.ActionChannel, "actions:lobby")

      assert socket.assigns[:user_id]
    end

    test "rejects join without user_id" do
      socket = Phoenix.ChannelTest.connect(SoshWeb.UserSocket, %{}, %{})

      {:error, %{reason: "not_authenticated"}} =
        subscribe_and_join(socket, SoshWeb.ActionChannel, "actions:lobby")
    end
  end

  describe "dig_action" do
    test "dig_action with valid position and face succeeds", %{socket: socket} do
      socket = assign(socket, :user_id, UUID.uuid4())

      ref = push(socket, "dig_action", %{"position" => [0, 0, 0], "face" => "top"})

      assert_reply(ref, :ok, %{status: "success", action_type: "dig"})
      assert_broadcast("terrain_changed", %{action: "dig"})
    end
  end
end
