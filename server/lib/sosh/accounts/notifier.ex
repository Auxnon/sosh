defmodule Sosh.Accounts.Notifier do
  @moduledoc """
  The emails accounts get: a code to confirm the address, and one to reset
  the password. In development they land in the mailbox at /dev/mailbox
  (and the log).
  """
  import Swoosh.Email
  require Logger

  alias Sosh.Mailer

  @from {"sosh", "no-reply@sosh.local"}

  def confirm(email, handle, code) do
    deliver(email, "Your sosh code: #{code}", """
    Hi #{handle},

    Your code to confirm this address for sosh is

        #{code}

    It works for 15 minutes. If you didn't sign up, ignore this email.
    """)
  end

  def reset(email, handle, code) do
    deliver(email, "Reset your sosh password: #{code}", """
    Hi #{handle},

    Your code to set a new sosh password is

        #{code}

    It works for 15 minutes. If you didn't ask for it, ignore this email:
    your password stays as it is.
    """)
  end

  defp deliver(to, subject, body) do
    email = new() |> to(to) |> from(@from) |> subject(subject) |> text_body(body)

    if Application.get_env(:sosh, :log_codes, false),
      do: Logger.info("email to #{to}: #{subject}")

    case Mailer.deliver(email) do
      {:ok, _} -> :ok
      {:error, why} -> Logger.error("email to #{to} failed: #{inspect(why)}")
    end
  end
end
