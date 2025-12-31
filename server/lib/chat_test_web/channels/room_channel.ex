defmodule ChatTestWeb.RoomChannel do
  use Phoenix.Channel

  # def join("room:lobby", _message, socket) do
  #   {:ok, socket}
  # end

  defp generate() do
    Enum.map(1..3, fn _x -> :rand.uniform() * 20 - 10 end)
  end

  def join("room:lobby", param, socket) do
    IO.inspect(param)
    %{"greet"=> greet, "vec"=> vec} = param
    user_id=UUID.uuid4()

    IO.puts("join worked, #{user_id}")
    # IO.puts("join vec, #{vec}")
    IO.inspect(vec)
    socket = assign(socket, :user_id, user_id)
    

    self() |> send( {:after_join, Map.put(param , :user_id,user_id) })
    # broadcast!(socket, "joined", %{user_id: user_id, vec: vec})

    IO.puts("after join 1")
    # test=ChatTest.Universe.add(1,2)
    # test |> IO.puts

    {:ok,
     %{
       connection_id: socket.assigns.connection_id,
       user_id: socket.assigns.user_id
     }, socket}
  end

  def handle_info({:after_join, params}, socket) do
    IO.puts("after join 2( #{2} )")
    IO.inspect(params)
    # push(socket, "handshake", %{user_id: socket.assigns.user_id})
    broadcast!(socket, "joined", params)
    {:noreply, socket}
  end

  def join("room:" <> _private_room_id, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  # Add a method to generate new numbers on demand
  def handle_in("get_update", _payload, socket) do
    push(socket, "refresh", %{numbers: generate()})
    {:noreply, socket}
  end

  def handle_in("new_msg", %{"body" => body}, socket) do
    broadcast!(socket, "new_msg", %{body: body, user_id: socket.assigns.user_id})
    {:noreply, socket}
  end

  def handle_in("move", %{"vec" => vec}, socket) do
    # ChatTest.Universe.move_ent(universe, 
    broadcast!(socket, "move", %{vec: vec, user_id: socket.assigns.user_id})
    {:noreply, socket}
  end

  def handle_in("animation", %{"animation" => animation}, socket) do
    broadcast!(socket, "animation", %{animation: animation, user_id: socket.assigns.user_id})
    {:noreply, socket}
  end

  def handle_in("face", %{"face" => face}, socket) do
    broadcast!(socket, "face", %{face: face, user_id: socket.assigns.user_id})
    {:noreply, socket}
  end
end
