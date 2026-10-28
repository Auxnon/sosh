defmodule Sosh.Character do
  @moduledoc """
  What someone looks like, as kept on their account (`users.character`)
  and drawn by every client (`client/scripts/character.lua`, the Android
  creator).

    * `height` - 0.85..1.2, the body stretched along its bones
    * `skin`, and a colour for each piece below: hex `"RRGGBB"`
    * `head` - which head model (`heads/0`)
    * `hair` - a head piece or `"none"`, with `hair_color`
    * `face` - up to 12 sprites on the front of the head, each `%{part,
      shape, x, y, scale, rot, color}`: `part` one of `parts/0`, `shape` an
      index into its shapes, `x`/`y` across the face in -1..1 (0, 0 the
      middle; +y up), `scale` 0.4..2.5, `rot` radians
    * `top`, `bottom`, `shoes`, `hat` - clothes (`clothes/0`) or `"none"`,
      each with a `_color`. Clothes are skinned with the body's own weights,
      so they move with it
    * `hand` - an item held in the right hand, or nil

  `clean/1` takes anything and returns a valid character, filling what's
  missing from `default/0`; clients only ever get cleaned ones.
  """

  @heads ~w(round square long bean)
  @hair ~w(none short tuft bob spikes long)
  @clothes %{
    "top" => ~w(none tee jacket sweater),
    "bottom" => ~w(none pants shorts skirt),
    "shoes" => ~w(none shoes boots),
    "hat" => ~w(none cap beanie tophat)
  }
  # how many shapes each face sprite has (client/assets/fp_<part><n>.glb)
  @parts %{
    "eye" => 6,
    "brow" => 4,
    "mouth" => 6,
    "nose" => 4,
    "cheek" => 2,
    "mark" => 4
  }
  @max_face 12

  def heads, do: @heads
  def hair, do: @hair
  def clothes, do: @clothes
  def parts, do: @parts

  @doc "Everything a creator offers, for clients."
  def catalog do
    %{
      heads: @heads,
      hair: @hair,
      clothes: @clothes,
      parts: @parts,
      height: [0.85, 1.2],
      max_face: @max_face
    }
  end

  def default do
    %{
      "v" => 1,
      "height" => 1.0,
      "skin" => "E8B796",
      "head" => "round",
      "hair" => "short",
      "hair_color" => "4A3020",
      "face" => [
        part("eye", 0, -0.32, 0.12, "302820"),
        part("eye", 0, 0.32, 0.12, "302820"),
        part("brow", 0, -0.32, 0.42, "4A3020"),
        part("brow", 0, 0.32, 0.42, "4A3020"),
        part("mouth", 0, 0.0, -0.45, "A04040")
      ],
      "top" => "tee",
      "top_color" => "4F7FC0",
      "bottom" => "pants",
      "bottom_color" => "40404A",
      "shoes" => "shoes",
      "shoes_color" => "6A4A30",
      "hat" => "none",
      "hat_color" => "C04040",
      "hand" => nil
    }
  end

  defp part(p, shape, x, y, color),
    do: %{"part" => p, "shape" => shape, "x" => x, "y" => y, "scale" => 1.0, "rot" => 0.0, "color" => color}

  @doc "A valid character from anything, keeping what's valid in `c`."
  def clean(c) when is_map(c) do
    d = default()
    c = Map.new(c, fn {k, v} -> {to_string(k), v} end)

    %{
      "v" => 1,
      "height" => num(c["height"], 0.85, 1.2, d["height"]),
      "skin" => color(c["skin"], d["skin"]),
      "head" => one_of(c["head"], @heads, d["head"]),
      "hair" => one_of(c["hair"], @hair, d["hair"]),
      "hair_color" => color(c["hair_color"], d["hair_color"]),
      "face" => face(c["face"], d["face"]),
      "hand" => hand(c["hand"])
    }
    |> Map.merge(
      Map.new(@clothes, fn {slot, options} -> {slot, one_of(c[slot], options, d[slot])} end)
    )
    |> Map.merge(
      Map.new(Map.keys(@clothes), fn slot ->
        k = slot <> "_color"
        {k, color(c[k], d[k])}
      end)
    )
  end

  def clean(_), do: default()

  defp face(list, _default) when is_list(list) do
    list
    |> Enum.take(@max_face)
    |> Enum.flat_map(fn
      %{} = p ->
        p = Map.new(p, fn {k, v} -> {to_string(k), v} end)
        name = p["part"]

        case @parts[name] do
          nil ->
            []

          shapes ->
            [
              %{
                "part" => name,
                "shape" => int(p["shape"], 0, shapes - 1, 0),
                "x" => num(p["x"], -1.0, 1.0, 0.0),
                "y" => num(p["y"], -1.0, 1.0, 0.0),
                "scale" => num(p["scale"], 0.4, 2.5, 1.0),
                "rot" => num(p["rot"], -3.1416, 3.1416, 0.0),
                "color" => color(p["color"], "302820")
              }
            ]
        end

      _ ->
        []
    end)
  end

  defp face(_, default), do: default

  defp hand(item) when is_binary(item) and byte_size(item) <= 32, do: item
  defp hand(_), do: nil

  defp num(v, lo, hi, _) when is_number(v), do: (v * 1.0) |> max(lo) |> min(hi) |> Float.round(3)
  defp num(_, _, _, d), do: d

  defp int(v, lo, hi, _) when is_integer(v), do: v |> max(lo) |> min(hi)
  defp int(v, lo, hi, d) when is_float(v), do: int(round(v), lo, hi, d)
  defp int(_, _, _, d), do: d

  defp one_of(v, options, d), do: if(v in options, do: v, else: d)

  defp color(v, d) when is_binary(v) do
    v = String.trim_leading(v, "#") |> String.upcase()
    if String.match?(v, ~r/^[0-9A-F]{6}$/), do: v, else: d
  end

  defp color(_, d), do: d
end
