defmodule Sheetshow.OAuthTest do
  use ExUnit.Case, async: true

  doctest Sheetshow.OAuth
  doctest Sheetshow.UserAccount

  alias Sheetshow.{Client, Error, OAuth, TestServer, UserAccount, Workbook}

  @id "123.apps.googleusercontent.com"
  @secret "GOCSPX-not-a-real-secret"
  @redirect "http://localhost:8910"

  defp account(opts \\ []), do: UserAccount.new(@id, @secret, opts)

  defp params(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  describe "consent_url" do
    test "asks for offline access and a fresh consent, so a refresh token comes back" do
      query = account() |> OAuth.consent_url(redirect_uri: @redirect) |> params()

      assert query["client_id"] == @id
      assert query["redirect_uri"] == @redirect
      assert query["response_type"] == "code"
      assert query["access_type"] == "offline"
      assert query["prompt"] == "consent"
      assert query["scope"] == "https://www.googleapis.com/auth/spreadsheets"
    end

    test "goes to Google's authorization endpoint" do
      url = OAuth.consent_url(account(), redirect_uri: @redirect)
      assert String.starts_with?(url, "https://accounts.google.com/o/oauth2/v2/auth?")
    end

    test "several scopes are one space-separated parameter" do
      query =
        account()
        |> OAuth.consent_url(redirect_uri: @redirect, scopes: ["one", "two"])
        |> params()

      assert query["scope"] == "one two"
    end

    test "carries the PKCE challenge, and says how it was made" do
      verifier = OAuth.verifier()

      query =
        account() |> OAuth.consent_url(redirect_uri: @redirect, verifier: verifier) |> params()

      assert query["code_challenge"] == OAuth.challenge(verifier)
      assert query["code_challenge_method"] == "S256"
      refute query["code_challenge"] == verifier
    end

    test "leaves out what it was not given" do
      query = account() |> OAuth.consent_url(redirect_uri: @redirect) |> params()

      refute Map.has_key?(query, "state")
      refute Map.has_key?(query, "login_hint")
      refute Map.has_key?(query, "code_challenge")
    end

    test "takes state, login_hint and a prompt of your own" do
      query =
        account()
        |> OAuth.consent_url(
          redirect_uri: @redirect,
          state: "xyz",
          login_hint: "user@example.com",
          prompt: "select_account"
        )
        |> params()

      assert query["state"] == "xyz"
      assert query["login_hint"] == "user@example.com"
      assert query["prompt"] == "select_account"
    end

    test "without somewhere for the answer to go, there is nothing to build" do
      assert_raise ArgumentError, ~r/redirect_uri/, fn ->
        OAuth.consent_url(account(), [])
      end
    end
  end

  describe "PKCE" do
    test "the challenge is the verifier's SHA-256, base64url without padding" do
      # The digest of "abc" is the one everybody's test vectors use.
      assert OAuth.challenge("abc") == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"
    end

    test "a verifier is long, random and URL-safe" do
      one = OAuth.verifier()
      two = OAuth.verifier()

      assert byte_size(one) in 43..128
      refute one == two
      assert one =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "state is random and URL-safe too" do
      refute OAuth.state() == OAuth.state()
      assert OAuth.state() =~ ~r/^[A-Za-z0-9_-]+$/
    end
  end

  describe "code" do
    test "takes the code out of the address the browser landed on" do
      assert OAuth.code("#{@redirect}/?state=xyz&code=4/0Ab_C-d", "xyz") == {:ok, "4/0Ab_C-d"}
    end

    test "an answer carrying somebody else's state is not an answer to yours" do
      assert {:error, %Error{reason: :state_mismatch} = error} =
               OAuth.code("#{@redirect}/?code=4/abc&state=other", "xyz")

      assert error.details.expected == "xyz"
      assert error.details.found == "other"
    end

    test "an answer with no state at all, when one was sent, is refused" do
      assert {:error, %Error{reason: :state_mismatch}} =
               OAuth.code("#{@redirect}/?code=4/abc", "xyz")
    end

    test "without a state to compare, it does not pretend to check one" do
      assert OAuth.code("#{@redirect}/?code=4/abc") == {:ok, "4/abc"}
    end

    test "a refusal at the consent screen arrives as a parameter, not a status" do
      assert {:error, %Error{reason: :auth} = error} =
               OAuth.code("#{@redirect}/?error=access_denied&state=xyz", "xyz")

      assert error.details.error == "access_denied"
      assert error.message =~ "access_denied"
    end

    test "an address with nothing in it says so" do
      assert {:error, %Error{reason: :auth} = error} = OAuth.code(@redirect)
      assert error.message =~ "no code"
    end
  end

  describe "exchange_request" do
    test "is the authorization_code grant, as data" do
      request = OAuth.exchange_request("4/abc", account(), redirect_uri: @redirect)

      assert request.url == "https://oauth2.googleapis.com/token"

      assert request.form == %{
               grant_type: "authorization_code",
               code: "4/abc",
               client_id: @id,
               client_secret: @secret,
               redirect_uri: @redirect
             }
    end

    test "carries the verifier itself, which is the half Google has not seen" do
      request =
        OAuth.exchange_request("4/abc", account(), redirect_uri: @redirect, verifier: "v")

      assert request.form.code_verifier == "v"
    end

    test "an option nobody reads is refused, here and at the consent screen" do
      assert_raise ArgumentError, ~r/unknown keys \[:verifer\]/, fn ->
        OAuth.exchange_request("4/abc", account(), redirect_uri: @redirect, verifer: "v")
      end

      assert_raise ArgumentError, ~r/unknown keys \[:redirect\]/, fn ->
        OAuth.consent_url(account(), redirect: @redirect)
      end

      assert_raise ArgumentError, ~r/unknown keys \[:refresh\]/, fn ->
        UserAccount.new(@id, @secret, refresh: "1//r")
      end
    end
  end

  describe "UserAccount" do
    test "reads and writes the authorized_user JSON gcloud uses" do
      json = UserAccount.to_json(account(refresh_token: "1//r"))

      assert JSON.decode!(json) == %{
               "type" => "authorized_user",
               "client_id" => @id,
               "client_secret" => @secret,
               "refresh_token" => "1//r"
             }

      assert {:ok, read} = UserAccount.from_json(json)
      assert read == account(refresh_token: "1//r")
    end

    test "reads a file, and says which one it could not" do
      path =
        Path.join(System.tmp_dir!(), "sheetshow-user-#{System.unique_integer([:positive])}.json")

      File.write!(path, UserAccount.to_json(account(refresh_token: "1//r")))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %UserAccount{refresh_token: "1//r"}} = UserAccount.from_file(path)

      assert {:error, %Error{reason: :invalid_credentials} = error} =
               UserAccount.from_file(path <> ".nope")

      assert error.message =~ "could not read"
    end

    test "a service-account key is not one of these" do
      assert {:error, %Error{reason: :invalid_credentials} = error} =
               UserAccount.from_json(~s({"type":"service_account","client_email":"a@b"}))

      assert error.details.type == "service_account"
    end

    test "a credential missing what it needs says which part" do
      assert {:error, %Error{reason: :invalid_credentials} = error} =
               UserAccount.from_json(~s({"type":"authorized_user","client_id":"123"}))

      assert error.details.key == "client_secret"
    end

    test "a file with no refresh token in it is an account that has not been through consent" do
      json = ~s({"type":"authorized_user","client_id":"123","client_secret":"s"})

      assert {:ok, account} = UserAccount.from_json(json)
      refute UserAccount.authorized?(account)

      assert {:error, %Error{reason: :no_refresh_token} = error} =
               UserAccount.token_request(account)

      assert error.message =~ "consent"
    end

    test "the refresh grant is what a token request asks with" do
      assert {:ok, request} = UserAccount.token_request(account(refresh_token: "1//r"))

      assert request.form == %{
               grant_type: "refresh_token",
               refresh_token: "1//r",
               client_id: @id,
               client_secret: @secret
             }
    end

    test "neither secret shows up when one is inspected" do
      shown = inspect(account(refresh_token: "1//r"))

      assert shown =~ @id
      refute shown =~ @secret
      refute shown =~ "1//r"
    end
  end

  describe "authorize" do
    test "trades the code for an account with a refresh token on it" do
      body = ~s({"access_token":"ya29.new","expires_in":3599,"refresh_token":"1//new"})
      url = TestServer.start([{200, body}])

      assert {:ok, authorized} =
               OAuth.authorize("4/abc", account(token_uri: url), redirect_uri: @redirect)

      assert authorized.refresh_token == "1//new"
      assert authorized.client_id == @id

      assert_receive {:request, request}
      assert request.method == :POST
      assert request.headers["content-type"] == "application/x-www-form-urlencoded"

      form = URI.decode_query(request.body)
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "4/abc"
      assert form["redirect_uri"] == @redirect
    end

    test "an answer with no refresh token is the prompt: consent mistake, and says so" do
      url = TestServer.start([{200, ~s({"access_token":"ya29.new","expires_in":3599})}])

      assert {:error, %Error{reason: :no_refresh_token} = error} =
               OAuth.authorize("4/abc", account(token_uri: url), redirect_uri: @redirect)

      assert error.message =~ "prompt"
      refute error.details.response["access_token"]
    end

    test "what Google says when it refuses the code is what you get" do
      body = ~s({"error":"invalid_grant","error_description":"Bad Request"})
      url = TestServer.start([{400, body}])

      assert {:error, %Error{reason: :auth} = error} =
               OAuth.authorize("4/used-already", account(token_uri: url), redirect_uri: @redirect)

      assert error.message =~ "Bad Request"
    end

    test "authorize! raises what authorize returns" do
      url = TestServer.start([{400, ~s({"error":"invalid_grant"})}])

      assert_raise Error, fn ->
        OAuth.authorize!("4/abc", account(token_uri: url), redirect_uri: @redirect)
      end
    end
  end

  describe "authenticating as a user" do
    test "a refresh gets a token, and the workbook is ready" do
      url = TestServer.start([{200, ~s({"access_token":"ya29.new","expires_in":3599})}])

      workbook =
        Workbook.google("1AbC", credentials: account(refresh_token: "1//r", token_uri: url))

      assert {:ok, workbook} = Sheetshow.authenticate(workbook)
      assert workbook.ref.token.access_token == "ya29.new"
      assert workbook.ref.token.scopes == ["https://www.googleapis.com/auth/spreadsheets"]
      assert Client.ready?(workbook.ref)

      assert_receive {:request, request}
      form = URI.decode_query(request.body)
      assert form["grant_type"] == "refresh_token"
      assert form["refresh_token"] == "1//r"
      assert form["client_secret"] == @secret
    end

    test "a refresh token Google rotates is kept, not dropped" do
      body = ~s({"access_token":"ya29.new","expires_in":3599,"refresh_token":"1//rotated"})
      url = TestServer.start([{200, body}])

      workbook =
        Workbook.google("1AbC", credentials: account(refresh_token: "1//old", token_uri: url))

      assert {:ok, workbook} = Sheetshow.authenticate(workbook)
      assert workbook.ref.credentials.refresh_token == "1//rotated"
    end

    test "a refresh token Google leaves alone stays where it was" do
      url = TestServer.start([{200, ~s({"access_token":"ya29.new","expires_in":3599})}])

      workbook =
        Workbook.google("1AbC", credentials: account(refresh_token: "1//r", token_uri: url))

      assert {:ok, workbook} = Sheetshow.authenticate(workbook)
      assert workbook.ref.credentials.refresh_token == "1//r"
    end

    test "a revoked grant is an auth error, as it is for a service account" do
      body =
        ~s({"error":"invalid_grant","error_description":"Token has been expired or revoked."})

      url = TestServer.start([{400, body}])

      workbook =
        Workbook.google("1AbC", credentials: account(refresh_token: "1//gone", token_uri: url))

      assert {:error, %Error{reason: :auth} = error} = Sheetshow.authenticate(workbook)
      assert error.message =~ "revoked"
    end

    test "an account that has not been through consent never leaves the house" do
      workbook = Workbook.google("1AbC", credentials: account())

      assert {:error, %Error{reason: :no_refresh_token}} = Sheetshow.authenticate(workbook)
    end

    test "connect works the same as it does for a service account" do
      url =
        TestServer.start([
          {200, ~s({"access_token":"ya29.new","expires_in":3599})},
          {200, ~s({"sheets":[{"properties":{"sheetId":0,"title":"Sheet1"}}]})}
        ])

      workbook =
        Workbook.google("1AbC",
          base_url: url,
          credentials: account(refresh_token: "1//r", token_uri: url <> "/token")
        )

      assert {:ok, workbook} = Sheetshow.connect(workbook)
      assert workbook.sheets == %{"Sheet1" => 0}
      assert Client.ready?(workbook.ref)

      assert_receive {:request, %{path: "/token"}}
      assert_receive {:request, %{path: "/v4/spreadsheets/1AbC"}}
    end
  end
end
