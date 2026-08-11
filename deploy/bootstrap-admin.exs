# Bootstrap (or re-verify) the Plausible admin user without email.
#
# On CE, leaving ENABLE_EMAIL_VERIFICATION unset makes registered users
# auto-verified, but this script also forces email_verified: true so it works
# regardless of that setting.
#
# Run INSIDE the plausible container. `eval` does not start the supervision
# tree, so the repo is started explicitly via Ecto.Migrator.with_repo/2 (the
# same pattern Plausible.Release uses for migrations). Values are read from the
# process environment, so pass them with `docker exec -e`:
#
#   docker cp deploy/bootstrap-admin.exs plausible:/tmp/bootstrap-admin.exs
#   docker exec \
#     -e ADMIN_EMAIL=you@example.com \
#     -e ADMIN_NAME="Your Name" \
#     -e ADMIN_PASSWORD='strong-password' \
#     plausible /app/bin/plausible eval 'Code.eval_file("/tmp/bootstrap-admin.exs")'
#
# After it prints the user id, set ADMIN_USER_IDS=<id> in .env.production and
# restart the app to grant super-admin.

alias Plausible.Auth.User

email = System.fetch_env!("ADMIN_EMAIL")
name = System.get_env("ADMIN_NAME", "Admin")
pass = System.fetch_env!("ADMIN_PASSWORD")

Ecto.Migrator.with_repo(Plausible.Repo, fn repo ->
  user =
    case repo.get_by(User, email: email) do
      nil ->
        # User.new/1 builds the struct internally and hashes the password.
        # Do NOT pass %User{} as a first arg — there is no User.new/2.
        User.new(%{"name" => name, "email" => email, "password" => pass})
        |> repo.insert!()

      existing ->
        existing
    end

  user = user |> User.changeset(%{email_verified: true}) |> repo.update!()

  IO.puts(
    "OK admin bootstrapped id=#{user.id} email=#{user.email} email_verified=#{user.email_verified}"
  )
end)
