defmodule Sheetshow.Google.Backend do
  @moduledoc false
  # The impure half of the Google backend: the token exchange, the metadata
  # fetch and the batch update. The docs live on the `Sheetshow` functions that
  # call these.

  @behaviour Sheetshow.Backend

  alias Sheetshow.{
    Client,
    Error,
    Google,
    HTTP,
    Op,
    Range,
    ServiceAccount,
    Token,
    UserAccount,
    Workbook
  }

  @form "application/x-www-form-urlencoded"
  @json "application/json"

  # Google applies a batch whole or not at all, works formulas out, keeps
  # styles and dimensions, and resolves appendCells server-side. What it has no
  # answer for is a conditional write: batchUpdate takes no ETag and no
  # revision precondition, so the read-to-write gap cannot be closed.
  @impl true
  def capabilities(_workbook) do
    %{
      atomic_batch: true,
      conditional_write: false,
      dimensions: true,
      evaluates_formulas: true,
      server_side_append: true,
      styles: true
    }
  end

  @impl true
  def connect(%Workbook{ref: %Client{} = client} = workbook) do
    ready = if Client.ready?(client), do: {:ok, workbook}, else: authenticate(workbook)

    with {:ok, workbook} <- ready, do: fetch_sheets(workbook)
  end

  @impl true
  def authenticate(%Workbook{ref: %Client{credentials: nil}}) do
    {:error,
     Error.new(
       :no_credentials,
       "the workbook has no credentials: build it with credentials: Sheetshow.ServiceAccount.from_file!(path)"
     )}
  end

  def authenticate(
        %Workbook{ref: %Client{credentials: %ServiceAccount{} = account} = client} = workbook
      ) do
    request = ServiceAccount.token_request(account, scopes: client.scopes)

    with {:ok, json} <- post_form(request, client.http),
         {:ok, token} <- Token.from_response(json, scopes: client.scopes) do
      {:ok, Workbook.put_ref(workbook, %{client | token: token})}
    end
  end

  # A refresh, rather than a signature. Google may hand back a new refresh token
  # instead of the one that was sent; dropping it would leave the app holding a
  # credential that has quietly stopped working, so it goes back on the client.
  def authenticate(
        %Workbook{ref: %Client{credentials: %UserAccount{} = account} = client} = workbook
      ) do
    with {:ok, request} <- UserAccount.token_request(account),
         {:ok, json} <- post_form(request, client.http),
         {:ok, token} <- Token.from_response(json, scopes: client.scopes) do
      {:ok,
       Workbook.put_ref(workbook, %{client | token: token, credentials: rotated(account, json)})}
    end
  end

  # The one-time trade of an authorization code for a refresh token. The access
  # token in the same answer is not kept: see `Sheetshow.OAuth.authorize/3`.
  def exchange(request, %UserAccount{} = account, http \\ []) do
    with {:ok, json} <- post_form(request, http) do
      case json do
        %{"refresh_token" => refresh_token} when is_binary(refresh_token) ->
          {:ok, %{account | refresh_token: refresh_token}}

        %{"error" => _} ->
          with {:error, _} = error <- Token.from_response(json), do: error

        _other ->
          {:error,
           Error.new(
             :no_refresh_token,
             "the token endpoint answered without a refresh token, which happens when the app " <>
               "has been approved before: ask again with prompt: \"consent\"",
             response: Map.drop(json, ["access_token", "id_token"])
           )}
      end
    end
  end

  defp post_form(%{url: url, form: form}, http) do
    headers = [{"content-type", @form}]

    with {:ok, response} <- HTTP.request(:post, url, headers, URI.encode_query(form), http) do
      json(response, url)
    end
  end

  defp rotated(%UserAccount{} = account, json) do
    case json do
      %{"refresh_token" => refresh_token} when is_binary(refresh_token) ->
        %{account | refresh_token: refresh_token}

      _kept ->
        account
    end
  end

  @impl true
  def fetch_sheets(%Workbook{ref: %Client{} = client} = workbook) do
    url = Client.url(client, "", fields: "sheets.properties(sheetId,title)")

    with {:ok, json} <- fetch_json(client, url) do
      {:ok, Workbook.put_sheets(workbook, titles(Map.get(json, "sheets", [])))}
    end
  end

  @impl true
  def run([], %Workbook{} = workbook), do: {:ok, workbook}

  def run(plan, %Workbook{ref: %Client{} = client} = workbook) when is_list(plan) do
    url = Client.url(client, ":batchUpdate")

    with {:ok, body} <- Google.encode(plan, workbook.sheets),
         {:ok, headers} <- authorization(client),
         {:ok, response} <-
           HTTP.request(
             :post,
             url,
             [{"content-type", @json} | headers],
             JSON.encode!(body),
             client.http
           ),
         {:ok, json} <- ok_json(response, url) do
      {:ok, Workbook.put_sheets(workbook, remember(plan, json, workbook.sheets))}
    end
  end

  # `quote_sheet: true` on every read: a whole-sheet name is quoted so Google
  # reads it as the tab, not a same-named range that would take precedence.
  @impl true
  def read_cells(%Range{} = range, %Workbook{} = workbook) do
    with {:ok, json} <- get(Range.to_a1(range, quote_sheet: true), workbook),
         do: {:ok, Google.decode(json)}
  end

  @impl true
  def read_rows(%Range{} = range, %Workbook{} = workbook) do
    with {:ok, json} <- get_values(Range.to_a1(range, quote_sheet: true), workbook),
         do: {:ok, Google.decode_values(json)}
  end

  @impl true
  def read_rows_batch(ranges, %Workbook{} = workbook) when is_list(ranges) do
    with {:ok, json} <-
           get_values_batch(Enum.map(ranges, &Range.to_a1(&1, quote_sheet: true)), workbook),
         do: {:ok, Google.decode_value_ranges(json)}
  end

  # The three reads before they become cells or rows, which is what the
  # integration run records as fixtures.
  def get(a1, %Workbook{ref: %Client{} = client}) when is_binary(a1) do
    fetch_json(client, Client.url(client, "", ranges: a1, fields: Google.read_fields()))
  end

  def get_values(a1, %Workbook{ref: %Client{} = client}) when is_binary(a1) do
    fetch_json(client, Client.url(client, "/values/" <> escape(a1), Google.value_options()))
  end

  # Several ranges in one request. Here they are query parameters rather than a
  # path segment, so the ordinary encoding is enough, and Google answers in the
  # order they were asked for.
  def get_values_batch(a1s, %Workbook{ref: %Client{} = client}) when is_list(a1s) do
    query = Enum.map(a1s, &{"ranges", &1}) ++ Google.value_options()
    fetch_json(client, Client.url(client, "/values:batchGet", query))
  end

  defp fetch_json(%Client{} = client, url) do
    with {:ok, headers} <- authorization(client),
         {:ok, response} <- HTTP.request(:get, url, headers, nil, client.http) do
      ok_json(response, url)
    end
  end

  # A range is a path segment on the values endpoint, not a query parameter, and
  # a sheet name can hold anything a person types. The characters A1 notation
  # itself is made of are left as they are, so the URL reads like the one in
  # Google's own documentation; a space, a slash, a "?" or a "#" would break the
  # path or the URL, and those are escaped.
  @literal ~c"!:'$"

  defp escape(a1) do
    URI.encode(a1, &(URI.char_unreserved?(&1) or &1 in @literal))
  end

  defp authorization(%Client{token: nil}) do
    {:error,
     Error.new(
       :no_token,
       "the workbook has no token: Sheetshow.connect/1 or Sheetshow.authenticate/1 gets one"
     )}
  end

  defp authorization(%Client{token: token}) do
    {:ok, [{"authorization", Token.authorization(token)}]}
  end

  # Every sheet the spreadsheet has, by title.
  defp titles(sheets) do
    for %{"properties" => %{"sheetId" => id, "title" => title}} <- sheets, into: %{} do
      {title, id}
    end
  end

  # The plan's adds and deletes applied to the remembered sheets in the order
  # the caller gave them, so a batch that adds a tab and then deletes it leaves
  # the workbook as it found it. Dropping every delete first and merging every
  # add after (an unordered `Map.drop |> Map.merge`) forgot the order and left
  # the deleted tab behind. An added tab's id comes from its reply; a delete
  # answers with nothing, so its title is simply taken back out.
  defp remember(plan, json, sheets) do
    ids = added(json)

    Enum.reduce(plan, sheets, fn
      %Op.AddSheet{title: title}, acc -> Map.put(acc, title, Map.get(ids, title))
      %Op.DeleteSheet{title: title}, acc -> Map.delete(acc, title)
      _op, acc -> acc
    end)
  end

  # A batch update answers an AddSheet with the sheet it made, which is how a
  # workbook learns the id of a tab it has just created.
  defp added(json) do
    for %{"addSheet" => %{"properties" => %{"sheetId" => id, "title" => title}}} <-
          Map.get(json, "replies", []),
        into: %{} do
      {title, id}
    end
  end

  defp ok_json(%{status: status} = response, url) when status in 200..299 do
    json(response, url)
  end

  # The quota refusal is the one worth telling apart from every other: nothing
  # about the request is wrong and the same request will work in a minute,
  # which is the whole difference between backing off and giving up. Deciding
  # whether and when to try again is still the app's business, and this is what
  # it needs to write that without reading error messages.
  defp ok_json(%{status: 429 = status, body: body, headers: headers}, url) do
    {:error,
     Error.new(:rate_limited, "#{url} answered #{status}: #{explain(body)}",
       status: status,
       retry_after: retry_after(headers),
       body: body,
       url: url
     )}
  end

  defp ok_json(%{status: status, body: body}, url) do
    {:error,
     Error.new(:http, "#{url} answered #{status}: #{explain(body)}",
       status: status,
       body: body,
       url: url
     )}
  end

  defp json(%{body: body}, url) do
    case JSON.decode(body) do
      {:ok, json} when is_map(json) ->
        {:ok, json}

      _ ->
        {:error,
         Error.new(:http, "#{url} answered with something that is not JSON", body: body, url: url)}
    end
  end

  # Seconds, when the answer names them, and nil when it does not, which is
  # most of the time. The header's other legal form is an HTTP date; a value
  # that is not a plain number is left as nil rather than guessed at, and the
  # answer itself is in `details.body` either way.
  defp retry_after(headers) do
    with {_name, value} <- Enum.find(headers, &(String.downcase(elem(&1, 0)) == "retry-after")),
         {seconds, ""} <- Integer.parse(String.trim(value)) do
      seconds
    else
      _ -> nil
    end
  end

  # Google puts the reason in the body; a bare status code is no help at all.
  defp explain(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      {:ok, %{"error" => error}} when is_binary(error) -> error
      _ -> String.slice(body, 0, 200)
    end
  end
end
