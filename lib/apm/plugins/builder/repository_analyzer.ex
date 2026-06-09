defmodule Apm.Plugins.Builder.RepositoryAnalyzer do
  @moduledoc """
  Analyzes a repository source (GitHub URL, .git path, or local path) and extracts
  metadata useful for generating a CCEM APM plugin skeleton.

  Clones remote repositories to a temp directory, reads locally when a path is given.
  """

  require Logger

  @type analysis :: %{
          readme: String.t(),
          language: :elixir | :node | :python | :unknown,
          capabilities: [atom()],
          name_hint: String.t(),
          description_hint: String.t()
        }

  @doc """
  Analyze a source string (GitHub URL, .git path, or local filesystem path).

  Returns `{:ok, analysis_map}` on success, `{:error, reason}` on failure.
  """
  @spec analyze(String.t()) :: {:ok, analysis()} | {:error, term()}
  def analyze(source) when is_binary(source) do
    if remote_source?(source) do
      analyze_remote(source)
    else
      analyze_local(Path.expand(source))
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp remote_source?(source) do
    String.starts_with?(source, "https://github.com/") or String.ends_with?(source, ".git")
  end

  defp analyze_remote(url) do
    tmp_dir = System.tmp_dir!() <> "/builder_analyze_#{:erlang.unique_integer([:positive])}"

    try do
      case System.cmd("git", ["clone", "--depth=1", url, tmp_dir], stderr_to_stdout: true) do
        {_output, 0} ->
          result = extract_metadata(tmp_dir, name_hint_from_url(url))
          {:ok, result}

        {output, code} ->
          Logger.warning("[RepositoryAnalyzer] git clone failed (exit #{code}): #{output}")
          {:error, {:clone_failed, output}}
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp analyze_local(path) do
    if File.dir?(path) do
      {:ok, extract_metadata(path, Path.basename(path))}
    else
      {:error, {:not_a_directory, path}}
    end
  end

  defp extract_metadata(dir, name_hint) do
    readme = read_readme(dir)
    language = detect_language(dir)
    capabilities = detect_capabilities(dir)
    description_hint = extract_description_hint(readme)

    %{
      readme: readme,
      language: language,
      capabilities: capabilities,
      name_hint: name_hint,
      description_hint: description_hint
    }
  end

  defp read_readme(dir) do
    Enum.find_value(["README.md", "README"], fn filename ->
      path = Path.join(dir, filename)

      case File.read(path) do
        {:ok, contents} -> contents
        _ -> nil
      end
    end) || ""
  end

  defp detect_language(dir) do
    cond do
      File.exists?(Path.join(dir, "mix.exs")) -> :elixir
      File.exists?(Path.join(dir, "package.json")) -> :node
      File.exists?(Path.join(dir, "requirements.txt")) -> :python
      true -> :unknown
    end
  end

  defp detect_capabilities(dir) do
    capabilities = []

    capabilities =
      if File.dir?(Path.join(dir, ".claude/skills")),
        do: [:skills | capabilities],
        else: capabilities

    capabilities =
      if File.exists?(Path.join(dir, ".claude/settings.json")) or
           File.exists?(Path.join(dir, "mcp.json")),
         do: [:mcp | capabilities],
         else: capabilities

    capabilities =
      if File.dir?(Path.join(dir, ".claude/commands")),
        do: [:commands | capabilities],
        else: capabilities

    Enum.reverse(capabilities)
  end

  defp extract_description_hint(""), do: ""

  defp extract_description_hint(readme) do
    readme
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
    |> Enum.find(&(String.trim(&1) != ""))
    |> then(&(&1 || ""))
    |> String.trim()
  end

  defp name_hint_from_url(url) do
    url
    |> String.trim_trailing(".git")
    |> String.split("/")
    |> List.last()
    |> then(&(&1 || "plugin"))
  end
end
