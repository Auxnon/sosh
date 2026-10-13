defmodule Sosh.Universe do
  @moduledoc """
  NIFs over the Rust simulation in `native/universe`: crops that grow on
  wall-clock time, cows that wander and get pushed, and what players carry
  (the universe decides what can be). `Sosh.Sim` owns the universe and is the
  only caller.

  Positions are `{x, y, z}` tuples in block coordinates (see `Sosh.World`).
  """
  use Rustler, otp_app: :sosh, crate: "universe"

  def bigbang(_stage_ms, _seed), do: :erlang.nif_error(:nif_not_loaded)
  def load_chunk(_universe, _key, _blocks), do: :erlang.nif_error(:nif_not_loaded)
  def set_block(_universe, _pos, _id), do: :erlang.nif_error(:nif_not_loaded)
  def plant(_universe, _pos, _planted_ms, _now_ms), do: :erlang.nif_error(:nif_not_loaded)
  def crop(_universe, _pos), do: :erlang.nif_error(:nif_not_loaded)
  def remove_crop(_universe, _pos), do: :erlang.nif_error(:nif_not_loaded)
  def crops(_universe), do: :erlang.nif_error(:nif_not_loaded)
  def spawn_cow(_universe, _x, _y), do: :erlang.nif_error(:nif_not_loaded)
  def cows(_universe), do: :erlang.nif_error(:nif_not_loaded)
  def carryable, do: :erlang.nif_error(:nif_not_loaded)
  def pick_block(_universe, _holder, _at, _id), do: :erlang.nif_error(:nif_not_loaded)
  def pick_cow(_universe, _holder, _at, _id), do: :erlang.nif_error(:nif_not_loaded)
  def put_down(_universe, _holder, _pos, _free), do: :erlang.nif_error(:nif_not_loaded)
  def release(_universe, _holder), do: :erlang.nif_error(:nif_not_loaded)
  def holding(_universe), do: :erlang.nif_error(:nif_not_loaded)
  def tick(_universe, _now_ms, _players), do: :erlang.nif_error(:nif_not_loaded)
end
