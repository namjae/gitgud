defmodule GitGud.User do
  @moduledoc """
  User account schema and helper functions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecto.Multi

  alias GitGud.DB

  alias GitGud.Auth
  alias GitGud.Email
  alias GitGud.Repo
  alias GitGud.SSHKey

  schema "users" do
    field :login, :string
    field :name, :string
    has_one :auth, Auth, on_replace: :update, on_delete: :delete_all
    belongs_to :primary_email, Email, on_replace: :update
    belongs_to :public_email, Email, on_replace: :update
    field :bio, :string
    field :url, :string
    field :location, :string
    has_many :emails, Email, on_delete: :delete_all
    has_many :repos, Repo, on_delete: :delete_all, foreign_key: :owner_id
    has_many :ssh_keys, SSHKey, on_delete: :delete_all
    timestamps()
  end

  @type t :: %__MODULE__{
    id: pos_integer,
    login: binary,
    name: binary,
    auth: Auth.t,
    primary_email: Email.t,
    public_email: Email.t,
    bio: binary,
    url: binary,
    location: binary,
    emails: [Email.t],
    repos: [Repo.t],
    ssh_keys: [SSHKey.t],
    inserted_at: NaiveDateTime.t,
    updated_at: NaiveDateTime.t
  }

  @doc """
  Creates a new user with the given `params`.

  ```elixir
  {:ok, user} = GitGud.User.create(
    login: "redrabbit",
    name: "Mario Flach",
    emails: [
      %{address: "m.flach@almightycouch.com"}
    ],
    auth: %{
      password: "qwertz"
    }
  )
  ```
  This function validates the given `params` using `registration_changeset/2`.
  """
  @spec create(map|keyword) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def create(params) do
    case create_and_set_primary_email(registration_changeset(%__MODULE__{}, Map.new(params))) do
      {:ok, %{user_with_primary_email: user}} ->
        {:ok, user}
      {:error, :user, changeset, _changes} ->
        {:error, changeset}
      {:error, :user_with_primary_email, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Similar to `create/1`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec create!(map|keyword) :: t
  def create!(params) do
    case create(params) do
      {:ok, user} -> user
      {:error, changeset} -> raise Ecto.InvalidChangesetError, action: changeset.action, changeset: changeset
    end
  end

  @doc """
  Updates the given `user` with the given `changeset_type` and `params`.

  ```elixir
  {:ok, user} = GitGud.User.update(user, :profile, name: "Mario Bros")
  ```

  Following changeset types are available:

  * `:profile` -- see `profile_changeset/2`.
  * `:password` -- see `password_changeset/2`.

  This function can also be used to update email associations, for example:

  ```elixir
  {:ok, user} = GitGud.User.update(user, :primary_email, email)
  ```
  """
  @spec update(t, atom, map|keyword) :: {:ok, t} | {:error, Ecto.Changeset.t}
  @spec update(t, atom, struct) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def update(%__MODULE__{} = user, changeset_type, params) do
    DB.update(update_changeset(user, changeset_type, params))
  end

  @doc """
  Similar to `update/3`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec update!(t, atom, map|keyword) :: t
  @spec update!(t, atom, struct) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def update!(%__MODULE__{} = user, changeset_type, params) do
    DB.update!(update_changeset(user, changeset_type, params))
  end

  @doc """
  Resets the given `user`'s password.
  """
  @spec reset_password(t) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def reset_password(%__MODULE__{} = user) do
    DB.update(change(user, auth: change(user.auth, password_hash: nil)))
  end

  @doc """
  Similar to `reset_password/1`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec reset_password!(t) :: t
  def reset_password!(%__MODULE__{} = user) do
    DB.update!(change(user, auth: change(user.auth, password_hash: nil)))
  end

  @doc """
  Deletes the given `user`.

  User associations (emails, repositories, etc.) will automatically be deleted.
  """
  @spec delete(t) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def delete(%__MODULE__{} = user) do
    DB.delete(user)
  end

  @doc """
  Similar to `delete!/1`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec delete!(t) :: t
  def delete!(%__MODULE__{} = user) do
    DB.delete!(user)
  end

  @doc """
  Returns `true` is `user` is verified; otherwise returns `false`.
  """
  @spec verified?(t) :: boolean
  def verified?(%__MODULE__{} = user) do
    !!user.primary_email_id
  end

  @doc """
  Returns a registration changeset for the given `params`.
  """
  @spec registration_changeset(t, map) :: Ecto.Changeset.t
  def registration_changeset(%__MODULE__{} = user, params \\ %{}) do
    user
    |> cast(params, [:login, :name, :bio, :url, :location])
    |> cast_assoc(:auth, required: true, with: &Auth.registration_changeset/2)
    |> cast_assoc(:emails, required: true, with: &Email.registration_changeset/2)
    |> validate_required([:login, :name])
    |> validate_login()
    |> validate_url()
    |> validate_oauth_email()
  end

  @doc """
  Returns a profile changeset for the given `params`.
  """
  @spec profile_changeset(t, map) :: Ecto.Changeset.t
  def profile_changeset(%__MODULE__{} = user, params \\ %{}) do
    user
    |> cast(params, [:name, :public_email_id, :bio, :url, :location])
    |> validate_required([:name])
    |> assoc_constraint(:public_email)
    |> validate_url()
  end

  @doc """
  Returns a password changeset for the given `params`.
  """
  @spec password_changeset(t, map) :: Ecto.Changeset.t
  def password_changeset(%__MODULE__{} = user, params \\ %{}) do
    user
    |> cast(%{auth: params}, [])
    |> cast_assoc(:auth, required: true, with: &Auth.password_changeset/2)
  end

  #
  # Helpers
  #

  defp create_and_set_primary_email(changeset) do
    Multi.new()
    |> Multi.insert(:user, changeset)
    |> Multi.run(:user_with_primary_email, &set_primary_email/2)
    |> DB.transaction()
  end

  defp set_primary_email(db, %{user: user}) do
    if email = Enum.find(user.emails, &(&1.verified)) do
      user
      |> update_changeset(:primary_email, email)
      |> db.insert()
    else
      {:ok, user}
    end
  end

  defp update_changeset(user, :profile, params), do: profile_changeset(user, Map.new(params))
  defp update_changeset(user, :password, params), do: password_changeset(user, Map.new(params))
  defp update_changeset(user, field, %Email{verified: true} = value) when field in [:primary_email, :public_email] do
    user
    |> struct([{field, nil}])
    |> change()
    |> put_assoc(field, value)
  end

  defp validate_login(changeset) do
    changeset
    |> validate_length(:login, min: 3, max: 24)
    |> validate_format(:login, ~r/^[a-zA-Z0-9_-]+$/)
    |> validate_exclusion(:login, ["auth", "login", "graphql", "logout", "new", "password", "register", "settings"])
    |> unique_constraint(:login)
  end

  defp validate_url(changeset) do
    if url = get_change(changeset, :url) do
      case URI.parse(url) do
        %URI{scheme: nil} ->
          add_error(changeset, :url, "invalid")
        %URI{host: nil} ->
          add_error(changeset, :url, "invalid")
        %URI{} ->
          changeset
      end
    end || changeset
  end

  defp validate_oauth_email(changeset) do
    if auth_changeset = get_change(changeset, :auth) do
      if get_change(auth_changeset, :providers) do
        put_change(changeset, :emails, Enum.map(get_change(changeset, :emails), &merge(&1, Email.verification_changeset(&1.data))))
      end
    end || changeset
  end
end
