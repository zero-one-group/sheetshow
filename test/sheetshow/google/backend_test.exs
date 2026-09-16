defmodule Sheetshow.Google.BackendTest do
  use ExUnit.Case, async: true

  alias Sheetshow.{Cell, Client, Error, ServiceAccount, TestServer, Token, Workbook}

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    %{pem: pem}
  end

  defp credentials(pem, token_uri) do
    ServiceAccount.from_json!(
      JSON.encode!(%{
        "type" => "service_account",
        "client_email" => "tests@example.iam.gserviceaccount.com",
        "private_key" => pem,
        "token_uri" => token_uri
      })
    )
  end

  defp workbook(url, opts \\ []) do
    Workbook.google("1AbC", Keyword.merge([base_url: url], opts))
  end

  defp token, do: Token.new("ya29.abc", DateTime.add(DateTime.utc_now(), 3600, :second))

  describe "authenticate" do
    test "trades the assertion for a token", %{pem: pem} do
      url = TestServer.start([{200, ~s({"access_token":"ya29.new","expires_in":3599})}])
      workbook = workbook(url, credentials: credentials(pem, url <> "/token"))

      assert {:ok, workbook} = Sheetshow.authenticate(workbook)
      assert workbook.ref.token.access_token == "ya29.new"
      assert workbook.ref.token.scopes == ["https://www.googleapis.com/auth/spreadsheets"]
      assert Client.ready?(workbook.ref)

      assert_receive {:request, request}
      assert request.method == :POST
      assert request.path == "/token"
      assert request.headers["content-type"] == "application/x-www-form-urlencoded"

      form = URI.decode_query(request.body)
      assert form["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
      assert [_header, _claims, _signature] = String.split(form["assertion"], ".")
    end

    test "what Google says when it refuses is what you get", %{pem: pem} do
      body = ~s({"error":"invalid_grant","error_description":"Invalid JWT Signature."})
      url = TestServer.start([{400, body}])
      workbook = workbook(url, credentials: credentials(pem, url <> "/token"))

      assert {:error, %Error{reason: :auth} = error} = Sheetshow.authenticate(workbook)
      assert error.message =~ "Invalid JWT Signature."
    end

    test "a workbook with no credentials says so, before any request" do
      assert {:error, %Error{reason: :no_credentials}} =
               Sheetshow.authenticate(workbook("http://127.0.0.1:1"))
    end
  end

  describe "fetch_sheets" do
    test "learns every tab and the number Google knows it by" do
      body = ~s({"sheets":[{"properties":{"sheetId":0,"title":"Sheet1"}},
                           {"properties":{"sheetId":417,"title":"Costs"}}]})

      url = TestServer.start([{200, body}])

      assert {:ok, workbook} = Sheetshow.fetch_sheets(workbook(url, token: token()))
      assert workbook.sheets == %{"Sheet1" => 0, "Costs" => 417}

      assert_receive {:request, request}
      assert request.method == :GET
      assert request.path == "/v4/spreadsheets/1AbC"
      assert request.query == %{"fields" => "sheets.properties(sheetId,title)"}
      assert request.headers["authorization"] == "Bearer ya29.abc"
    end

    test "an error carries the reason Google gave, not just the status" do
      body = ~s({"error":{"code":403,"message":"The caller does not have permission"}})
      url = TestServer.start([{403, body}])

      assert {:error, %Error{reason: :http} = error} =
               Sheetshow.fetch_sheets(workbook(url, token: token()))

      assert error.message =~ "The caller does not have permission"
      assert error.details.status == 403
    end

    test "the quota is its own reason, with the wait Google asked for" do
      body = ~s({"error":{"code":429,"message":"Quota exceeded for 'Read requests per minute'"}})
      url = TestServer.start([{429, body, "application/json", [{"retry-after", "30"}]}])

      assert {:error, %Error{reason: :rate_limited} = error} =
               Sheetshow.fetch_sheets(workbook(url, token: token()))

      assert error.message =~ "Quota exceeded"
      assert error.details.status == 429
      assert error.details.retry_after == 30
    end

    test "a quota refusal that names no wait leaves retry_after nil" do
      url = TestServer.start([{429, ~s({"error":{"message":"Quota exceeded"}})}])

      assert {:error, %Error{reason: :rate_limited} = error} =
               Sheetshow.fetch_sheets(workbook(url, token: token()))

      assert error.details.retry_after == nil
      assert error.details.body =~ "Quota exceeded"
    end

    test "without a token there is nothing to send" do
      assert {:error, %Error{reason: :no_token}} =
               Sheetshow.fetch_sheets(workbook("http://127.0.0.1:1"))
    end
  end

  describe "run" do
    test "sends the plan as one batch update" do
      url = TestServer.start([{200, ~s({"spreadsheetId":"1AbC","replies":[{}]})}])
      workbook = workbook(url, token: token()) |> Map.put(:sheets, %{"Costs" => 0})

      plan = Sheetshow.plan!(Sheetshow.row([1, 2], sheet: "Costs"))
      assert {:ok, ^workbook} = Sheetshow.run(plan, workbook)

      assert_receive {:request, request}
      assert request.method == :POST
      assert request.path == "/v4/spreadsheets/1AbC:batchUpdate"
      assert request.headers["content-type"] == "application/json"

      assert %{"requests" => [%{"updateCells" => update}]} = JSON.decode!(request.body)
      assert update["start"] == %{"sheetId" => 0, "rowIndex" => 0, "columnIndex" => 0}
    end

    test "the workbook comes back knowing the sheets the plan created" do
      replies = ~s({"replies":[{"addSheet":{"properties":{"sheetId":912,"title":"log"}}},{}]})
      url = TestServer.start([{200, replies}])
      workbook = workbook(url, token: token()) |> Map.put(:sheets, %{"Costs" => 0})

      plan =
        Sheetshow.plan!(Sheetshow.row([1], sheet: "log"), existing_sheets: ["Costs"])

      assert {:ok, workbook} = Sheetshow.run(plan, workbook)
      assert workbook.sheets == %{"Costs" => 0, "log" => 912}
    end

    test "a plan for a sheet the spreadsheet has not got never leaves the house" do
      workbook = workbook("http://127.0.0.1:1", token: token())
      plan = Sheetshow.plan!(Sheetshow.row([1], sheet: "nowhere"))

      assert {:error, %Error{reason: :unknown_sheet}} = Sheetshow.run(plan, workbook)
    end

    test "an empty plan asks Google nothing" do
      workbook = workbook("http://127.0.0.1:1", token: token())
      assert {:ok, ^workbook} = Sheetshow.run([], workbook)
    end
  end

  test "connect gets a token and the sheets, in that order", %{pem: pem} do
    url =
      TestServer.start([
        {200, ~s({"access_token":"ya29.new","expires_in":3599})},
        {200, ~s({"sheets":[{"properties":{"sheetId":0,"title":"Sheet1"}}]})}
      ])

    workbook = workbook(url, credentials: credentials(pem, url <> "/token"))

    assert {:ok, workbook} = Sheetshow.connect(workbook)
    assert workbook.ref.token.access_token == "ya29.new"
    assert workbook.sheets == %{"Sheet1" => 0}

    assert_receive {:request, %{path: "/token"}}
    assert_receive {:request, %{path: "/v4/spreadsheets/1AbC"}}
  end

  test "connect keeps a token that is still good", %{pem: pem} do
    url = TestServer.start([{200, ~s({"sheets":[]})}])
    workbook = workbook(url, credentials: credentials(pem, url <> "/token"), token: token())

    assert {:ok, workbook} = Sheetshow.connect(workbook)
    assert workbook.ref.token.access_token == "ya29.abc"

    assert_receive {:request, %{path: "/v4/spreadsheets/1AbC"}}
    refute_receive {:request, %{path: "/token"}}, 50
  end

  test "a server that is not there is a transport error, not a status" do
    workbook = workbook("http://127.0.0.1:1", token: token())

    assert {:error, %Error{reason: :transport} = error} = Sheetshow.fetch_sheets(workbook)
    assert error.message =~ "GET"
  end

  test "an answer that is not JSON says so" do
    url = TestServer.start([{200, "<html>not json</html>", "text/html"}])

    assert {:error, %Error{reason: :http} = error} =
             Sheetshow.fetch_sheets(workbook(url, token: token()))

    assert error.message =~ "not JSON"
  end

  test "the whole write path, from cells to one request" do
    url = TestServer.start([{200, ~s({"replies":[{},{}]})}])
    workbook = workbook(url, token: token()) |> Map.put(:sheets, %{"Costs" => 0})

    cells = [Cell.new("Costs!A1", "Rent"), Cell.new("Costs!C1", 1000)]
    assert {:ok, _client} = cells |> Sheetshow.plan!() |> Sheetshow.run(workbook)

    assert_receive {:request, request}
    assert %{"requests" => [one, two]} = JSON.decode!(request.body)
    assert one["updateCells"]["start"]["columnIndex"] == 0
    assert two["updateCells"]["start"]["columnIndex"] == 2
  end
end
