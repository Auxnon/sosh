defmodule Sosh.Universe do
  @moduledoc """
  NIFs over one Rust universe (`native/universe`): its blocks and floating
  islands, crops that grow on world ticks, cows, furniture and blueprints,
  airships, helpers, and what players hold. `Sosh.Sim` owns each universe
  and is the only caller.

  Positions are `{x, y, z}` tuples in block coordinates (see `Sosh.World`),
  in a frame: `on` is 0 for the world, or a ship's id for that ship's own;
  bags are lists of `nil | {item, count}` (see `Sosh.Players`). Fallible
  calls return `:ok`, `{:ok, ...}` or `{:error, reason}`.
  """
  use Rustler, otp_app: :sosh, crate: "universe"

  def bigbang(_gx, _gy, _seed, _stage_ms), do: err()
  def chunk_keys, do: err()
  def load_chunk(_u, _key, _blocks), do: err()
  def take_dirty(_u), do: err()
  def rle(_u, _key), do: err()
  def block(_u, _on, _pos), do: err()
  def world_of(_u, _on, _at), do: err()
  def save(_u, _now_ms), do: err()
  def restore(_u, _json), do: err()
  def set_open(_u, _open), do: err()
  def asleep(_u), do: err()
  def sleep(_u, _now_ms), do: err()
  def wake(_u, _now_ms), do: err()
  def ambient(_u, _now_ms), do: err()
  def spawn(_u, _user, _at), do: err()
  def spawn_cows(_u, _n), do: err()
  def plant_aged(_u, _pos, _ago_ms), do: err()
  def plant(_u, _pos), do: err()
  def harvest(_u, _pos, _bag), do: err()
  def crop_at(_u, _pos), do: err()
  def dig(_u, _user, _on, _pos, _bag), do: err()
  def place(_u, _on, _pos, _item, _rot, _bag), do: err()
  def start_site(_u, _kind, _on, _pos, _rot), do: err()
  def deposit(_u, _site, _bag), do: err()
  def site_at(_u, _on, _pos), do: err()
  def furniture_at(_u, _on, _pos), do: err()
  def stash(_u, _at, _id, _bag, _slot), do: err()
  def take(_u, _at, _id, _slot, _bag), do: err()
  def grab(_u, _user, _at, _id, _bag), do: err()
  def pick_block(_u, _user, _at, _on, _pos), do: err()
  def pick_cow(_u, _user, _at, _id), do: err()
  def put_down(_u, _user, _on, _pos, _rot), do: err()
  def release(_u, _user), do: err()
  def take_helm(_u, _user, _at), do: err()
  def leave_helm(_u, _user), do: err()
  def steer(_u, _user, _helm), do: err()
  def arrive(_u, _cargo, _from), do: err()
  def call_helper(_u, _user, _id), do: err()
  def tick(_u, _now_ms, _players), do: err()
  def drain(_u), do: err()
  def snapshot(_u), do: err()
  def catalog, do: err()
  def starter_bag, do: err()
  def bag_add(_bag, _item, _n), do: err()
  def bag_take(_bag, _item, _n), do: err()
  def bag_give(_bag, _item, _n), do: err()

  # Passwords (Argon2id, on dirty CPU schedulers): see `Sosh.Accounts`.
  def hash_password(_password), do: err()
  def verify_password(_password, _hash), do: err()
  def no_user_verify(_password), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
