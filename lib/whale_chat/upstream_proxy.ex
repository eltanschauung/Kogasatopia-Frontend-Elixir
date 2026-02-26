defmodule WhaleChat.UpstreamProxy do
  @moduledoc false

  def fetch_html(url) when is_binary(url) do
    case System.cmd("curl", ["-fsSL", url], stderr_to_stdout: true) do
      {body, 0} -> {:ok, body}
      {_output, _code} -> :error
    end
  end
end

