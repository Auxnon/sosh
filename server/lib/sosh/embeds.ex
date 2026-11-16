defmodule Sosh.Embeds do
  @moduledoc """
  Link previews ("embeds") for chat messages: posts on X, Instagram,
  Threads, Bluesky and Mastodon, YouTube, TikTok, Reddit, Spotify, Vimeo
  and SoundCloud.

  When a message is posted or edited, the first three links in it that a
  provider here recognises are looked up (`attach/1`, in the background)
  and kept on the message (`messages.embeds`), then announced to its chat
  as `embeds` `%{id, embeds}`. Each embed, as clients see it:
  `%{url, provider, title, author, text, thumb, video}`, everything but
  `url`, `provider` and `video` maybe nil; `video` is true when the link
  is to a video (clients put a play mark on its picture; opening it goes
  to the provider, nothing plays here), `thumb` a picture kept like any other
  (`Sosh.Media.view/1`, served from here, so clients never reach the
  provider). A link whose provider won't say anything still gets a bare
  card.

  Only providers' own public endpoints are asked (oEmbed, Mastodon's
  statuses API, X's syndication API and Bluesky's public AppView for a
  post's picture or video, Reddit's JSON, a page's OpenGraph tags for
  Instagram and Threads, unless `META_OEMBED_TOKEN` is set), never the link as given; Mastodon only on
  the instances in `@mastodon` (plus `SOSH_MASTODON_HOSTS`, comma
  separated). Nothing is fetched from a host that resolves to a private
  address, redirects aren't followed, and answers are capped in size.
  What each URL said is cached for an hour.

  In tests nothing is fetched (`config :sosh, Sosh.Embeds, fetch: false`,
  `sync: true`); `fetch` can be a `fun(url) -> {:ok, status, body} |
  {:error, why}` to stand in for the network.
  """
  use GenServer

  import Ecto.Query

  alias Sosh.{Media, Repo}
  alias Sosh.Social.Message

  require Logger

  @max_links 3
  @table __MODULE__
  @ttl_ms :timer.hours(1)
  @max_body 2 * 1024 * 1024
  @max_thumb 2 * 1024 * 1024
  @timeout 6_000
  @max_text 400
  @user_agent "SoshLinkPreview/1.0 (+chat link previews)"

  @mastodon ~w(mastodon.social mastodon.online mstdn.social mas.to fosstodon.org
               hachyderm.io infosec.exchange mastodon.world techhub.social
               universeodon.com mastodon.art masto.ai social.vivaldi.net
               mstdn.jp pawoo.net mastodon.scot chaos.social mastodon.ie
               aus.social mastodon.nz toot.community indieweb.social)

  @providers ~w(x instagram threads bluesky mastodon youtube tiktok reddit spotify vimeo soundcloud)

  # links to these are always videos
  @video_providers ~w(youtube tiktok vimeo)

  def providers, do: @providers

  @doc "The URL cache's owner (one ETS table)."
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  # -- which links

  @doc """
  The links in `body` a provider here knows, in order, at most #{@max_links},
  each once: `[{provider, url, target}]`, `target` what to ask the provider
  about.
  """
  def links(body) when is_binary(body) do
    ~r{https?://[^\s<>"']+}i
    |> Regex.scan(body)
    |> Enum.map(fn [u] -> Regex.replace(~r/[.,;:!?)\]}*]+$/, u, "") end)
    |> Enum.uniq()
    |> Enum.flat_map(fn u ->
      case recognise(u) do
        nil -> []
        {p, t} -> [{p, u, t}]
      end
    end)
    |> Enum.uniq_by(fn {_, _, t} -> t end)
    |> Enum.take(@max_links)
  end

  def links(_), do: []

  defp recognise(url) do
    with %URI{scheme: s, host: h} = uri when s in ["http", "https"] and is_binary(h) <- URI.parse(url) do
      host = h |> String.downcase() |> String.replace_prefix("www.", "")
      path = uri.path || "/"
      query = URI.decode_query(uri.query || "")
      match(host, String.split(path, "/", trim: true), query)
    else
      _ -> nil
    end
  end

  defp match(h, [user, "status", id | _], _)
       when h in ["x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com", "fxtwitter.com", "vxtwitter.com", "fixupx.com"] do
    if digits?(id) and handle?(user), do: {"x", {:x, user, id}}
  end

  defp match(h, [kind, code | _], _) when h in ["instagram.com", "m.instagram.com"] and kind in ["p", "reel", "reels", "tv"] do
    if slug?(code), do: {"instagram", {:instagram, kind, code}}
  end

  defp match(h, ["@" <> user, "post", code | _], _) when h in ["threads.net", "threads.com"] do
    if handle?(user) and slug?(code), do: {"threads", {:threads, user, code}}
  end

  defp match("bsky.app", ["profile", who, "post", rkey | _], _) do
    if slug?(who) and slug?(rkey), do: {"bluesky", {:bluesky, who, rkey}}
  end

  defp match(h, ["watch"], %{"v" => id}) when h in ["youtube.com", "m.youtube.com", "music.youtube.com"],
    do: youtube(id)

  defp match(h, [kind, id | _], _) when h in ["youtube.com", "m.youtube.com"] and kind in ["shorts", "live", "embed"],
    do: youtube(id)

  defp match("youtu.be", [id | _], _), do: youtube(id)

  defp match(h, ["@" <> user, "video", id | _], _) when h in ["tiktok.com", "m.tiktok.com"] do
    if handle?(user) and digits?(id), do: {"tiktok", {:tiktok, user, id}}
  end

  defp match(h, ["r", sub, "comments", id | rest], _) when h in ["reddit.com", "old.reddit.com", "new.reddit.com"] do
    if slug?(sub) and slug?(id),
      do: {"reddit", {:reddit, sub, id, Enum.find(rest, &slug?/1)}}
  end

  defp match("open.spotify.com", parts, _) do
    case Enum.drop_while(parts, &String.starts_with?(&1, "intl-")) do
      [kind, id | _] when kind in ["track", "album", "playlist", "episode", "show", "artist"] ->
        if slug?(id), do: {"spotify", {:spotify, kind, id}}

      _ ->
        nil
    end
  end

  defp match("vimeo.com", [id | _], _) do
    if digits?(id), do: {"vimeo", {:vimeo, id}}
  end

  defp match("soundcloud.com", [user, track | _], _) do
    if slug?(user) and slug?(track) and user not in ["discover", "search", "you", "stream"],
      do: {"soundcloud", {:soundcloud, user, track}}
  end

  defp match(h, parts, _) do
    if h in mastodon_hosts() do
      case parts do
        ["@" <> user, id | _] -> if handle?(user) and digits?(id), do: {"mastodon", {:mastodon, h, id}}
        ["users", user, "statuses", id | _] -> if handle?(user) and digits?(id), do: {"mastodon", {:mastodon, h, id}}
        _ -> nil
      end
    end
  end

  defp youtube(id) do
    if Regex.match?(~r/^[A-Za-z0-9_-]{6,20}$/, id), do: {"youtube", {:youtube, id}}
  end

  defp digits?(s), do: Regex.match?(~r/^\d{1,25}$/, s)
  defp handle?(s), do: Regex.match?(~r/^[A-Za-z0-9_.]{1,40}$/, s)
  defp slug?(s), do: Regex.match?(~r/^[A-Za-z0-9_.:-]{1,100}$/, s)

  defp mastodon_hosts do
    extra =
      (System.get_env("SOSH_MASTODON_HOSTS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

    @mastodon ++ extra
  end

  # -- on a message

  @doc """
  Look up the links in message `m` (as just posted or edited), keep what
  they say on it and tell its chat. In the background unless configured
  `sync`; with no links it clears any it had.
  """
  def attach(%Message{} = m) do
    if config(:sync, false), do: run(m), else: Task.start(fn -> run(m) end)
    :ok
  end

  defp run(%Message{id: id, body: body, author_id: author} = m) do
    embeds = for {p, url, target} <- links(body), do: preview(p, url, target, author)

    if embeds != [] or (m.embeds || []) != [] do
      from(x in Message, where: x.id == ^id) |> Repo.update_all(set: [embeds: embeds])
      announce(m, %{id: id, embeds: embeds})
    end

    embeds
  rescue
    e ->
      Logger.warning("embeds for message #{id}: #{Exception.message(e)}")
      []
  end

  defp announce(%Message{server_id: nil, conversation_id: c}, payload),
    do: SoshWeb.Endpoint.broadcast("dm:#{c}", "embeds", payload)

  defp announce(%Message{server_id: s}, payload),
    do: SoshWeb.Endpoint.broadcast("server:#{s}", "embeds", payload)

  @doc "How a message's kept embeds go to clients."
  def view(list) when is_list(list), do: Enum.map(list, &view_one/1)
  def view(_), do: []

  defp view_one(e) do
    get = fn k -> e[k] || e[to_string(k)] end

    %{
      url: get.(:url),
      provider: get.(:provider),
      title: get.(:title),
      author: get.(:author),
      text: get.(:text),
      thumb: get.(:thumb),
      video: get.(:video) == true
    }
  end

  # -- asking the providers

  @doc false
  def preview(provider, url, target, owner_id) do
    case cached(url) do
      {:ok, e} ->
        e

      :miss ->
        e =
          if config(:fetch, true) == false do
            bare(provider, url)
          else
            fetched(provider, url, target, owner_id)
          end

        remember(url, e)
        e
    end
  end

  defp video_target?({:instagram, kind, _}), do: kind in ["reel", "reels", "tv"]
  defp video_target?(_), do: false

  defp bare(provider, url),
    do: %{url: url, provider: provider, title: nil, author: nil, text: nil, thumb: nil, video: provider in @video_providers}

  defp fetched(provider, url, target, owner_id) do
    found =
      case ask(target) do
        {:ok, info} -> info
        _ -> %{}
      end

    thumb =
      case found[:thumb_url] do
        nil -> nil
        t -> thumbnail(t, owner_id)
      end

    %{
      url: url,
      provider: provider,
      title: clip(found[:title], 200),
      author: clip(found[:author], 80),
      text: clip(found[:text], @max_text),
      thumb: thumb,
      video: provider in @video_providers or found[:video] == true or video_target?(target)
    }
  end

  defp ask({:youtube, id}),
    do: oembed("https://www.youtube.com/oembed", "https://www.youtube.com/watch?v=" <> id, format: "json")

  # X's syndication API (what its own embeds use) has the post's picture,
  # or a video's; its oEmbed only the words.
  defp ask({:x, user, id}) do
    case x_syndication(id) do
      {:ok, _} = ok -> ok
      _ -> x_oembed(user, id)
    end
  end

  defp ask({:bluesky, who, rkey}) do
    case bluesky_post(who, rkey) do
      {:ok, _} = ok -> ok
      _ -> bluesky_oembed(who, rkey)
    end
  end


  defp ask({:mastodon, host, id}) do
    with {:ok, j} <- get_json("https://#{host}/api/v1/statuses/#{id}") do
      account = j["account"] || %{}
      media = Enum.find(j["media_attachments"] || [], &(&1["type"] in ["image", "gifv", "video"]))

      {:ok,
       %{
         author: present(account["display_name"]) || account["acct"],
         text: html_text(j["content"] || ""),
         title: nil,
         thumb_url: media && media["preview_url"],
         video: media != nil and media["type"] in ["video", "gifv"]
       }}
    end
  end

  defp ask({:instagram, kind, code}) do
    url = "https://www.instagram.com/#{kind}/#{code}/"

    case System.get_env("META_OEMBED_TOKEN") do
      nil -> page_meta(url)
      token -> oembed("https://graph.facebook.com/v21.0/instagram_oembed", url, access_token: token)
    end
  end

  defp ask({:threads, user, code}), do: page_meta("https://www.threads.net/@#{user}/post/#{code}")

  defp ask({:tiktok, user, id}),
    do: oembed("https://www.tiktok.com/oembed", "https://www.tiktok.com/@#{user}/video/#{id}")

  defp ask({:reddit, sub, id, slug}) do
    path = "https://www.reddit.com/r/#{sub}/comments/#{id}/" <> if(slug, do: slug <> "/", else: "")

    case reddit_json(sub, id) do
      {:ok, _} = ok -> ok
      _ -> oembed("https://www.reddit.com/oembed", path)
    end
  end

  # A post's own JSON: its title, and its preview picture (a video's too).
  defp reddit_json(sub, id) do
    with {:ok, 200, body} <- get("https://www.reddit.com/r/#{sub}/comments/#{id}.json?limit=1&raw_json=1"),
         {:ok, [%{"data" => %{"children" => [%{"data" => d} | _]}} | _]} <- Jason.decode(body) do
      picture =
        get_in(d, ["preview", "images", Access.at(0), "source", "url"]) ||
          (is_binary(d["thumbnail"]) and String.starts_with?(d["thumbnail"], "https://") && d["thumbnail"]) || nil

      {:ok,
       %{
         title: present(d["title"]),
         author: present(d["author"]) && "u/" <> d["author"],
         text: present(d["selftext"]),
         thumb_url: picture && entities(picture),
         video: d["is_video"] == true or d["post_hint"] in ["hosted:video", "rich:video"]
       }}
    else
      _ -> :error
    end
  end

  defp ask({:spotify, kind, id}),
    do: oembed("https://open.spotify.com/oembed", "https://open.spotify.com/#{kind}/#{id}")

  defp ask({:vimeo, id}), do: oembed("https://vimeo.com/api/oembed.json", "https://vimeo.com/" <> id)

  defp ask({:soundcloud, user, track}),
    do: oembed("https://soundcloud.com/oembed", "https://soundcloud.com/#{user}/#{track}", format: "json")

  defp x_syndication(id) do
    q = URI.encode_query(id: id, lang: "en", token: x_token(id))

    with {:ok, j} <- get_json("https://cdn.syndication.twimg.com/tweet-result?" <> q),
         true <- is_binary(j["text"]) or is_list(j["mediaDetails"]) do
      media = List.first(j["mediaDetails"] || []) || %{}
      user = j["user"] || %{}

      {:ok,
       %{
         author: present(user["name"]) || present(user["screen_name"]),
         text: present(strip_media_links(j["text"] || "", j)),
         title: nil,
         thumb_url: media["media_url_https"],
         video: media["type"] in ["video", "animated_gif"]
       }}
    else
      _ -> :error
    end
  end

  # the t.co links X puts at the end for the post's own pictures
  defp strip_media_links(text, j) do
    (j["mediaDetails"] || [])
    |> Enum.map(& &1["url"])
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce(text, &String.replace(&2, &1, ""))
    |> entities()
    |> String.trim()
  end

  @doc false
  # The token X's embed script sends: (id / 1e15 * pi) in base 36, without
  # its zeros and point (as JavaScript's toString(36) writes it).
  def x_token(id) do
    {n, ""} = Integer.parse(id)
    (n / 1.0e15 * :math.pi()) |> js_base36() |> String.replace(~r/0+|\./, "")
  end

  @digits ~c"0123456789abcdefghijklmnopqrstuvwxyz"

  # V8's DoubleToRadixCString for radix 36 and a positive double: the
  # shortest fraction digits that still read back as the same double.
  defp js_base36(value) do
    int = Float.floor(value)
    frac = value - int
    <<bits::64>> = <<value::float>>
    <<next::float>> = <<bits + 1::64>>
    delta = max(0.5 * (next - value), 5.0e-324)

    {int, frac_digits} =
      if frac >= delta, do: fraction36(frac, delta, [], int), else: {int, []}

    int_digits = Integer.to_string(trunc(int), 36) |> String.downcase()
    if frac_digits == [], do: int_digits, else: int_digits <> "." <> to_string(Enum.reverse(frac_digits))
  end

  defp fraction36(frac, delta, acc, int) do
    frac = frac * 36
    delta = delta * 36
    digit = trunc(frac)
    acc = [Enum.at(@digits, digit) | acc]
    frac = frac - digit

    cond do
      (frac > 0.5 or (frac == 0.5 and rem(digit, 2) == 1)) and frac + delta > 1 -> round_up(acc, int)
      frac >= delta -> fraction36(frac, delta, acc, int)
      true -> {int, acc}
    end
  end

  # carry one into the last digit (acc is reversed)
  defp round_up([], int), do: {int + 1, []}

  defp round_up([c | rest], int) do
    d = Enum.find_index(@digits, &(&1 == c))
    if d + 1 < 36, do: {int, [Enum.at(@digits, d + 1) | rest]}, else: round_up(rest, int)
  end

  # Bluesky's public AppView: the post, its words and a picture or video.
  defp bluesky_post(who, rkey) do
    uri = "at://#{who}/app.bsky.feed.post/#{rkey}"

    with {:ok, %{"posts" => [post | _]}} <-
           get_json("https://public.api.bsky.app/xrpc/app.bsky.feed.getPosts?" <> URI.encode_query(uris: uri)) do
      author = post["author"] || %{}
      {thumb, video} = bluesky_media(post["embed"])

      {:ok,
       %{
         author: present(author["displayName"]) || present(author["handle"]),
         text: present((post["record"] || %{})["text"]),
         title: nil,
         thumb_url: thumb,
         video: video
       }}
    else
      _ -> :error
    end
  end

  defp bluesky_media(%{"$type" => "app.bsky.embed.video#view"} = e), do: {e["thumbnail"], true}
  defp bluesky_media(%{"$type" => "app.bsky.embed.images#view", "images" => [i | _]}), do: {i["thumb"], false}
  defp bluesky_media(%{"$type" => "app.bsky.embed.external#view", "external" => x}), do: {x["thumb"], false}
  defp bluesky_media(%{"$type" => "app.bsky.embed.recordWithMedia#view", "media" => m}), do: bluesky_media(m)
  defp bluesky_media(_), do: {nil, false}

  defp x_oembed(user, id) do
    with {:ok, j} <-
           oembed_json("https://publish.x.com/oembed", "https://twitter.com/#{user}/status/#{id}",
             omit_script: "true",
             dnt: "true"
           ) do
      {:ok, %{author: j["author_name"], text: blockquote_text(j["html"]), title: nil}}
    end
  end

  defp bluesky_oembed(who, rkey) do
    with {:ok, j} <- oembed_json("https://embed.bsky.app/oembed", "https://bsky.app/profile/#{who}/post/#{rkey}", format: "json") do
      {:ok, %{author: j["author_name"], text: blockquote_text(j["html"]), title: nil}}
    end
  end

  # An oEmbed answer's usual fields.
  defp oembed(endpoint, url, params \\ []) do
    with {:ok, j} <- oembed_json(endpoint, url, params) do
      {:ok, %{title: j["title"], author: j["author_name"], text: nil, thumb_url: j["thumbnail_url"]}}
    end
  end

  defp oembed_json(endpoint, url, params) do
    q = URI.encode_query([{"url", url} | Enum.map(params, fn {k, v} -> {to_string(k), v} end)])
    get_json(endpoint <> "?" <> q)
  end

  defp get_json(url) do
    with {:ok, 200, body} <- get(url),
         {:ok, %{} = j} <- Jason.decode(body) do
      {:ok, j}
    else
      _ -> :error
    end
  end

  # A page's OpenGraph tags (Instagram, Threads).
  defp page_meta(url) do
    with {:ok, 200, html} <- get(url) do
      title = meta(html, "og:title")
      text = meta(html, "og:description")

      if title || text do
        video = meta(html, "og:video") != nil or String.starts_with?(meta(html, "og:type") || "", "video")
        {:ok, %{title: title, author: nil, text: text, thumb_url: meta(html, "og:image"), video: video}}
      else
        :error
      end
    else
      _ -> :error
    end
  end

  defp meta(html, prop) do
    p = Regex.escape(prop)

    case Regex.run(~r/<meta[^>]+(?:property|name)=["']#{p}["'][^>]*content=["']([^"']*)["']/i, html) ||
           Regex.run(~r/<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']#{p}["']/i, html) do
      [_, v] -> present(entities(v))
      _ -> nil
    end
  end

  # The post's words in an oEmbed blockquote: its first paragraph.
  defp blockquote_text(nil), do: nil

  defp blockquote_text(html) do
    case Regex.run(~r{<p[^>]*>(.*?)</p>}s, html) do
      [_, p] -> html_text(p)
      _ -> nil
    end
  end

  defp html_text(html) do
    html
    |> String.replace(~r{<br\s*/?>|</p>\s*<p[^>]*>}i, "\n")
    |> String.replace(~r/<[^>]*>/, "")
    |> entities()
    |> String.trim()
    |> present()
  end

  defp entities(s) do
    s
    |> String.replace(~r/&#(\d+);/, fn m -> codepoint(Regex.run(~r/\d+/, m) |> hd() |> String.to_integer()) end)
    |> String.replace(~r/&#x([0-9a-fA-F]+);/, fn m ->
      [_, h] = Regex.run(~r/&#x([0-9a-fA-F]+);/, m)
      codepoint(String.to_integer(h, 16))
    end)
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
  end

  defp codepoint(n) when n in 0..0x10FFFF and n not in 0xD800..0xDFFF, do: <<n::utf8>>
  defp codepoint(_), do: ""

  defp present(nil), do: nil
  defp present(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp present(_), do: nil

  defp clip(nil, _), do: nil
  defp clip(s, n) when is_binary(s), do: if(String.length(s) > n, do: String.slice(s, 0, n - 1) <> "…", else: s)
  defp clip(_, _), do: nil

  # A provider's picture, kept like an upload of the message's author.
  defp thumbnail(url, owner_id) do
    with true <- String.starts_with?(url, "https://"),
         {:ok, 200, bytes} <- get(url, @max_thumb),
         {:ok, m} <- Media.keep(owner_id, bytes, "preview"),
         true <- m.kind == "image" do
      Media.view(m)
    else
      _ -> nil
    end
  end

  # -- the network

  defp get(url, max \\ @max_body) do
    case config(:fetch, true) do
      fun when is_function(fun, 1) -> fun.(url)
      false -> {:error, :off}
      _ -> http_get(url, max)
    end
  end

  @doc false
  def http_get(url, max \\ @max_body) do
    %URI{scheme: "https", host: host} = URI.parse(url)

    if public_host?(host) do
      req = Finch.build(:get, url, [{"user-agent", @user_agent}, {"accept", "application/json, text/html;q=0.9, */*;q=0.5"}])

      acc = {nil, [], 0}

      result =
        Finch.stream_while(req, Sosh.Finch, acc, fn
          {:status, s}, {_, b, n} -> {:cont, {s, b, n}}
          {:headers, _}, a -> {:cont, a}
          {:data, d}, {s, b, n} ->
            n = n + byte_size(d)
            if n > max, do: {:halt, {:too_big, b, n}}, else: {:cont, {s, [b | d], n}}
          _, a -> {:cont, a}
        end, receive_timeout: @timeout, pool_timeout: @timeout)

      case result do
        {:ok, {:too_big, _, _}} -> {:error, :too_big}
        {:ok, {s, b, _}} -> {:ok, s, IO.iodata_to_binary(b)}
        {:error, e, _} -> {:error, e}
        {:error, e} -> {:error, e}
      end
    else
      {:error, :private_host}
    end
  rescue
    e -> {:error, e}
  end

  @doc "Does `host` resolve only to public addresses?"
  def public_host?(host) when is_binary(host) do
    h = String.to_charlist(host)

    addrs =
      for fam <- [:inet, :inet6], {:ok, as} <- [:inet.getaddrs(h, fam)], a <- as, do: a

    addrs != [] and Enum.all?(addrs, &public_addr?/1)
  end

  def public_host?(_), do: false

  defp public_addr?({a, b, _, _}) do
    not (a in [0, 10, 127] or (a == 100 and b in 64..127) or (a == 169 and b == 254) or
           (a == 172 and b in 16..31) or (a == 192 and b == 168) or a >= 224)
  end

  defp public_addr?({0, 0, 0, 0, 0, 0xFFFF, x, y}), do: public_addr?({div(x, 256), rem(x, 256), div(y, 256), rem(y, 256)})

  defp public_addr?({a, _, _, _, _, _, _, _} = ip) do
    not (ip == {0, 0, 0, 0, 0, 0, 0, 0} or ip == {0, 0, 0, 0, 0, 0, 0, 1} or
           Bitwise.band(a, 0xFE00) == 0xFC00 or Bitwise.band(a, 0xFFC0) == 0xFE80 or
           Bitwise.band(a, 0xFF00) == 0xFF00)
  end

  # -- cache

  defp cached(url) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, url) do
      [{^url, e, at}] -> if now() - at < @ttl_ms, do: {:ok, e}, else: :miss
      _ -> :miss
    end
  end

  defp remember(url, e) do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {url, e, now()})
  end

  @doc "Forget what was cached. For tests."
  def forget, do: if(:ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table))

  defp now, do: System.monotonic_time(:millisecond)

  defp config(key, default), do: Application.get_env(:sosh, __MODULE__, []) |> Keyword.get(key, default)
end
