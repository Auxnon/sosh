defmodule ChatTestWeb.ActionChannel do
  use Phoenix.Channel
  require Logger

  def join("actions:lobby", _params, socket) do
    if socket.assigns[:user_id] do
      {:ok, socket}
    else
      {:error, %{reason: "not_authenticated"}}
    end
  end

  def handle_in("dig_action", %{"position" => pos, "face" => face}, socket) do
    action_id = UUID.uuid4()
    user_id = socket.assigns.user_id

    with {:ok, validated_pos} <- validate_position(pos),
         {:ok, validated_face} <- validate_face(face) do
      case perform_dig_action(user_id, validated_pos, validated_face) do
        {:ok, result} ->
          push(socket, "action_complete", %{
            action_id: to_string(action_id),
            status: "success",
            action_type: "dig",
            position: validated_pos,
            face: validated_face,
            result: result
          })

          broadcast!(socket, "terrain_changed", %{
            user_id: to_string(user_id),
            action: "dig",
            position: validated_pos,
            face: validated_face,
            result: result,
            timestamp: System.system_time(:millisecond)
          })

          {:noreply, socket}

        {:error, reason} ->
          push(socket, "action_failed", %{
            action_id: to_string(action_id),
            status: "error",
            action_type: "dig",
            reason: reason
          })

          {:noreply, socket}
      end
    else
      {:error, reason} ->
        push(socket, "action_failed", %{
          action_id: to_string(action_id),
          status: "error",
          action_type: "dig",
          reason: "validation_failed: #{reason}"
        })

        {:noreply, socket}
    end
  end

  def handle_in("place_action", %{"position" => pos, "block_type" => block_type}, socket) do
    action_id = UUID.uuid4()
    user_id = socket.assigns.user_id

    with {:ok, validated_pos} <- validate_position(pos),
         {:ok, validated_block_type} <- validate_block_type(block_type) do
      case perform_place_action(user_id, validated_pos, validated_block_type) do
        {:ok, result} ->
          push(socket, "action_complete", %{
            action_id: to_string(action_id),
            status: "success",
            action_type: "place",
            position: validated_pos,
            block_type: validated_block_type,
            result: result
          })

          broadcast!(socket, "terrain_changed", %{
            user_id: to_string(user_id),
            action: "place",
            position: validated_pos,
            block_type: validated_block_type,
            result: result,
            timestamp: System.system_time(:millisecond)
          })

          {:noreply, socket}

        {:error, reason} ->
          push(socket, "action_failed", %{
            action_id: to_string(action_id),
            status: "error",
            action_type: "place",
            reason: reason
          })

          {:noreply, socket}
      end
    else
      {:error, reason} ->
        push(socket, "action_failed", %{
          action_id: to_string(action_id),
          status: "error",
          action_type: "place",
          reason: "validation_failed: #{reason}"
        })

        {:noreply, socket}
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

  defp validate_face(face) when face in ["top", "bottom", "north", "south", "east", "west"],
    do: {:ok, face}

  defp validate_face(_), do: {:error, "invalid_face"}

  defp validate_block_type(block_type) when block_type in ["stone", "dirt", "grass", "wood"],
    do: {:ok, block_type}

  defp validate_block_type(_), do: {:error, "invalid_block_type"}

  defp validate_quantity(qty) when is_number(qty) and qty > 0, do: {:ok, qty}
  defp validate_quantity(_), do: {:error, "invalid_quantity"}

  defp validate_item_id(item_id) when is_binary(item_id) and byte_size(item_id) > 0,
    do: {:ok, item_id}

  defp validate_item_id(_), do: {:error, "invalid_item_id"}

  defp perform_dig_action(user_id, position, face) do
    Logger.info("DIG action: User #{user_id} at #{inspect(position)} face #{face}")

    # For now, basic implementation - will integrate with Rust NIF later
    {:ok,
     %{
       block_removed: "dirt",
       items_dropped: [%{item_id: "dirt_block", quantity: 1}],
       new_block_state: "air"
     }}
  end

  defp perform_place_action(user_id, position, block_type) do
    Logger.info("PLACE action: User #{user_id} at #{inspect(position)} type #{block_type}")

    # Basic implementation - will integrate with Rust NIF later
    {:ok,
     %{
       block_placed: block_type,
       position: position
     }}
  end

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
end
