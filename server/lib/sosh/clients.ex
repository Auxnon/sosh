defmodule Sosh.Clients do
  @moduledoc """
  Which app versions this server still talks to. The Android and desktop
  apps say who they are on every API request (`X-Sosh-Client:
  android/0.3.0`, `desktop/0.3.0`); one older than the server's minimum for
  it (`SOSH_MIN_ANDROID`, `SOSH_MIN_DESKTOP`) is answered `426
  update_required` with `%{min, download}`, and asks first with `GET
  /api/client` so it can say so before anyone signs in.

  Development builds are never turned away: a version with `-debug` or
  `-dev` in it, or `0.0.0-<commit>` from an untagged CI build. Nor is a
  request that doesn't say (the web game, which is always the server's own,
  and apps from before this).
  """

  @kinds ~w(android desktop)
  @download "https://github.com/Auxnon/sosh/releases/latest"

  @doc "`:ok`, or `{:update, %{min, download}}` for a client (`kind/version`) that's too old."
  def check(nil), do: :ok

  def check(client) when is_binary(client) do
    with [kind, version] <- String.split(client, "/", parts: 2),
         true <- kind in @kinds,
         min when is_binary(min) <- min(kind),
         {:ok, v} <- Version.parse(version),
         false <- dev?(v),
         {:ok, m} <- Version.parse(min),
         :lt <- Version.compare(v, m) do
      {:update, %{min: min, download: download()}}
    else
      _ -> :ok
    end
  end

  def min(kind), do: Map.get(Application.get_env(:sosh, :min_client, %{}), kind)
  def download, do: Application.get_env(:sosh, :download_url) || @download

  defp dev?(%Version{major: 0, minor: 0, patch: 0}), do: true
  defp dev?(%Version{pre: pre}), do: Enum.any?(pre, &(to_string(&1) in ~w(debug dev)))
end
