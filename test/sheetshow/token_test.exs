defmodule Sheetshow.TokenTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Token

  alias Sheetshow.{Error, Token}

  @now ~U[2026-09-12 08:00:00Z]

  describe "from_response" do
    test "turns expires_in into a moment" do
      response = %{"access_token" => "ya29.abc", "expires_in" => 3599, "token_type" => "Bearer"}

      assert {:ok, token} = Token.from_response(response, now: @now)
      assert token.access_token == "ya29.abc"
      assert token.expires_at == ~U[2026-09-12 08:59:59Z]
      assert token.type == "Bearer"
    end

    test "takes expires_in as a string too, as some endpoints send it" do
      assert {:ok, token} =
               Token.from_response(%{"access_token" => "a", "expires_in" => "60"}, now: @now)

      assert token.expires_at == ~U[2026-09-12 08:01:00Z]
    end

    test "scopes come from the answer, or from what was asked for" do
      granted = %{"access_token" => "a", "expires_in" => 60, "scope" => "one two"}
      assert {:ok, token} = Token.from_response(granted, now: @now)
      assert token.scopes == ["one", "two"]

      quiet = %{"access_token" => "a", "expires_in" => 60}
      assert {:ok, token} = Token.from_response(quiet, now: @now, scopes: ["one"])
      assert token.scopes == ["one"]
    end

    test "an OAuth error is an error, with what Google said" do
      response = %{"error" => "invalid_grant", "error_description" => "Invalid JWT Signature."}

      assert {:error, %Error{reason: :auth} = error} = Token.from_response(response)
      assert error.message =~ "invalid_grant"
      assert error.message =~ "Invalid JWT Signature."
      assert error.details.error == "invalid_grant"
    end

    test "anything else is an answer we do not understand" do
      for bad <- [
            %{},
            %{"access_token" => "a"},
            %{"expires_in" => 60},
            %{"access_token" => "a", "expires_in" => "soon"},
            %{"access_token" => "a", "expires_in" => nil}
          ] do
        assert {:error, %Error{reason: :invalid_token_response}} = Token.from_response(bad)
      end

      assert_raise Error, fn -> Token.from_response!(%{}) end
    end
  end

  describe "expired?" do
    test "is true from the moment it expires" do
      token = Token.new("a", ~U[2026-09-12 09:00:00Z])

      refute Token.expired?(token, ~U[2026-09-12 08:59:59Z])
      assert Token.expired?(token, ~U[2026-09-12 09:00:00Z])
      assert Token.expired?(token, ~U[2026-09-12 09:00:01Z])
    end

    test "a margin is a moment in the future" do
      token = Token.new("a", ~U[2026-09-12 09:00:00Z])
      in_a_minute = DateTime.add(~U[2026-09-12 08:59:30Z], 60, :second)

      refute Token.expired?(token, ~U[2026-09-12 08:59:30Z])
      assert Token.expired?(token, in_a_minute)
    end
  end

  test "inspecting a token keeps the token to itself" do
    shown = inspect(Token.new("ya29.secret", @now, scopes: ["one"]))

    assert shown =~ "one"
    refute shown =~ "ya29.secret"
  end
end
