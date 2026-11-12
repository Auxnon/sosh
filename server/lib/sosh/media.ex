defmodule Sosh.Media do
  @moduledoc """
  Pictures and carts shared in chat. Uploaded first (`store/3`), then
  attached to a message by key (`Sosh.Chat.post/3` with `media`).

  What's accepted is decided by the bytes, never by a name or a declared
  type: PNG, JPEG, GIF and WebP, whose headers give the size and whether it
  moves (an animated GIF, WebP or APNG). A PNG with a zip after its last
  chunk is a Petrichor64 cart (`.game.png`: the icon, then the game), kind
  `"cart"`; everything else is kind `"image"`.

  Served at `/media/<key>` (`SoshWeb.MediaController`): the key is random
  and unguessable, the same way a message's link is shared.

  As clients see one (`view/1`): `%{key, url, kind, mime, animated, w, h,
  size, name}`, `url` relative to the server.
  """
  import Ecto.Query

  alias Sosh.{RateLimit, Repo}
  alias Sosh.Accounts.User
  alias Sosh.Social.Medium

  @max_size 8 * 1024 * 1024
  @ticket_age 3600
  @max_side 16_384

  def max_size, do: @max_size

  @doc """
  Keep `bytes` for `user`. `{:ok, medium}`, or `{:error, :too_big |
  :empty | :bad_media | :rate_limited}`.
  """
  def store(%User{} = user, bytes, name \\ nil) when is_binary(bytes) do
    with :ok <- RateLimit.hit({:upload, user.id}, 20, :timer.minutes(10)),
         :ok <- check_size(bytes),
         {:ok, info} <- sniff(bytes) do
      %Medium{
        key: key(),
        owner_id: user.id,
        kind: info.kind,
        mime: info.mime,
        animated: info.animated,
        width: info.w,
        height: info.h,
        size: byte_size(bytes),
        name: clean_name(name),
        data: bytes
      }
      |> Repo.insert()
    end
  end

  defp check_size(""), do: {:error, :empty}
  defp check_size(b) when byte_size(b) > @max_size, do: {:error, :too_big}
  defp check_size(_), do: :ok

  defp key, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp clean_name(nil), do: nil

  defp clean_name(name) when is_binary(name) do
    n =
      name
      |> Path.basename()
      |> String.replace(~r/[^\w .\-]/u, "")
      |> String.trim()
      |> String.slice(0, 80)

    if n == "", do: nil, else: n
  end

  defp clean_name(_), do: nil

  # -- tickets: sharing from a page that can't sign in

  @doc """
  A ticket letting whoever holds it share a picture or cart into `place`
  (`{:server, id}` or `{:dm, id}`) as `user` for an hour, and nothing else.
  The game asks for one and hands it to the web page around it
  (client/web/bridge.js), which never sees the user's session.
  """
  def ticket(%User{id: id}, {kind, place_id}) when kind in [:server, :dm] and is_integer(place_id),
    do: Phoenix.Token.sign(SoshWeb.Endpoint, "media ticket", %{u: id, k: Atom.to_string(kind), p: place_id})

  @doc "The user and place a ticket is for: `{:ok, user, place}` or an error."
  def redeem(ticket) when is_binary(ticket) do
    with {:ok, %{u: u, k: k, p: p}} <-
           Phoenix.Token.verify(SoshWeb.Endpoint, "media ticket", ticket, max_age: @ticket_age),
         %User{} = user <- Sosh.Accounts.get_user(u) || {:error, :signed_out} do
      {:ok, user, {String.to_existing_atom(k), p}}
    else
      {:error, :expired} -> {:error, :expired}
      {:error, :signed_out} -> {:error, :signed_out}
      _ -> {:error, :bad_ticket}
    end
  end

  def redeem(_), do: {:error, :bad_ticket}

  @doc "One, without its bytes, by key."
  def get(key) when is_binary(key), do: Repo.get_by(Medium, key: key)
  def get(_), do: nil

  @doc "One's bytes and type, by key, for serving: `{mime, data}` or nil."
  def fetch(key) when is_binary(key) do
    Repo.one(from m in Medium, where: m.key == ^key, select: {m.mime, m.data})
  end

  def fetch(_), do: nil

  @doc "A medium `user` may attach: theirs, by key."
  def attachable(%User{id: id}, key) when is_binary(key) do
    case get(key) do
      %Medium{owner_id: ^id} = m -> {:ok, m}
      %Medium{} -> {:error, :not_yours}
      nil -> {:error, :no_such_media}
    end
  end

  def attachable(_, _), do: {:error, :no_such_media}

  def view(nil), do: nil

  def view(%Medium{} = m) do
    %{
      key: m.key,
      url: "/media/" <> m.key,
      kind: m.kind,
      mime: m.mime,
      animated: m.animated,
      w: m.width,
      h: m.height,
      size: m.size,
      name: m.name
    }
  end

  # -- what the bytes are

  @doc """
  What `bytes` are: `{:ok, %{kind, mime, animated, w, h}}` or
  `{:error, :bad_media}`.
  """
  def sniff(bytes) do
    case kind_of(bytes) do
      {:ok, %{w: w, h: h} = info} when w in 1..@max_side and h in 1..@max_side -> {:ok, info}
      _ -> {:error, :bad_media}
    end
  end

  defp kind_of(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, rest::binary>>), do: png(rest)
  defp kind_of(<<0xFF, 0xD8, 0xFF, _::binary>> = b), do: jpeg(b)
  defp kind_of(<<"GIF8", v, "a", w::little-16, h::little-16, _::binary>> = b) when v in [?7, ?9],
    do: {:ok, %{kind: "image", mime: "image/gif", animated: gif_frames(b) > 1, w: w, h: h}}

  defp kind_of(<<"RIFF", _::little-32, "WEBP", rest::binary>>), do: webp(rest)
  defp kind_of(_), do: :error

  # PNG: IHDR gives the size; acTL before the image data is an APNG; bytes
  # after IEND starting a zip make it a cart.
  defp png(<<13::32, "IHDR", w::32, h::32, _::binary-5, _crc::32, rest::binary>>) do
    case png_chunks(rest, false) do
      {:ok, animated, tail} ->
        cart = match?(<<"PK", 3, 4, _::binary>>, tail)

        {:ok,
         %{kind: if(cart, do: "cart", else: "image"), mime: "image/png", animated: animated and not cart, w: w, h: h}}

      :error ->
        :error
    end
  end

  defp png(_), do: :error

  defp png_chunks(<<len::32, "IEND", _::binary-size(len), _crc::32, tail::binary>>, animated),
    do: {:ok, animated, tail}

  defp png_chunks(<<len::32, type::binary-4, _::binary-size(len), _crc::32, rest::binary>>, animated),
    do: png_chunks(rest, animated or type == "acTL")

  defp png_chunks(_, _), do: :error

  # JPEG: the first start-of-frame marker gives the size.
  defp jpeg(<<0xFF, 0xD8, rest::binary>>), do: jpeg_seg(rest)

  defp jpeg_seg(<<0xFF, 0xFF, rest::binary>>), do: jpeg_seg(<<0xFF, rest::binary>>)

  defp jpeg_seg(<<0xFF, m, _len::16, _p, h::16, w::16, _::binary>>)
       when m in 0xC0..0xCF and m not in [0xC4, 0xC8, 0xCC],
       do: {:ok, %{kind: "image", mime: "image/jpeg", animated: false, w: w, h: h}}

  defp jpeg_seg(<<0xFF, m, rest::binary>>) when m in 0xD0..0xD9 or m == 0x01, do: jpeg_seg(rest)

  defp jpeg_seg(<<0xFF, _m, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    case rest do
      <<_::binary-size(skip), more::binary>> -> jpeg_seg(more)
      _ -> :error
    end
  end

  defp jpeg_seg(_), do: :error

  # GIF: count the image descriptors, walking the blocks properly (an 0x2C
  # byte inside image data isn't one).
  defp gif_frames(<<_::binary-6, _w::16, _h::16, flags, _bg, _aspect, rest::binary>>) do
    rest = skip_table(rest, flags)
    gif_blocks(rest, 0)
  end

  defp gif_frames(_), do: 0

  defp skip_table(rest, flags) do
    if Bitwise.band(flags, 0x80) != 0 do
      n = 3 * Bitwise.bsl(1, Bitwise.band(flags, 0x07) + 1)

      case rest do
        <<_::binary-size(n), more::binary>> -> more
        _ -> ""
      end
    else
      rest
    end
  end

  defp gif_blocks(_, n) when n > 1, do: n

  defp gif_blocks(<<0x2C, _::binary-8, flags, rest::binary>>, n) do
    rest = skip_table(rest, flags)

    case rest do
      <<_lzw, more::binary>> -> gif_blocks(skip_subblocks(more), n + 1)
      _ -> n + 1
    end
  end

  defp gif_blocks(<<0x21, _label, rest::binary>>, n), do: gif_blocks(skip_subblocks(rest), n)
  defp gif_blocks(_, n), do: n

  defp skip_subblocks(<<0, rest::binary>>), do: rest

  defp skip_subblocks(<<len, rest::binary>>) do
    case rest do
      <<_::binary-size(len), more::binary>> -> skip_subblocks(more)
      _ -> ""
    end
  end

  defp skip_subblocks(_), do: ""

  # WebP: VP8X has the canvas and an animation flag; plain VP8 and VP8L
  # keep the size in their bitstream headers.
  defp webp(<<"VP8X", _::little-32, flags, _::binary-3, w::little-24, h::little-24, _::binary>>),
    do: {:ok, %{kind: "image", mime: "image/webp", animated: Bitwise.band(flags, 0x02) != 0, w: w + 1, h: h + 1}}

  defp webp(<<"VP8L", _::little-32, 0x2F, b::little-32, _::binary>>) do
    w = Bitwise.band(b, 0x3FFF) + 1
    h = Bitwise.band(Bitwise.bsr(b, 14), 0x3FFF) + 1
    {:ok, %{kind: "image", mime: "image/webp", animated: false, w: w, h: h}}
  end

  defp webp(<<"VP8 ", _::little-32, _::binary-3, 0x9D, 0x01, 0x2A, w::little-16, h::little-16, _::binary>>),
    do:
      {:ok,
       %{kind: "image", mime: "image/webp", animated: false, w: Bitwise.band(w, 0x3FFF), h: Bitwise.band(h, 0x3FFF)}}

  defp webp(_), do: :error
end
