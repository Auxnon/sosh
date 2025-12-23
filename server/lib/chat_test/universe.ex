defmodule ChatTest.Universe do
  use Rustler, otp_app: :chat_test, crate: "universe"

  # When your NIF is loaded, it will override this function.
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
  def bigbang(), do: :erlang.nif_error(:nif_not_loaded)
  def new_ent(_universe ), do: :erlang.nif_error(:nif_not_loaded)
  def move_ent(_universe, _id, _pos), do: :erlang.nif_error(:nif_not_loaded)
  def get_state(_universe), do: :erlang.nif_error(:nif_not_loaded)
end
