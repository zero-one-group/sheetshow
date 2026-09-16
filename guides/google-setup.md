# Setting Up Google

Sheetshow talks to the Sheets API with a token, and a token comes from one of
two credentials: a service account, or a person's own Google account. This page
walks through making either in the Google Cloud console and handing it to
`Sheetshow.connect/1`. It takes about ten minutes and needs no billing account.

Note that Sheetshow never looks for a credential of its own accord: there is no
well-known path, no environment variable and no cache. We read the file, and we
hold the value. The `elixir` snippets on this page that need no account are run
by the test suite; the ones that reach Google or a browser are marked as such
in the prose.

## Two Kinds of Credential

A **service account** is a robot: it has an email address of its own, a private
key, and nothing else. A spreadsheet has to be shared with that email, exactly
as we would share it with a colleague, and then the robot sees that spreadsheet
and no other. Nobody has to be at a keyboard when it authenticates, which makes
it the right credential for a server, a scheduled job or a test suite. Its key
file is the whole secret, so wherever the file goes, the access goes with it.

A **user account** acts as the person who signed in, and sees the spreadsheets
they see. It needs a consent screen once (a browser, a Google login, a click on
*Allow*), and what comes back is a refresh token, which is the thing worth
keeping. It is the right credential for a tool a person runs against their own
spreadsheets, and the wrong one for anything that has to work at three in the
morning without them.

If in doubt: a service account. It is the simpler of the two by some distance,
and it is what the [Google quick start](quick-start-google.md) assumes.

## A Project, and the Sheets API

Both credentials live in a Google Cloud project, which is free to make.

1. Go to the [Google Cloud console](https://console.cloud.google.com/) and make
   a new project. Any name will do; it is visible only to us.
2. Under **APIs & Services → Library**, find **Google Sheets API** and click
   **Enable**. Nothing else needs enabling, since Sheetshow never touches
   Drive: a workbook is always an existing spreadsheet's id.

That is all. No billing account, and no IAM roles.

## A Service Account

Under **IAM & Admin → Service Accounts**, click **Create service account**, give
it a name, and click **Done**. The console offers to grant the account roles on
the project; we skip that, because the account needs none. Its whole access
will be the spreadsheets we share with it.

Open the account, go to the **Keys** tab, and choose **Add key → Create new key
→ JSON**. A file downloads. Google keeps no copy, so if we lose it we make
another; and anyone holding it is the account, so it goes nowhere near a
repository ([Google's steps](https://developers.google.com/workspace/guides/create-credentials#service-account)).

The file names the account's email as `client_email`, something like
`sheetshow@our-project.iam.gserviceaccount.com`. Open the spreadsheet in a
browser, click **Share**, paste that email in, and give it **Editor**. Viewer
would do for a workbook we only read.

The spreadsheet's id is the long string in its URL, between `/d/` and `/edit`.
With that and the file, connecting is two lines; this block reaches Google, so
the tests do not run it:

<!-- guide-test: skip -->
```elixir
account = Sheetshow.ServiceAccount.from_file!("service-account.json")

{:ok, workbook} =
  "1AbC...the id from the URL"
  |> Sheetshow.Workbook.google(credentials: account)
  |> Sheetshow.connect()

Sheetshow.Workbook.titles(workbook)
```

`from_file!/1` decodes the private key there and then, so a credential that
parses is one that can sign; inspecting the account shows everything but the
key. In an application we would keep the path in configuration or an
environment variable and read the file at startup, and in CI, where a file is
awkward, `Sheetshow.ServiceAccount.from_json!/1` takes the JSON itself from a
secret.

## A User Account

This is the longer road, and three of its four steps are in the console.

### The Consent Screen

Under **Google Auth Platform** (the console used to call it *OAuth consent
screen*), click **Get started**: an app name, a support email, and under
**Audience** the type **External**. The app is created in the *Testing*
publishing status, which is the right place to start and has one consequence
we come back to below.

Two more things while we are here. Under **Audience → Test users**, add every
Google account that will sign in while the app is in Testing; a login from any
other account is refused at the consent screen. And under **Data access**, add
the scope `https://www.googleapis.com/auth/spreadsheets`, which is the one
Sheetshow asks for.

### A Client

Under **Google Auth Platform → Clients**, click **Create client**, choose the
application type **Desktop app**, and give it a name
([Google's steps](https://developers.google.com/workspace/guides/create-credentials#desktop-app)).
The console shows a client id and a client secret; the secret is shown once, so
we copy it now. A desktop client registers no redirect URIs, because Google
accepts a redirect to loopback, `http://127.0.0.1` on whatever port we pick,
without being told about it beforehand
([loopback redirects](https://developers.google.com/identity/protocols/oauth2/native-app#loopback-ip-address-macos-linux-windows-desktop)).

### Consent, Once

Sheetshow's half of the flow is `Sheetshow.OAuth`: three pure functions and one
request. Opening a browser and running a server to catch the redirect are a
runtime, and runtimes belong to our application rather than to the library. For
a command-line tool the shortest honest version is to print the URL, let the
person paste back the address they land on, and hand that to
`Sheetshow.OAuth.code/2`. The browser fails to load `127.0.0.1:8910`, which is
the moment it has worked. This block needs a person and a browser, so the tests
do not run it:

<!-- guide-test: skip -->
```elixir
account = Sheetshow.UserAccount.new(client_id, client_secret)
verifier = Sheetshow.OAuth.verifier()
state = Sheetshow.OAuth.state()
redirect_uri = "http://127.0.0.1:8910"

url = Sheetshow.OAuth.consent_url(account, redirect_uri: redirect_uri, verifier: verifier, state: state)
IO.puts("Open this, sign in, approve, and paste back the address you land on:\n\n#{url}\n")
landed_on = IO.gets("> ") |> String.trim()

{:ok, code} = Sheetshow.OAuth.code(landed_on, state)
{:ok, account} = Sheetshow.OAuth.authorize(code, account, redirect_uri: redirect_uri, verifier: verifier)

File.write!("user.json", Sheetshow.UserAccount.to_json(account))
File.chmod!("user.json", 0o600)
```

The `verifier` is PKCE: its hash goes in the URL, the verifier itself goes in
the exchange, and a code intercepted on its way back is worth nothing without
it. The `state` is what stops an answer to somebody else's request being taken
for an answer to ours. Both are on by default in the sense that `consent_url/2`
and `authorize/3` take them; we only have to pass the same values to both.

The two pure steps in the middle can be shown without a browser. Consider the
address the browser lands on, and what `code/2` makes of it:

```elixir
{:ok, "4/abc"} = Sheetshow.OAuth.code("http://127.0.0.1:8910/?code=4/abc&state=xyz", "xyz")

{:error, %Sheetshow.Error{reason: :state_mismatch}} =
  Sheetshow.OAuth.code("http://127.0.0.1:8910/?code=4/abc&state=other", "xyz")

{:error, %Sheetshow.Error{reason: :auth}} =
  Sheetshow.OAuth.code("http://127.0.0.1:8910/?error=access_denied", "xyz")
```

A refusal at the consent screen arrives the same way, as a parameter rather
than a status, and is an `:auth` error here. And an account has two stages,
which is what `authorized?/1` tells apart:

```elixir
unconsented = Sheetshow.UserAccount.new("123.apps.googleusercontent.com", "GOCSPX-secret")
false = Sheetshow.UserAccount.authorized?(unconsented)

consented = Sheetshow.UserAccount.new("123.apps.googleusercontent.com", "GOCSPX-secret", refresh_token: "1//r")
true = Sheetshow.UserAccount.authorized?(consented)

json = Sheetshow.UserAccount.to_json(consented)
{:ok, ^consented} = Sheetshow.UserAccount.from_json(json)
```

`to_json/1` writes the `authorized_user` shape that `gcloud` uses, so the file
is one anything else that reads the format will take, and `from_file/1` reads
the file `gcloud auth application-default login` writes, though a token from
that file only reaches Sheets if the login asked for the spreadsheets scope,
which `gcloud`'s does not by default.

### Afterwards

From then on the file is the credential, and connecting looks the same as it
does with a service account. This block reaches Google:

<!-- guide-test: skip -->
```elixir
account = Sheetshow.UserAccount.from_file!("user.json")

{:ok, workbook} =
  "1AbC...the id from the URL"
  |> Sheetshow.Workbook.google(credentials: account)
  |> Sheetshow.connect()
```

`connect/1` trades the refresh token for an access token that lasts an hour;
when Google rotates the refresh token on the way, the new one is put back on
the workbook's client rather than dropped, so a long-running application should
keep the workbook it is handed back.

## Two of Google's Rules That Will Look Like Bugs

**A refresh token from an app in Testing dies seven days after consent.** It
arrives as the same `invalid_grant` a revoked token does, an
`%Sheetshow.Error{reason: :auth}` saying the token was expired or revoked, and
nothing in the library can tell the two apart. So if a credential that worked
last week has stopped, this is why
([Google](https://developers.google.com/identity/protocols/oauth2#expiration)).
The cure is to publish the app, under **Audience → Publishing status**, which
costs an *unverified app* warning at the consent screen and a cap of a hundred
users until Google has verified the app. For a tool we and a few colleagues
run, going through consent again every week is the cheaper of the two.

**The out-of-band flow is gone.** `urn:ietf:wg:oauth:2.0:oob` as a redirect URI
is refused ([Google](https://developers.google.com/identity/protocols/oauth2/native-app#manual-copypaste-deprecated)).
Letting the loopback redirect fail to load and reading the code out of the
address bar, as above, is not that flow; it is the loopback flow with the
listener left as an exercise, and Google is content with it.

There is a third, smaller one: Google keeps at most a hundred refresh tokens
per account per client, and `consent_url/2` asks for a new one every time
(`prompt: "consent"` is the default, because without it Google issues a
refresh token on the first approval and never again). A setup script run a
hundred and one times retires the token from the first run.

## Scopes

The one scope Sheetshow asks for is
`https://www.googleapis.com/auth/spreadsheets`, which reads and writes the
spreadsheets the account can reach; it is
`Sheetshow.Google.default_scopes/0`. An application that only reads may prefer
`https://www.googleapis.com/auth/spreadsheets.readonly`, passed as `:scopes`
to `Sheetshow.Workbook.google/2`, so that a bug can at most read; a `run/2`
under that scope answers `:http` with a 403. For a user account the scope has
to be one the consent screen lists under **Data access**, and one the person
approved.

## When It Does Not Connect

`connect/1` makes two requests, one to `oauth2.googleapis.com` for a token and
then one to `sheets.googleapis.com` for the spreadsheet's sheets, and the error
names the host that refused, which says which half went wrong.

| the error | what it usually means |
| --- | --- |
| `:invalid_credentials` | the file is not what we think: most often an OAuth client's JSON downloaded where a service-account key was wanted, or the other way round |
| `:no_refresh_token` | a user account nobody has consented for; the file has the client but no `refresh_token` |
| `:auth` | the token endpoint refused: a wrong client secret, a revoked grant, a deleted service-account key, or the seven-day rule above |
| `:http` with `details.status` `403` | the token is good but the spreadsheet is not shared with this account, or the Sheets API is not enabled in the project, which Google also reports as a 403 that says so |
| `:http` with `details.status` `404` | no spreadsheet has that id; check the URL |
| `:transport` | no answer at all: DNS, TLS or a timeout. A café network and a VPN that needed connecting have both produced this |
| `:rate_limited` | sixty requests in a minute; `details.retry_after` says how long to wait when Google said |

Every reason is listed in `Sheetshow.Error`.

## For Contributors

The offline test suite needs nothing on this page. The integration tests need a
service account with Editor on one empty spreadsheet, and two environment
variables: `SHEETSHOW_TEST_CREDENTIALS`, the key file's path (or the JSON
itself, for CI), and `SHEETSHOW_TEST_SPREADSHEET_ID`. With those set,
`mix check.all` runs them; without them, they are not compiled at all. The
tests make tabs named `sheetshow <n>` and delete every one of them at the end
of the run, and touch nothing else in the spreadsheet.
