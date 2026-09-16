ExUnit.start(exclude: [:integration])

cond do
  Sheetshow.Integration.configured?() ->
    # The first HTTPS connection loads the system trust store, which on macOS
    # means asking the keychain. Doing it here, once, keeps four modules from
    # each waiting on it inside a ten-second connect timeout.
    _ = :public_key.cacerts_get()
    {:ok, _} = Sheetshow.Integration.start()

    # Every tab the run made, taken away in one request rather than two per
    # test. Nothing happens here when no integration test ran: the agent is
    # still holding the nil it started with.
    ExUnit.after_suite(fn _results -> Sheetshow.Integration.clean_up() end)

  :integration in (ExUnit.configuration()[:include] || []) ->
    IO.puts("""

    Integration tests skipped: set SHEETSHOW_TEST_CREDENTIALS (a path to the
    service-account JSON, or the JSON itself) and SHEETSHOW_TEST_SPREADSHEET_ID.
    """)

  true ->
    :ok
end
