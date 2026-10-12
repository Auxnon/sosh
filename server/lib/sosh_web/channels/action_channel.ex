defmodule SoshWeb.ActionChannel do
  use Phoenix.Channel
  require Logger

  alias Sosh.{Lobby, Sim, World}

  # Joining replies with the living world (Sosh.Sim.snapshot/0): every cow
  # and crop. Updates then arrive as `cows`, `moo` and `crop` broadcasts.
  def join("actions:lobby", _params, socket) do
    if socket.assigns[:user_id] do
      {:ok, Sim.snapshot(), socket}
    else
      {:error, %{reason: "not_authenticated"}}
    end
  end

  # World edits and chunk fetches. Positions are integer block coordinates
  # (Z-up, a block at z spans [z, z+1]); see Sosh.World.

  @reach 7
  @max_chunks_per_request 48
  @grass 1
  @dirt 2

  def handle_in("get_chunks", %{"keys" => keys}, socket) when is_list(keys) do
    chunks =
      keys
      |> Enum.take(@max_chunks_per_request)
      |> Enum.flat_map(fn
        [cx, cy, cz] when is_integer(cx) and is_integer(cy) and is_integer(cz) ->
          [%{key: [cx, cy, cz], rle: World.rle(World.chunk({cx, cy, cz}))}]

        _ ->
          []
      end)

    {:reply, {:ok, %{chunks: chunks}}, socket}
  end

  def handle_in("dig_action", %{"position" => pos}, socket) do
    with {:ok, [x, y, z]} <- validate_block_position(pos),
         :ok <- within_reach(socket, x, y, z),
         {:ok, current} <- diggable(World.block(x, y, z)),
         {:ok, _} <- World.put_block(x, y, z, 0) do
      # whatever grew on it goes too
      Sim.uproot({x, y, z + 1})
      changed(socket, [x, y, z], "air", current)
    else
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("place_action", %{"position" => pos, "block_type" => block_type}, socket) do
    with {:ok, [x, y, z]} <- validate_block_position(pos),
         {:ok, id} <- validate_block_type(block_type),
         :ok <- within_reach(socket, x, y, z),
         :ok <- free(World.block(x, y, z)),
         :ok <- no_crop(x, y, z),
         {:ok, _} <- World.put_block(x, y, z, id) do
      changed(socket, [x, y, z], block_type, nil)
    else
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # Plant a carrot in the air cell `position`, on grass or dirt; grass under
  # it is tilled to dirt. It grows on its own (Sosh.Sim).
  def handle_in("plant_action", %{"position" => pos}, socket) do
    with {:ok, [x, y, z]} <- validate_block_position(pos),
         :ok <- within_reach(socket, x, y, z),
         :ok <- if(World.block(x, y, z) == 0, do: :ok, else: {:error, "occupied"}),
         {:ok, soil} <- soil(World.block(x, y, z - 1)),
         :ok <- Sim.plant({x, y, z}) do
      if soil == @grass do
        {:ok, _} = World.put_block(x, y, z - 1, @dirt)
        changed(socket, [x, y, z - 1], "dirt", soil)
      end

      {:reply, {:ok, %{position: [x, y, z]}}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  # Pick the ripe crop in `position`.
  def handle_in("harvest_action", %{"position" => pos}, socket) do
    with {:ok, [x, y, z]} <- validate_block_position(pos),
         :ok <- within_reach(socket, x, y, z),
         {:ok, _} <- Sim.harvest({x, y, z}) do
      {:reply, {:ok, %{position: [x, y, z], item: "carrot"}}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in(
        "drop_item",
        %{"item_id" => item_id, "quantity" => qty, "position" => pos},
        socket
      ) do
    action_id = UUID.uuid4()
    user_id = socket.assigns.user_id

    with {:ok, validated_pos} <- validate_position(pos),
         {:ok, validated_qty} <- validate_quantity(qty),
         {:ok, validated_item_id} <- validate_item_id(item_id) do
      case perform_drop_action(user_id, validated_item_id, validated_qty, validated_pos) do
        {:ok, result} ->
          push(socket, "action_complete", %{
            action_id: to_string(action_id),
            status: "success",
            action_type: "drop",
            item_id: validated_item_id,
            quantity: validated_qty,
            position: validated_pos,
            result: result
          })

          broadcast!(socket, "item_dropped", %{
            user_id: to_string(user_id),
            item_id: validated_item_id,
            quantity: validated_qty,
            position: validated_pos,
            timestamp: System.system_time(:millisecond)
          })

          {:noreply, socket}

        {:error, reason} ->
          push(socket, "action_failed", %{
            action_id: to_string(action_id),
            status: "error",
            action_type: "drop",
            reason: reason
          })

          {:noreply, socket}
      end
    else
      {:error, reason} ->
        push(socket, "action_failed", %{
          action_id: to_string(action_id),
          status: "error",
          action_type: "drop",
          reason: "validation_failed: #{reason}"
        })

        {:noreply, socket}
    end
  end

  def handle_in("pickup_item", %{"item_id" => item_id}, socket) do
    action_id = UUID.uuid4()
    user_id = socket.assigns.user_id

    with {:ok, validated_item_id} <- validate_item_id(item_id) do
      case perform_pickup_action(user_id, validated_item_id) do
        {:ok, result} ->
          push(socket, "action_complete", %{
            action_id: to_string(action_id),
            status: "success",
            action_type: "pickup",
            item_id: validated_item_id,
            result: result
          })

          broadcast!(socket, "item_picked_up", %{
            user_id: to_string(user_id),
            item_id: validated_item_id,
            timestamp: System.system_time(:millisecond)
          })

          {:noreply, socket}

        {:error, reason} ->
          push(socket, "action_failed", %{
            action_id: to_string(action_id),
            status: "error",
            action_type: "pickup",
            reason: reason
          })

          {:noreply, socket}
      end
    else
      {:error, reason} ->
        push(socket, "action_failed", %{
          action_id: to_string(action_id),
          status: "error",
          action_type: "pickup",
          reason: "validation_failed: #{reason}"
        })

        {:noreply, socket}
    end
  end

  defp validate_position(pos) when is_list(pos) and length(pos) == 3 do
    case Enum.all?(pos, &is_number/1) do
      true -> {:ok, pos}
      false -> {:error, "invalid_position_format"}
    end
  end

  defp validate_position(_), do: {:error, "invalid_position_format"}

  defp validate_block_type(block_type) when is_binary(block_type) do
    if block_type in World.placeable(),
      do: {:ok, World.block_ids()[block_type]},
      else: {:error, "invalid_block_type"}
  end

  defp validate_block_type(_), do: {:error, "invalid_block_type"}

  defp validate_quantity(qty) when is_number(qty) and qty > 0, do: {:ok, qty}
  defp validate_quantity(_), do: {:error, "invalid_quantity"}

  defp validate_item_id(item_id) when is_binary(item_id) and byte_size(item_id) > 0,
    do: {:ok, item_id}

  defp validate_item_id(_), do: {:error, "invalid_item_id"}

  defp perform_drop_action(user_id, item_id, quantity, position) do
    Logger.info(
      "DROP action: User #{user_id} item #{item_id} qty #{quantity} at #{inspect(position)}"
    )

    # Basic implementation
    {:ok,
     %{
       item_dropped: item_id,
       quantity: quantity,
       position: position
     }}
  end

  defp perform_pickup_action(user_id, item_id) do
    Logger.info("PICKUP action: User #{user_id} item #{item_id}")

    # Basic implementation
    {:ok,
     %{
       item_picked_up: item_id
     }}
  end

  defp changed(socket, [x, y, z] = pos, block_type, _previous) do
    Sim.block_changed({x, y, z}, World.block_ids()[block_type])

    broadcast!(socket, "block_changed", %{
      user_id: to_string(socket.assigns.user_id),
      position: pos,
      block: World.block_ids()[block_type],
      block_type: block_type
    })

    {:reply, {:ok, %{position: pos, block_type: block_type}}, socket}
  end

  defp validate_block_position([x, y, z] = pos)
       when is_integer(x) and is_integer(y) and is_integer(z),
       do: {:ok, pos}

  defp validate_block_position(_), do: {:error, "invalid_position_format"}

  # Measured from the player's last reported position (Sosh.Lobby).
  defp within_reach(socket, x, y, z) do
    case Enum.find(Lobby.list(), &(&1.user_id == socket.assigns.user_id)) do
      %{vec: [px, py, pz]} ->
        dx = x + 0.5 - px
        dy = y + 0.5 - py
        dz = z + 0.5 - pz
        if dx * dx + dy * dy + dz * dz <= @reach * @reach, do: :ok, else: {:error, "out_of_reach"}

      nil ->
        {:error, "not_in_world"}
    end
  end

  defp diggable(0), do: {:error, "nothing_there"}
  defp diggable(6), do: {:error, "cannot_dig_water"}
  defp diggable(id), do: {:ok, id}

  defp soil(id) when id in [@grass, @dirt], do: {:ok, id}
  defp soil(_), do: {:error, "needs_soil"}

  defp no_crop(x, y, z),
    do: if(Sim.crop({x, y, z}), do: {:error, "occupied"}, else: :ok)

  # Placing into air or water; anything else is occupied.
  defp free(id) when id in [0, 6], do: :ok
  defp free(_), do: {:error, "occupied"}
end
