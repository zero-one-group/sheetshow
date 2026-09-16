defmodule Sheetshow.ServiceAccountTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.ServiceAccount

  alias Sheetshow.{Error, ServiceAccount}

  setup_all do
    key = :public_key.generate_key({:rsa, 2048, 65_537})

    %{
      pkcs1: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)]),
      pkcs8: :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)]),
      public: {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    }
  end

  defp json(fields) do
    %{
      "type" => "service_account",
      "client_email" => "tests@example.iam.gserviceaccount.com",
      "project_id" => "example",
      "private_key_id" => "abc123"
    }
    |> Map.merge(fields)
    |> JSON.encode!()
  end

  defp account(pem, fields \\ %{}) do
    ServiceAccount.from_json!(json(Map.put(fields, "private_key", pem)))
  end

  defp parts(assertion) do
    [header, claims, signature] = String.split(assertion, ".")

    %{
      header: decode(header),
      claims: decode(claims),
      signature: Base.url_decode64!(signature, padding: false),
      payload: header <> "." <> claims
    }
  end

  defp decode(segment), do: segment |> Base.url_decode64!(padding: false) |> JSON.decode!()

  describe "from_json" do
    test "reads what the key file holds", %{pkcs1: pem} do
      account = account(pem)

      assert account.client_email == "tests@example.iam.gserviceaccount.com"
      assert account.project_id == "example"
      assert account.private_key_id == "abc123"
      assert account.token_uri == "https://oauth2.googleapis.com/token"
    end

    test "a file that names its own token endpoint keeps it", %{pkcs1: pem} do
      account = account(pem, %{"token_uri" => "https://example.test/token"})
      assert account.token_uri == "https://example.test/token"
    end

    test "either PEM layout of an RSA key will do", %{pkcs1: pkcs1, pkcs8: pkcs8, public: public} do
      for pem <- [pkcs1, pkcs8] do
        %{payload: payload, signature: signature} = parts(ServiceAccount.assertion(account(pem)))
        assert :public_key.verify(payload, :sha256, signature, public)
      end
    end

    test "a credential it could not sign with is refused now, not at the first request", %{
      pkcs1: pem
    } do
      for bad <- [
            ~s({"type": "authorized_user", "refresh_token": "x"}),
            ~s({"client_email": "a@b.test"}),
            json(%{"private_key" => pem, "client_email" => ""}),
            json(%{}),
            json(%{"private_key" => "not a pem"}),
            json(%{
              "private_key" =>
                "-----BEGIN RSA PRIVATE KEY-----\nnope\n-----END RSA PRIVATE KEY-----\n"
            }),
            "{not json",
            "[]"
          ] do
        assert {:error, %Error{reason: :invalid_credentials}} = ServiceAccount.from_json(bad)
      end

      assert_raise Error, fn -> ServiceAccount.from_json!(~s({"type": "authorized_user"})) end
    end

    test "the message says what kind of credential it got" do
      {:error, error} = ServiceAccount.from_json(~s({"type": "authorized_user"}))

      assert error.message =~ "authorized_user"
      assert error.details == %{type: "authorized_user"}
    end
  end

  describe "assertion" do
    test "is a JWT the account's key signed", %{pkcs1: pem, public: public} do
      %{header: header, claims: claims, payload: payload, signature: signature} =
        parts(ServiceAccount.assertion(account(pem)))

      assert header == %{"alg" => "RS256", "typ" => "JWT"}
      assert claims["iss"] == "tests@example.iam.gserviceaccount.com"
      assert claims["aud"] == "https://oauth2.googleapis.com/token"
      assert claims["scope"] == "https://www.googleapis.com/auth/spreadsheets"
      assert :public_key.verify(payload, :sha256, signature, public)
    end

    test "asks for the scopes given, and lasts as long as asked", %{pkcs1: pem} do
      assertion =
        ServiceAccount.assertion(account(pem),
          scopes: ["https://example.test/a", "https://example.test/b"],
          lifetime: 60,
          now: ~U[2026-09-12 08:00:00Z]
        )

      assert %{claims: claims} = parts(assertion)
      assert claims["scope"] == "https://example.test/a https://example.test/b"
      assert claims["iat"] == 1_789_200_000
      assert claims["exp"] == claims["iat"] + 60
    end

    test "a signature is over the header and claims as sent", %{pkcs1: pem, public: public} do
      %{payload: payload, signature: signature} = parts(ServiceAccount.assertion(account(pem)))

      refute :public_key.verify(payload <> "x", :sha256, signature, public)
    end
  end

  test "token_request is the post, as data", %{pkcs1: pem} do
    request = ServiceAccount.token_request(account(pem), now: ~U[2026-09-12 08:00:00Z])

    assert request.url == "https://oauth2.googleapis.com/token"
    assert request.form.grant_type == "urn:ietf:params:oauth:grant-type:jwt-bearer"
    assert %{claims: %{"iat" => 1_789_200_000}} = parts(request.form.assertion)
  end

  test "inspecting an account keeps the key to itself", %{pkcs1: pem} do
    shown = inspect(account(pem))

    assert shown =~ "tests@example.iam.gserviceaccount.com"
    refute shown =~ "PRIVATE KEY"
  end

  @tag :tmp_dir
  test "from_file reads the path you give it", %{pkcs1: pem, tmp_dir: dir} do
    path = Path.join(dir, "sa.json")
    File.write!(path, json(%{"private_key" => pem}))

    assert {:ok, account} = ServiceAccount.from_file(path)
    assert account.client_email == "tests@example.iam.gserviceaccount.com"

    assert {:error, %Error{reason: :invalid_credentials, details: %{path: _}}} =
             ServiceAccount.from_file(Path.join(dir, "nope.json"))

    assert_raise Error, fn -> ServiceAccount.from_file!(Path.join(dir, "nope.json")) end
  end
end
