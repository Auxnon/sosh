defmodule Sosh.EmbedsTest do
  # changes Sosh.Embeds' config: not async
  use SoshWeb.ChannelCase

  alias Sosh.{Embeds, Servers}

  setup do
    Embeds.forget()
    on_exit(fn -> Application.put_env(:sosh, Embeds, fetch: false, sync: true) end)
    :ok
  end

  defp fake(answers) do
    Application.put_env(:sosh, Embeds,
      sync: true,
      fetch: fn url ->
        case Enum.find(answers, fn {prefix, _} -> String.starts_with?(url, prefix) end) do
          {_, body} -> {:ok, 200, body}
          nil -> {:ok, 404, ""}
        end
      end
    )
  end

  test "links: the providers it knows, each once, at most three" do
    found = fn body -> for {p, _, _} <- Embeds.links(body), do: p end

    assert found.("look https://x.com/someone/status/123456 and https://twitter.com/someone/status/123456.") == ["x"]
    assert found.("https://www.instagram.com/p/C0deX_1/ https://www.threads.net/@zuck/post/C8abc") == ["instagram", "threads"]
    assert found.("https://youtu.be/dQw4w9WgXcQ?t=3") == ["youtube"]
    assert found.("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1 https://youtube.com/shorts/abcdefghijk") == ["youtube", "youtube"]
    assert found.("(https://bsky.app/profile/jay.bsky.team/post/3kabc123)") == ["bluesky"]
    assert found.("https://mastodon.social/@Gargron/109265406458888290") == ["mastodon"]
    assert found.("https://example.social/@someone/109265406458888290") == []
    assert found.("https://www.tiktok.com/@user/video/7234567890123456789") == ["tiktok"]
    assert found.("https://www.reddit.com/r/elixir/comments/abc123/a_title/") == ["reddit"]
    assert found.("https://open.spotify.com/intl-de/track/4uLU6hMCjMI75M1A2tKUQC") == ["spotify"]
    assert found.("https://vimeo.com/76979871 https://soundcloud.com/artist/a-track") == ["vimeo", "soundcloud"]
    assert found.("https://example.com/x https://x.com/home javascript:alert(1)") == []

    four = Enum.map_join(1..4, " ", &"https://x.com/a/status/#{&1}")
    assert length(Embeds.links(four)) == 3
  end

  test "a post's words, author and picture come from its provider" do
    fake([
      {"https://publish.x.com/oembed",
       Jason.encode!(%{
         author_name: "Some One",
         html: ~s(<blockquote class="twitter-tweet"><p lang="en">hello &amp; <a href="x">welcome</a><br>to it</p>&mdash; Some One</blockquote>)
       })},
      {"https://mastodon.social/api/v1/statuses/1",
       Jason.encode!(%{
         content: "<p>a toot &#8212; with <span>tags</span></p>",
         account: %{display_name: "", acct: "gargron"},
         media_attachments: []
       })},
      {"https://www.youtube.com/oembed", Jason.encode!(%{title: "A video", author_name: "A channel"})},
      {"https://www.instagram.com/p/abc/",
       ~s(<html><head><meta property="og:title" content="Someone on Instagram"><meta content="a caption &quot;here&quot;" property="og:description"></head></html>)}
    ])

    [x] = Embeds.links("https://x.com/someone/status/42")
    assert %{provider: "x", author: "Some One", text: "hello & welcome\nto it", thumb: nil} = preview(x)

    [m] = Embeds.links("https://mastodon.social/@gargron/1")
    assert %{author: "gargron", text: "a toot — with tags"} = preview(m)

    [y] = Embeds.links("https://youtu.be/dQw4w9WgXcQ")
    assert %{title: "A video", author: "A channel"} = preview(y)

    [i] = Embeds.links("https://instagram.com/p/abc")
    assert %{title: "Someone on Instagram", text: ~s(a caption "here")} = preview(i)

    # a provider that won't say still makes a card
    [b] = Embeds.links("https://bsky.app/profile/a.b/post/xyz")
    assert %{provider: "bluesky", url: "https://bsky.app/profile/a.b/post/xyz", title: nil, text: nil} = preview(b)
  end

  test "videos are marked, and posts with a picture or video get it" do
    png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", 4::32, 3::32, 8, 6, 0, 0, 0, 0::32, 0::32, "IEND", 0::32>>
    owner = account("poster").id

    fake([
      {"https://cdn.syndication.twimg.com/tweet-result?id=1628832338187636740&lang=en&token=3y54libozsy",
       Jason.encode!(%{
         text: "look at this https://t.co/abc",
         user: %{name: "Some One", screen_name: "someone"},
         mediaDetails: [%{type: "video", url: "https://t.co/abc", media_url_https: "https://pbs.twimg.com/v.jpg"}]
       })},
      {"https://public.api.bsky.app/xrpc/app.bsky.feed.getPosts",
       Jason.encode!(%{
         posts: [
           %{
             author: %{handle: "a.b", displayName: ""},
             record: %{text: "a clip"},
             embed: %{"$type" => "app.bsky.embed.video#view", thumbnail: "https://video.bsky.app/t.jpg"}
           }
         ]
       })},
      {"https://www.reddit.com/r/aww/comments/abc.json",
       Jason.encode!([
         %{data: %{children: [%{data: %{title: "a dog", author: "dogs", is_video: true, preview: %{images: [%{source: %{url: "https://preview.redd.it/d.jpg?a=1&amp;b=2"}}]}}}]}}
       ])},
      {"https://pbs.twimg.com/v.jpg", png},
      {"https://video.bsky.app/t.jpg", png},
      {"https://preview.redd.it/d.jpg?a=1&b=2", png}
    ])

    [x] = Embeds.links("https://x.com/someone/status/1628832338187636740")
    assert %{author: "Some One", text: "look at this", video: true, thumb: %{}} = preview(x, owner)

    [b] = Embeds.links("https://bsky.app/profile/a.b/post/xyz")
    assert %{author: "a.b", text: "a clip", video: true, thumb: %{}} = preview(b, owner)

    [r] = Embeds.links("https://www.reddit.com/r/aww/comments/abc/a_dog/")
    assert %{title: "a dog", author: "u/dogs", video: true, thumb: %{}} = preview(r, owner)

    # always videos, even when the provider says nothing
    [y] = Embeds.links("https://youtu.be/dQw4w9WgXcQ")
    assert %{video: true} = preview(y, owner)
    [i] = Embeds.links("https://www.instagram.com/reel/C0deX_1/")
    assert %{video: true} = preview(i, owner)
    [s] = Embeds.links("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
    assert %{video: false} = preview(s, owner)
  end

  test "X's embed token is JavaScript's" do
    for {id, token} <- [{"1", "bhi2ay3f28n"}, {"20", "6dq1a2xwd93"}, {"1628832338187636740", "3y54libozsy"}, {"1902321123456789012", "4mbg7p42j"}] do
      assert Embeds.x_token(id) == token
    end
  end

  defp preview(link, owner \\ nil)
  defp preview({p, url, target}, owner), do: Embeds.preview(p, url, target, owner)

  test "private hosts are never fetched" do
    refute Embeds.public_host?("localhost")
    refute Embeds.public_host?("127.0.0.1")
    refute Embeds.public_host?("10.1.2.3")
    refute Embeds.public_host?("192.168.0.1")
    refute Embeds.public_host?("::1")
    assert {:error, :private_host} = Embeds.http_get("https://localhost/x")
  end

  test "a message's links get previews, told to its chat and kept with it" do
    Servers.seed()
    user = account("linker")
    Servers.join_home(user)
    {:ok, socket} = connect(SoshWeb.UserSocket, %{"token" => Sosh.Accounts.new_session(user)})
    plaza = Servers.home()

    {:ok, _, chat} =
      Phoenix.ChannelTest.subscribe_and_join(socket, SoshWeb.ServerChannel, "server:#{plaza.id}", %{})

    ref = push(chat, "post", %{"body" => "watch https://youtu.be/dQw4w9WgXcQ"})
    assert_reply ref, :ok, %{message: %{id: id}}
    assert_broadcast "embeds", %{id: ^id, embeds: [%{provider: "youtube", url: "https://youtu.be/dQw4w9WgXcQ"}]}

    ref = push(chat, "history", %{})
    assert_reply ref, :ok, %{messages: messages}
    assert %{embeds: [%{provider: "youtube"}]} = Enum.find(messages, &(&1.id == id))

    # edited to no links, the preview goes
    ref = push(chat, "edit", %{"id" => id, "body" => "never mind"})
    assert_reply ref, :ok, _
    assert_broadcast "embeds", %{id: ^id, embeds: []}
  end
end
