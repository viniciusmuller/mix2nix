Mix.install([
  {:req, "~> 0.2"}
])

defmodule Package do
  defstruct [:name, :version, :dependencies, :tar_hash, :kind, :rev]
end

defmodule Deps do
  def parse_from_lock(content) do
    {%{} = lock, _} = content |> Code.string_to_quoted!() |> Code.eval_quoted()
    Enum.map(lock, &parse/1)
  end

  defp parse({name, {:hex, pname, version, tar_hash, compilers, deps, hex} = old_format}) do
    parse({name, Tuple.append(old_format, nil)})
  end

  defp parse({name, {:hex, pname, version, tar_hash, compilers, deps, hex, _content_hash}}) do
    %Package{
      name: pname,
      kind: :hex,
      version: version,
      tar_hash: tar_hash,
      dependencies:
        Enum.map(deps, fn {name, version, _metadata} ->
          %Package{
            name: name,
            version: version
          }
        end)
    }
  end

  defp parse({name, {:git, url, rev, _list?}}) do
    url = String.trim_trailing(url, ".git") <> "/tarball/#{rev}"
    resp = Req.get!(url)
    hash = :binary.decode_unsigned(:crypto.hash(:sha256, resp.body))

    {_, lock} =
      untar(resp.body)
      |> Enum.find(fn {name, _} = entry -> String.contains?(name, "mix.lock") end)

    deps = parse_from_lock(lock)

    %Package{
      name: name,
      kind: :git,
      rev: rev,
      dependencies: deps,
      tar_hash: hash
    }
  end

  defp untar(body) do
    with {:ok, files} <-
           :erl_tar.extract(
             {:binary, body},
             [:memory, :compressed]
           ) do
      Map.new(files, fn {filename, content} ->
        {to_string(filename), content}
      end)
    end
  end
end

content = File.read!("/tmp/mix.lock")

Deps.parse_from_lock(content)
|> IO.inspect(label: :result, limit: :infinity)
