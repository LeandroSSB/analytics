# Run inside the plausible container, e.g.:
#   docker cp deploy/bootstrap-admin.exs plausible:/tmp/bootstrap-admin.exs
#   docker exec plausible /app/bin/plausible eval /tmp/bootstrap-admin.exs
# Env: ADMIN_EMAIL (required), ADMIN_NAME (default "Admin"), ADMIN_PASSWORD (required)
alias Plausible.Repo
alias Plausible.Auth.User

email = System.fetch_env!("ADMIN_EMAIL")
name  = System.get_env("ADMIN_NAME", "Admin")
pass  = System.fetch_env!("ADMIN_PASSWORD")

user =
  case Repo.get_by(User, email: email) do
    nil ->
      %User{}
      |> User.new(%{"name" => name, "email" => email, "password" => pass})
      |> Repo.insert!()
    existing ->
      existing
  end

user =
  user
  |> User.changeset(%{email_verified: true})
  |> Repo.update!()

IO.puts("OK admin bootstrapped id=#{user.id} email=#{user.email} email_verified=#{user.email_verified}")
