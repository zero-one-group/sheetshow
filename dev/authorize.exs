# Runs the OAuth consent flow once and writes the credential it produces.
#
#     mix run dev/authorize.exs
#
# There is no loopback server here, on purpose: running one is a runtime, and
# runtimes belong to the application rather than to Sheetshow. The redirect will
# fail to load in the browser, and that is expected. Copy the address bar and paste
# it back, which is every bit as good and a great deal less machinery.
#
# Needs an OAuth client of type "Desktop app" in the Google Cloud console. A
# desktop client has no redirect URIs to register: Google accepts loopback
# (127.0.0.1 or ::1) on whatever port the app picks, which is what makes this
# work without telling the console anything.
#
# While the app's publishing status is "Testing", the refresh token this writes
# stops working seven days after consent. That is Google's rule for testing
# apps, not a bug here; run this again, or publish the app, when it does.
#
#     export SHEETSHOW_OAUTH_CLIENT_ID=...apps.googleusercontent.com
#     export SHEETSHOW_OAUTH_CLIENT_SECRET=GOCSPX-...
#     export SHEETSHOW_USER_CREDENTIALS=~/.config/sheetshow/user.json   # optional
#     export SHEETSHOW_TEST_SPREADSHEET_ID=...                          # optional, to verify

alias Sheetshow.{OAuth, UserAccount, Workbook}

redirect_uri = "http://127.0.0.1:8910"

ask = fn prompt ->
  case IO.gets(prompt) do
    :eof -> raise "nothing to read"
    answer -> String.trim(answer)
  end
end

client_id =
  System.get_env("SHEETSHOW_OAUTH_CLIENT_ID") || ask.("OAuth client id: ")

client_secret =
  System.get_env("SHEETSHOW_OAUTH_CLIENT_SECRET") || ask.("OAuth client secret: ")

path =
  (System.get_env("SHEETSHOW_USER_CREDENTIALS") || "~/.config/sheetshow/user.json")
  |> Path.expand()

account = UserAccount.new(client_id, client_secret)
verifier = OAuth.verifier()
state = OAuth.state()

url =
  OAuth.consent_url(account,
    redirect_uri: redirect_uri,
    verifier: verifier,
    state: state
  )

IO.puts("""

Open this, sign in as the account you want Sheetshow to act as, and approve it:

#{url}

The browser will then fail to load #{redirect_uri}, which is the point at which
it has worked. Copy the whole address out of the address bar.
""")

redirect_url = ask.("Paste the address: ")

with {:ok, code} <- OAuth.code(redirect_url, state),
     {:ok, authorized} <-
       OAuth.authorize(code, account, redirect_uri: redirect_uri, verifier: verifier) do
  File.mkdir_p!(Path.dirname(path))
  File.write!(path, UserAccount.to_json(authorized))
  File.chmod!(path, 0o600)

  IO.puts("\nWritten to #{path}.")

  case System.get_env("SHEETSHOW_TEST_SPREADSHEET_ID") do
    nil ->
      IO.puts("""
      Set SHEETSHOW_TEST_SPREADSHEET_ID and run this again to check the credential
      against a real spreadsheet.
      """)

    spreadsheet_id ->
      IO.puts("Checking it against #{spreadsheet_id}...")

      case spreadsheet_id |> Workbook.google(credentials: authorized) |> Sheetshow.connect() do
        {:ok, workbook} ->
          IO.puts("Connected as the signed-in user. Tabs: #{inspect(Workbook.titles(workbook))}")

        {:error, error} ->
          IO.puts("Could not connect: #{Exception.message(error)}")
      end
  end
else
  {:error, error} -> IO.puts("\n#{Exception.message(error)}")
end
