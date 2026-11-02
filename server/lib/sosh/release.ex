defmodule Sosh.Release do
  @moduledoc """
  Tasks for a release, where there's no Mix: `bin/sosh eval Sosh.Release.migrate`.
  The container runs it before every start (`rel/overlays/bin/server`).
  """
  @app :sosh

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    # The release's SSL/crypto apps for Postgrex, without starting sosh itself.
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
