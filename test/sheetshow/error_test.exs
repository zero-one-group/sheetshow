defmodule Sheetshow.ErrorTest do
  use ExUnit.Case, async: true
  doctest Sheetshow.Error

  alias Sheetshow.Error

  test "new/3 accepts details as a keyword list or a map, and defaults to none" do
    assert %Error{details: %{key: :bolt}} = Error.new(:invalid_style, "x", key: :bolt)
    assert %Error{details: %{status: 429}} = Error.new(:http, "x", %{status: 429})
    assert %Error{details: %{}} = Error.new(:http, "x")
  end

  test "is an exception whose message is the message field" do
    assert_raise Error, "boom", fn -> raise Error.new(:boom, "boom") end
  end
end
