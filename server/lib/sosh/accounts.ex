defmodule Sosh.Accounts do
  @moduledoc """
  Accounts: sign up with an email, a handle and a password; confirm the
  email with a 6-digit code sent to it; sign in with email and password for
  a session token; reset a forgotten password with another emailed code.

  Security, at a medium level:
    * passwords are Argon2id-hashed in the Rust NIF (`Sosh.Universe.hash_password/1`),
      off the normal schedulers; a sign-in for an unknown email spends the
      same time as a real one
    * session tokens are 32 random bytes; codes are 6 digits that last 15
      minutes and die after 5 wrong guesses. Only SHA-256 digests are stored
    * sign-in, sign-up, resends and code guesses are rate limited per email
      and per caller (`Sosh.RateLimit`)
    * replies don't say whether an email has an account, except sign-up's
      "taken", which a unique address needs anyway
    * a new password signs out every session; sessions last 60 days and
      slide while used

  `:require_confirmation` (default true) can be turned off for local play.
  """
  import Ecto.Query
  require Logger

  alias Sosh.{RateLimit, Repo, Universe}
  alias Sosh.Accounts.{Notifier, User, UserToken}

  @session_days 60
  @code_minutes 15
  @code_attempts 5
  @window :timer.minutes(15)

  # -- lookups

  def get_user(id), do: Repo.get(User, id)

  def get_by_handle(handle) when is_binary(handle) do
    Repo.one(from u in User, where: fragment("lower(?)", u.handle) == ^String.downcase(handle))
  end

  def get_by_handle(_), do: nil

  def get_by_email(email) when is_binary(email) do
    Repo.one(
      from u in User,
        where: fragment("lower(?)", u.email) == ^(email |> String.trim() |> String.downcase())
    )
  end

  def get_by_email(_), do: nil

  # -- sign up

  @doc """
  `{:ok, user}` and a code emailed, or `{:error, changeset}` /
  `{:error, :rate_limited}`. Without `:require_confirmation` the account is
  confirmed straight away.
  """
  def register(attrs, caller \\ "local") do
    with :ok <- RateLimit.hit({:register, caller}, 10, :timer.hours(1)) do
      cs = User.registration_changeset(%User{}, attrs)

      with {:ok, cs} <- hash_into(cs),
           {:ok, user} <- Repo.insert(cs) do
        if require_confirmation?() do
          send_code(user, "confirm")
          {:ok, user}
        else
          confirm!(user)
        end
      end
    end
  end

  defp hash_into(%Ecto.Changeset{valid?: false} = cs), do: {:error, cs}

  defp hash_into(cs) do
    pw = Ecto.Changeset.get_change(cs, :password)
    {:ok, hash} = Universe.hash_password(pw)

    {:ok,
     cs
     |> Ecto.Changeset.put_change(:hashed_password, hash)
     |> Ecto.Changeset.delete_change(:password)}
  end

  def require_confirmation?,
    do: Application.get_env(:sosh, __MODULE__, [])[:require_confirmation] != false

  @doc "Email a new confirmation code (if the account needs one). Always `:ok`."
  def resend_confirmation(email) do
    with :ok <- RateLimit.hit({:resend, normalize(email)}, 3, @window),
         %User{confirmed_at: nil} = user <- get_by_email(email) do
      send_code(user, "confirm")
    end

    :ok
  end

  @doc "`{:ok, user, token}` signed in, or `{:error, :bad_code | :rate_limited}`."
  def confirm(email, code) do
    with %User{} = user <- get_by_email(email),
         :ok <- use_code(user, "confirm", code) do
      user = if user.confirmed_at, do: user, else: elem(confirm!(user), 1)
      {:ok, user, new_session(user)}
    else
      nil -> {:error, :bad_code}
      err -> err
    end
  end

  defp confirm!(user) do
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  # -- sign in

  @doc """
  `{:ok, user, token}`, or `{:error, :bad_login | :unconfirmed |
  :rate_limited}`. An unconfirmed account gets a fresh code.
  """
  def login(email, password, caller \\ "local")

  def login(email, password, caller) when is_binary(email) and is_binary(password) do
    email = normalize(email)

    with :ok <- RateLimit.hit({:login, email}, 10, @window),
         :ok <- RateLimit.hit({:login_from, caller}, 50, @window) do
      case get_by_email(email) do
        nil ->
          Universe.no_user_verify(password)
          {:error, :bad_login}

        user ->
          cond do
            not Universe.verify_password(password, user.hashed_password) ->
              {:error, :bad_login}

            require_confirmation?() and user.confirmed_at == nil ->
              send_code(user, "confirm")
              {:error, :unconfirmed}

            true ->
              {:ok, user, new_session(user)}
          end
      end
    end
  end

  def login(_, _, _), do: {:error, :bad_login}

  @doc "A new session token for `user`, as given to the client (url-safe base64)."
  def new_session(%User{id: id}) do
    raw = :crypto.strong_rand_bytes(32)

    Repo.insert!(%UserToken{
      user_id: id,
      token: UserToken.digest(raw),
      context: "session",
      last_used_at: DateTime.utc_now(:second)
    })

    Base.url_encode64(raw, padding: false)
  end

  @doc "The user a session token belongs to, or nil. Using it keeps it alive."
  def session_user(token) when is_binary(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false),
         %UserToken{} = t <-
           Repo.one(
             from t in UserToken,
               where: t.context == "session" and t.token == ^UserToken.digest(raw),
               preload: :user
           ) do
      cutoff = DateTime.add(DateTime.utc_now(), -@session_days * 86_400, :second)

      cond do
        DateTime.compare(t.last_used_at || t.inserted_at, cutoff) == :lt ->
          Repo.delete(t)
          nil

        true ->
          # only touch it once an hour, not on every request
          if DateTime.diff(DateTime.utc_now(), t.last_used_at || t.inserted_at) > 3600,
            do: Repo.update_all(from(x in UserToken, where: x.id == ^t.id), set: [last_used_at: DateTime.utc_now(:second)])

          t.user
      end
    else
      _ -> nil
    end
  end

  def session_user(_), do: nil

  def logout(token) when is_binary(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false) do
      Repo.delete_all(
        from t in UserToken, where: t.context == "session" and t.token == ^UserToken.digest(raw)
      )
    end

    :ok
  end

  def logout(_), do: :ok

  # -- passwords

  @doc "Email a reset code if the account exists. Always `:ok`."
  def forgot_password(email) do
    with :ok <- RateLimit.hit({:forgot, normalize(email)}, 3, @window),
         %User{} = user <- get_by_email(email) do
      send_code(user, "reset")
    end

    :ok
  end

  @doc """
  Set a new password with an emailed code: `{:ok, user, token}`, signing
  out every other session, or `{:error, :bad_code | changeset}`.
  """
  def reset_password(email, code, password) do
    with %User{} = user <- get_by_email(email),
         cs = User.password_changeset(user, %{password: password}),
         {:ok, cs} <- hash_into(cs),
         :ok <- use_code(user, "reset", code) do
      {:ok, user} =
        Repo.transaction(fn ->
          Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id and t.context == "session")
          # the code proved the address, so it's confirmed too
          cs = if user.confirmed_at, do: cs, else: Ecto.Changeset.put_change(cs, :confirmed_at, DateTime.utc_now(:second))
          Repo.update!(cs)
        end)

      {:ok, user, new_session(user)}
    else
      nil -> {:error, :bad_code}
      err -> err
    end
  end

  @doc "Change the password, knowing the current one. Signs out other sessions."
  def change_password(%User{} = user, current, new, keep_token) do
    if Universe.verify_password(current, user.hashed_password) do
      cs = User.password_changeset(user, %{password: new})

      with {:ok, cs} <- hash_into(cs) do
        keep =
          case Base.url_decode64(keep_token || "", padding: false) do
            {:ok, raw} -> UserToken.digest(raw)
            :error -> <<>>
          end

        Repo.transaction(fn ->
          Repo.delete_all(
            from t in UserToken,
              where: t.user_id == ^user.id and t.context == "session" and t.token != ^keep
          )

          Repo.update!(cs)
        end)
      end
    else
      {:error, :bad_login}
    end
  end

  # -- characters

  def set_character(%User{} = user, character) do
    user |> User.character_changeset(character) |> Repo.update()
  end

  # -- codes

  defp send_code(user, context) do
    <<n::unsigned-32>> = :crypto.strong_rand_bytes(4)
    code = Integer.to_string(100_000 + rem(n, 900_000))

    Repo.transaction(fn ->
      Repo.delete_all(from t in UserToken, where: t.user_id == ^user.id and t.context == ^context)

      Repo.insert!(%UserToken{
        user_id: user.id,
        token: UserToken.digest("#{user.id}:#{code}"),
        context: context,
        sent_to: user.email
      })
    end)

    if Application.get_env(:sosh, :log_codes, false),
      do: Logger.info("#{context} code for #{user.email}: #{code}")

    case context do
      "confirm" -> Notifier.confirm(user.email, user.handle, code)
      "reset" -> Notifier.reset(user.email, user.handle, code)
    end
  end

  # A code is good once, for 15 minutes, to the address it went to, and dies
  # after 5 wrong guesses.
  defp use_code(user, context, code) do
    code = if is_binary(code), do: String.trim(code), else: ""

    with :ok <- RateLimit.hit({:code, user.id}, 10, @window),
         %UserToken{} = t <-
           Repo.one(from t in UserToken, where: t.user_id == ^user.id and t.context == ^context) do
      fresh = DateTime.diff(DateTime.utc_now(), t.inserted_at) < @code_minutes * 60

      cond do
        not fresh or t.attempts >= @code_attempts or t.sent_to != user.email ->
          Repo.delete(t)
          {:error, :bad_code}

        Plug.Crypto.secure_compare(t.token, UserToken.digest("#{user.id}:#{code}")) ->
          Repo.delete(t)
          :ok

        true ->
          Repo.update_all(from(x in UserToken, where: x.id == ^t.id), inc: [attempts: 1])
          {:error, :bad_code}
      end
    else
      nil -> {:error, :bad_code}
      err -> err
    end
  end

  defp normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()
  defp normalize(_), do: ""
end
