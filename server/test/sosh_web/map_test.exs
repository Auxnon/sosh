defmodule SoshWeb.MapTest do
  # starts universes: not async
  use SoshWeb.ConnCase

  alias Sosh.{Maps, Servers, Sim}

  setup do
    Sim.stop_all()
    Servers.seed()
    :ok
  end

  test "a universe's map is a picture of it, kept and cached" do
    conn = get(build_conn(), "/map/0,0")
    assert conn.status == 200
    assert ["image/png"] = get_resp_header(conn, "content-type")
    assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", w::32, h::32, 8, 2, _::binary>> = conn.resp_body
    assert w > 200 and abs(w / h - 2) < 0.05
    # it inflates back to w x h of RGB rows
    <<_::binary-33, len::32, "IDAT", _::binary>> = conn.resp_body
    <<_::binary-41, idat::binary-size(len), _::binary>> = conn.resp_body
    assert byte_size(:zlib.uncompress(idat)) == h * (1 + w * 3)

    # kept, so asked again it's the same, and unchanged it's a 304
    [tag] = get_resp_header(conn, "etag")
    assert {png, _} = Maps.get({0, 0})
    assert png == conn.resp_body
    assert build_conn() |> put_req_header("if-none-match", tag) |> get("/map/0,0") |> Map.get(:status) == 304

    assert get(build_conn(), "/map/99,99").status == 404
    assert get(build_conn(), "/map/nowhere").status == 404
  end

  test "the server list points at each universe's map" do
    for s <- Sosh.Repo.all(Sosh.Social.Server) do
      assert Servers.public(s).map == "/map/#{s.gx},#{s.gy}"
    end
  end
end
