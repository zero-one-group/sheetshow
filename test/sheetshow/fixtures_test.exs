defmodule Sheetshow.FixturesTest do
  # Not async: it turns the recording flag on and off.
  use ExUnit.Case, async: false

  alias Sheetshow.Fixtures

  @id "1AbCdEfGhIjKlMnOpQrStUvWxYz"
  @flag "SHEETSHOW_RECORD_FIXTURES"

  setup do
    was = System.get_env(@flag)

    on_exit(fn ->
      if was, do: System.put_env(@flag, was), else: System.delete_env(@flag)
    end)

    :ok
  end

  test "the spreadsheet id becomes a placeholder, wherever it hides" do
    answer = %{
      "spreadsheetId" => @id,
      "spreadsheetUrl" => "https://docs.google.com/spreadsheets/d/#{@id}/edit",
      "sheets" => [%{"properties" => %{"title" => "Costs"}}]
    }

    assert Fixtures.scrub(answer, @id) == %{
             "spreadsheetId" => "SPREADSHEET_ID",
             "spreadsheetUrl" => "https://docs.google.com/spreadsheets/d/SPREADSHEET_ID/edit",
             "sheets" => [%{"properties" => %{"title" => "Costs"}}]
           }
  end

  test "the keys that name people are dropped, at any depth" do
    answer = %{
      "owners" => [%{"emailAddress" => "user@example.com"}],
      "sheets" => [%{"user" => %{"emailAddress" => "someone@example.com"}, "keep" => 1}]
    }

    assert Fixtures.scrub(answer, @id) == %{"sheets" => [%{"keep" => 1}]}
  end

  test "an email that survived in some other field is blanked anyway" do
    answer = %{"note" => "ask real.person@example.org about this", "values" => ["a@b.co.uk"]}

    assert Fixtures.scrub(answer, @id) == %{
             "note" => "ask someone@example.test about this",
             "values" => ["someone@example.test"]
           }
  end

  test "a test tab's number goes, so re-recording shows no change that is not one" do
    answer = %{
      "range" => "'sheetshow 2057'!A1:Z1000",
      "properties" => %{"title" => "sheetshow 1859"}
    }

    assert Fixtures.scrub(answer, @id) == %{
             "range" => "'sheetshow N'!A1:Z1000",
             "properties" => %{"title" => "sheetshow N"}
           }
  end

  test "everything else is left exactly as it was" do
    answer = %{"n" => 42, "f" => 2.5, "b" => true, "nil" => nil, "list" => [1, "two"]}

    assert Fixtures.scrub(answer, @id) == answer
  end

  test "nothing is recorded until recording is asked for, and then only scrubbed" do
    path = Path.join(["test", "fixtures", "recording_test.json"])
    on_exit(fn -> File.rm(path) end)

    answer = %{
      "spreadsheetId" => @id,
      "owners" => [%{"emailAddress" => "user@example.com"}],
      "keep" => 1
    }

    System.delete_env(@flag)
    assert Fixtures.record("recording_test", answer, @id) == :ok
    refute File.exists?(path)
    assert Fixtures.read("recording_test") == nil

    System.put_env(@flag, "1")
    assert Fixtures.record("recording_test", answer, @id) == :ok
    assert Fixtures.read("recording_test") == %{"spreadsheetId" => "SPREADSHEET_ID", "keep" => 1}
  end
end
