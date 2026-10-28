defmodule SoshWeb.Api.Json do
  @moduledoc "Replies for the API controllers: `{:error, reason}`s and changesets as JSON."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @statuses %{
    signed_out: 401,
    bad_login: 401,
    unconfirmed: 403,
    forbidden: 403,
    banned: 403,
    not_yours: 403,
    rate_limited: 429,
    no_such_user: 404,
    no_such_server: 404,
    no_such_message: 404,
    no_such_gift: 404,
    no_such_conversation: 404
  }

  def ok(conn, body \\ %{ok: true}), do: json(conn, body)

  def error(conn, %Ecto.Changeset{} = cs) do
    errors =
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)

    conn |> put_status(422) |> json(%{error: "invalid", errors: errors})
  end

  def error(conn, why) when is_atom(why) do
    conn |> put_status(Map.get(@statuses, why, 422)) |> json(%{error: why})
  end

  def error(conn, why), do: conn |> put_status(422) |> json(%{error: to_string(why)})

  @doc "Reply with `ok` for `:ok`/`{:ok, x}` (via `fun`) or the error."
  def reply(conn, result, fun \\ fn _ -> %{ok: true} end)
  def reply(conn, :ok, fun), do: ok(conn, fun.(nil))
  def reply(conn, {:ok, x}, fun), do: ok(conn, fun.(x))
  def reply(conn, {:error, why}, _), do: error(conn, why)
end
