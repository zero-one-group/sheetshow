defmodule Sheetshow.OAuth do
  @moduledoc """
  Sending somebody to a Google consent screen, and turning what comes back into
  a `Sheetshow.UserAccount` you can keep.

  Three of the four steps are pure, and the fourth is one request:

      account = Sheetshow.UserAccount.new(client_id, client_secret)
      verifier = Sheetshow.OAuth.verifier()
      state = Sheetshow.OAuth.state()

      url = Sheetshow.OAuth.consent_url(account,
              redirect_uri: "http://127.0.0.1:8910",
              verifier: verifier,
              state: state)

      # open `url`, let them sign in, catch the redirect: all yours
      {:ok, code} = Sheetshow.OAuth.code(redirect_url, state)
      {:ok, account} = Sheetshow.OAuth.authorize(code, account,
                         redirect_uri: "http://127.0.0.1:8910", verifier: verifier)

      File.write!(path, Sheetshow.UserAccount.to_json(account))

  **What is not here is the browser and the listener.** Opening a browser and
  running an HTTP server to catch the redirect are a runtime, and runtimes are
  the application's, not the library's. For a command-line tool the shortest
  honest version is to print the URL, let the person paste the address they land
  on back in, and hand that to `code/2`.

  ## The two things worth knowing

  **`access_type: "offline"` and `prompt: "consent"` are the defaults**, because
  without them Google gives you a refresh token the *first* time somebody
  approves your app and never again, so the second person to run your setup
  gets an access token that dies in an hour and no way to get another. Asking
  every time costs a click and removes a whole class of confused bug report.

  **PKCE is on by default.** Pass the `:verifier` from `verifier/0` to both
  `consent_url/2` and `authorize/3`; it never leaves your machine, and it is
  what stops a code intercepted on its way back from being worth anything.

  ## Two of Google's rules that will bite you rather than us

  A refresh token issued while the app's publishing status is **"Testing"**
  stops working **seven days** after consent. Nothing here can tell the
  difference between that and a revoked grant, since both arrive as
  `%Sheetshow.Error{reason: :auth}` saying the token was expired or revoked, so
  if a credential dies a week after it was made, that is why, and publishing the
  app is the cure.

  And the **out-of-band flow is gone**: `urn:ietf:wg:oauth:2.0:oob` is refused.
  A desktop app redirects to loopback (`http://127.0.0.1:<port>`), and a desktop
  client needs no redirect URI registered, because Google accepts loopback on
  whatever port you pick. Letting that redirect fail to connect and reading the
  code out of the address bar is not the OOB flow: it is the loopback flow with
  the listener left as an exercise.
  """

  alias Sheetshow.{Error, Google, UserAccount}

  @auth_uri "https://accounts.google.com/o/oauth2/v2/auth"

  @doc """
  A PKCE code verifier: 86 characters of randomness to keep until `authorize/3`.

      iex> Sheetshow.OAuth.verifier() |> byte_size()
      86
  """
  @spec verifier() :: String.t()
  def verifier, do: random(64)

  @doc """
  The challenge that goes in the consent URL: the verifier's SHA-256, which is
  why the verifier itself never travels.

      iex> Sheetshow.OAuth.challenge("abc") |> byte_size()
      43
  """
  @spec challenge(String.t()) :: String.t()
  def challenge(verifier) when is_binary(verifier) do
    :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
  end

  @doc """
  Something random to send as `state` and compare when it comes back, so an
  answer to somebody else's request is not mistaken for an answer to yours.

      iex> Sheetshow.OAuth.state() |> byte_size()
      43
  """
  @spec state() :: String.t()
  def state, do: random(32)

  @doc """
  The URL to send somebody to.

  `:redirect_uri` is required and must be one the app is registered with.
  Options: `:scopes` (default `Sheetshow.Google.default_scopes/0`), `:state`, `:verifier` (PKCE,
  strongly recommended), `:access_type` (default `"offline"`), `:prompt`
  (default `"consent"`) and `:login_hint`.

      iex> account = Sheetshow.UserAccount.new("123.apps.googleusercontent.com", "s")
      iex> url = Sheetshow.OAuth.consent_url(account, redirect_uri: "http://127.0.0.1:8910")
      iex> %{query: query} = URI.parse(url)
      iex> params = URI.decode_query(query)
      iex> {params["client_id"], params["access_type"], params["response_type"]}
      {"123.apps.googleusercontent.com", "offline", "code"}

  Raises `ArgumentError` without a redirect URI, because there is nowhere for
  the answer to go.
  """
  @spec consent_url(UserAccount.t(), keyword()) :: String.t()
  def consent_url(%UserAccount{} = account, opts) do
    redirect_uri = Keyword.get(opts, :redirect_uri) || raise_no_redirect()

    query =
      [
        client_id: account.client_id,
        redirect_uri: redirect_uri,
        response_type: "code",
        scope: opts |> Keyword.get(:scopes, Google.default_scopes()) |> Enum.join(" "),
        access_type: Keyword.get(opts, :access_type, "offline"),
        prompt: Keyword.get(opts, :prompt, "consent")
      ]
      |> put(:state, Keyword.get(opts, :state))
      |> put(:login_hint, Keyword.get(opts, :login_hint))
      |> challenge_params(Keyword.get(opts, :verifier))

    @auth_uri <> "?" <> URI.encode_query(query)
  end

  @doc """
  The code out of the address the browser landed on, having checked that the
  `state` is the one you sent.

  A refusal at the consent screen comes back the same way, as a parameter rather
  than an error status, and is `{:error, %Sheetshow.Error{reason: :auth}}` here.

      iex> Sheetshow.OAuth.code("http://127.0.0.1:8910/?code=4/abc&state=xyz", "xyz")
      {:ok, "4/abc"}

      iex> {:error, %Sheetshow.Error{reason: :state_mismatch}} =
      ...>   Sheetshow.OAuth.code("http://127.0.0.1:8910/?code=4/abc&state=other", "xyz")

      iex> {:error, %Sheetshow.Error{reason: :auth}} =
      ...>   Sheetshow.OAuth.code("http://127.0.0.1:8910/?error=access_denied", "xyz")
  """
  @spec code(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, Error.t()}
  def code(redirect_url, state \\ nil) when is_binary(redirect_url) do
    params = redirect_url |> URI.parse() |> Map.get(:query) |> decode_query()

    cond do
      error = params["error"] ->
        {:error,
         Error.new(:auth, "the consent screen came back with #{inspect(error)}",
           error: error,
           description: params["error_description"]
         )}

      state != nil and params["state"] != state ->
        {:error,
         Error.new(
           :state_mismatch,
           "this answer carries a different state from the request it should be answering",
           expected: state,
           found: params["state"]
         )}

      is_binary(params["code"]) ->
        {:ok, params["code"]}

      true ->
        {:error,
         Error.new(:auth, "there is no code in #{inspect(redirect_url)}", url: redirect_url)}
    end
  end

  @doc """
  The exchange request as data, where to post and what to post, for whichever
  HTTP client is doing the talking. Takes `authorize/3`'s options.

      Sheetshow.OAuth.exchange_request(code, account, redirect_uri: uri, verifier: verifier)
      %{url: "https://oauth2.googleapis.com/token", form: %{grant_type: "authorization_code", ...}}
  """
  @spec exchange_request(String.t(), UserAccount.t(), keyword()) :: %{
          url: String.t(),
          form: map()
        }
  def exchange_request(code, %UserAccount{} = account, opts) when is_binary(code) do
    redirect_uri = Keyword.get(opts, :redirect_uri) || raise_no_redirect()

    form =
      %{
        grant_type: "authorization_code",
        code: code,
        client_id: account.client_id,
        client_secret: account.client_secret,
        redirect_uri: redirect_uri
      }
      |> put_verifier(Keyword.get(opts, :verifier))

    %{url: account.token_uri, form: form}
  end

  @doc """
  Trades the code for a refresh token, and gives back the same account with it.

  Options: `:redirect_uri` (required, and the same one `consent_url/2` was given),
  `:verifier` (the same one too, if you used PKCE) and `:http`, which passes
  `:timeout`, `:connect_timeout` and `:ssl` through as `Sheetshow.Client` does.

  The access token that comes back with it is deliberately dropped. Authorizing
  is a setup step somebody runs once, and the token would be an hour from dead
  before the program that needs it starts; `Sheetshow.connect/1` gets a fresh one
  from the refresh token in a single request.

      {:ok, account} = Sheetshow.OAuth.authorize(code, account, redirect_uri: uri, verifier: verifier)
      File.write!(path, Sheetshow.UserAccount.to_json(account))

  `{:error, %Sheetshow.Error{reason: :auth}}` when Google refuses: a code used
  twice, a redirect URI that does not match the one the code was made for, or a
  verifier that does not go with the challenge.
  """
  @spec authorize(String.t(), UserAccount.t(), keyword()) ::
          {:ok, UserAccount.t()} | {:error, Error.t()}
  def authorize(code, %UserAccount{} = account, opts) when is_binary(code) do
    Google.Backend.exchange(
      exchange_request(code, account, opts),
      account,
      Keyword.get(opts, :http, [])
    )
  end

  @doc "Same as `authorize/3`, raising on failure."
  @spec authorize!(String.t(), UserAccount.t(), keyword()) :: UserAccount.t()
  def authorize!(code, %UserAccount{} = account, opts) do
    code |> authorize(account, opts) |> Error.unwrap!()
  end

  defp challenge_params(query, nil), do: query

  defp challenge_params(query, verifier) do
    query ++ [code_challenge: challenge(verifier), code_challenge_method: "S256"]
  end

  defp put_verifier(form, nil), do: form
  defp put_verifier(form, verifier), do: Map.put(form, :code_verifier, verifier)

  defp put(query, _key, nil), do: query
  defp put(query, key, value), do: query ++ [{key, value}]

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)

  defp random(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp raise_no_redirect do
    raise ArgumentError,
          "redirect_uri: is required, and has to be one the app is registered with; " <>
            "for a command-line tool that is usually a loopback address such as " <>
            ~s("http://127.0.0.1:8910")
  end
end
