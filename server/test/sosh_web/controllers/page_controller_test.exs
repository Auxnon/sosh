defmodule SoshWeb.PageControllerTest do
  use SoshWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    # the Petrichor64 web build (client/README.md)
    assert html_response(conn, 200) =~ "Petrichor64.js"
  end
end
