defmodule SoshWeb.ClientIP do
  @moduledoc """
  Who's asking, for rate limits: the peer's address, or behind a reverse
  proxy (`TRUST_PROXY=1`, config `:trust_proxy`) the address it hands on in
  `x-real-ip`. Only trust that when nothing but the proxy can reach the
  server (the deploy publishes it on 127.0.0.1), or anyone could pick their
  own address and dodge the limits.
  """

  @doc "From a Plug conn."
  def from_conn(%Plug.Conn{} = conn) do
    forwarded(Plug.Conn.get_req_header(conn, "x-real-ip")) || ntoa(conn.remote_ip)
  end

  @doc "From a socket's connect_info (needs `:peer_data` and `:x_headers`)."
  def from_connect_info(info) do
    header = for {"x-real-ip", v} <- info[:x_headers] || [], do: v

    forwarded(header) ||
      case info[:peer_data] do
        %{address: a} -> ntoa(a)
        _ -> "socket"
      end
  end

  defp forwarded([v | _]) do
    if Application.get_env(:sosh, :trust_proxy, false) do
      v = String.trim(v)
      if match?({:ok, _}, :inet.parse_address(String.to_charlist(v))), do: v
    end
  end

  defp forwarded(_), do: nil

  defp ntoa(a), do: a |> :inet.ntoa() |> to_string()
end
