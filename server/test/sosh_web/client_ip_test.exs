defmodule SoshWeb.ClientIPTest do
  # async: false, it flips :trust_proxy
  use ExUnit.Case, async: false

  alias SoshWeb.ClientIP

  setup do
    on_exit(fn -> Application.delete_env(:sosh, :trust_proxy) end)
  end

  defp conn(headers) do
    Enum.reduce(headers, Plug.Test.conn(:get, "/"), fn {k, v}, c ->
      Plug.Conn.put_req_header(c, k, v)
    end)
    |> Map.put(:remote_ip, {10, 88, 0, 1})
  end

  test "the peer's address, ignoring x-real-ip unless behind a trusted proxy" do
    assert ClientIP.from_conn(conn([{"x-real-ip", "203.0.113.9"}])) == "10.88.0.1"

    assert ClientIP.from_connect_info(%{
             peer_data: %{address: {10, 88, 0, 1}, port: 1},
             x_headers: [{"x-real-ip", "203.0.113.9"}]
           }) == "10.88.0.1"

    assert ClientIP.from_connect_info(%{}) == "socket"
  end

  test "behind a trusted proxy, its x-real-ip if it's an address" do
    Application.put_env(:sosh, :trust_proxy, true)

    assert ClientIP.from_conn(conn([{"x-real-ip", " 2001:db8::1 "}])) == "2001:db8::1"
    assert ClientIP.from_conn(conn([{"x-real-ip", "not an ip"}])) == "10.88.0.1"
    assert ClientIP.from_conn(conn([])) == "10.88.0.1"

    assert ClientIP.from_connect_info(%{
             peer_data: %{address: {10, 88, 0, 1}, port: 1},
             x_headers: [{"x-real-ip", "203.0.113.9"}]
           }) == "203.0.113.9"
  end
end
