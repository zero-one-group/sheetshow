defmodule Sheetshow.FakeDAV do
  @moduledoc false
  # Enough of a WebDAV server to hold one file: GET, HEAD and PUT, a strong
  # entity tag that changes with the bytes, and `If-Match` / `If-None-Match`
  # honoured the way RFC 7232 says. It runs on `Sheetshow.TestServer`, so every
  # request still arrives in the test process.
  #
  # The canned-response tests prove what Sheetshow *sends*; this proves that a
  # store which answers like a server does lets a workbook live on it.

  alias Sheetshow.TestServer

  @doc "Starts a server holding nothing, and returns the file's URL."
  @spec start(String.t()) :: String.t()
  def start(name \\ "workbook.xlsx") do
    TestServer.start({&handle/2, nil}) <> "/" <> name
  end

  defp handle(%{method: :GET}, nil), do: {{404, "", "text/plain"}, nil}
  defp handle(%{method: :HEAD}, nil), do: {{404, "", "text/plain"}, nil}

  defp handle(%{method: :GET}, bytes) do
    {{200, bytes, "application/octet-stream", [{"etag", etag(bytes)}]}, bytes}
  end

  defp handle(%{method: :HEAD}, bytes) do
    {{200, "", "application/octet-stream", [{"etag", etag(bytes)}]}, bytes}
  end

  defp handle(%{method: :PUT, headers: headers, body: body}, bytes) do
    cond do
      headers["if-none-match"] == "*" and bytes != nil ->
        {{412, "", "text/plain"}, bytes}

      is_binary(headers["if-match"]) and (bytes == nil or headers["if-match"] != etag(bytes)) ->
        {{412, "", "text/plain"}, bytes}

      true ->
        {{if(bytes, do: 204, else: 201), "", "text/plain", [{"etag", etag(body)}]}, body}
    end
  end

  defp handle(_request, bytes), do: {{405, "", "text/plain"}, bytes}

  defp etag(bytes), do: ~s("#{:crypto.hash(:sha, bytes) |> Base.encode16(case: :lower)}")
end
