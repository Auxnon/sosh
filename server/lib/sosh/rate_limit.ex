defmodule Sosh.RateLimit do
  @moduledoc """
  Fixed-window counters in ETS: `hit({:login, email}, 10, :timer.minutes(15))`
  is `:ok` for the first 10 hits on that key in a window and `{:error,
  :rate_limited}` after. Windows are swept now and then; nothing survives a
  restart, which is fine for slowing guessing down.
  """
  use GenServer

  @table __MODULE__
  @sweep :timer.minutes(5)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def hit(key, limit, window_ms) do
    now = System.monotonic_time(:millisecond)
    window = div(now, window_ms)
    k = {key, window_ms, window}
    n = :ets.update_counter(@table, k, {2, 1}, {k, 0, now + window_ms})
    if n <= limit, do: :ok, else: {:error, :rate_limited}
  end

  @doc "Forget every counter. For tests."
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, s) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep)
    {:noreply, s}
  end
end
