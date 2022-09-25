Mix.install([
  {:req, "~> 0.2"}
])

defmodule Package do
  defstruct [
    :name,
    :version,
    :dependencies,
    :sha256,
    :kind,
    :rev,
    :git_url,
    :metadata
  ]
end

defmodule Deps do
  @type import_structure :: %{atom() => %Package{}}

  @spec build_import_structure(String.t()) :: import_structure()
  def build_import_structure(mix_lock) do
    deps = parse_from_lock(mix_lock)

    deps_map = Enum.reduce(deps, %{}, &dependency_map/2)

    # deps
    # |> Enum.map(&flatten_deps/1)
    # |> Map.new(fn %Package{} = pkg -> {pkg.name, pkg} end)
    # |> IO.inspect(label: :result, limit: :infinity)

    deps_map
  end

  defp dependency_map(%Package{name: name, dependencies: :unfetched} = pkg, acc) do
    Map.put(acc, name, pkg)
  end

  defp dependency_map(%Package{name: name} = pkg, acc) do
    Enum.reduce(pkg.dependencies, Map.put(acc, name, pkg), &dependency_map/2)
  end

  defp parse_from_lock(mix_lock) do
    {%{} = lock, _} = mix_lock |> Code.string_to_quoted!() |> Code.eval_quoted()
    Enum.map(lock, &parse/1)
  end

  # old versions of mix.lock entries didn't had the last hash
  defp parse({name, {:hex, _pname, _version, _tar_hash, _compilers, _deps, _hex} = old_format}) do
    parse({name, Tuple.append(old_format, nil)})
  end

  defp parse({_name, {:hex, pname, version, tar_hash, _compilers, deps, _hex, _content_hash}}) do
    %Package{
      name: pname,
      kind: :hex,
      version: version,
      sha256: tar_hash,
      dependencies:
        Enum.map(deps, fn {name, version, metadata} ->
          %Package{
            dependencies: :unfetched,
            kind: :hex,
            name: name,
            version: version,
            metadata: metadata
          }
        end)
    }
  end

  defp parse({name, {:git, url, rev, _list?}}) do
    tarball_url = String.trim_trailing(url, ".git") <> "/tarball/#{rev}"
    resp = Req.get!(tarball_url)
    hash = Base.encode16(:crypto.hash(:sha256, resp.body), case: :lower)

    {_, lock} =
      untar(resp.body)
      |> Enum.find(fn {name, _} -> String.contains?(name, "mix.lock") end)

    deps = parse_from_lock(lock)

    %Package{
      name: name,
      kind: :git,
      rev: rev,
      dependencies: deps,
      sha256: hash,
      git_url: url
    }
  end

  defp untar(body) do
    {:ok, files} = :erl_tar.extract({:binary, body}, [:memory, :compressed])

    Map.new(files, fn {filename, content} ->
      {to_string(filename), content}
    end)
  end
end

defmodule CodeGenerator do
  @spec generate(Deps.import_structure()) :: String.t()
  def generate(import_structure) do
    derivations =
      import_structure
      |> Map.values()
      |> Enum.map(&build_package/1)

    "
{ lib, beamPackages, overrides ? (x: y: {}) }:

let
	buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
	buildMix = lib.makeOverridable beamPackages.buildMix;
	buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

	self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    #{derivations}
  };
in self
    "
  end

  defp build_package(%Package{
         kind: :hex,
         version: version,
         name: name,
         sha256: sha,
         dependencies: deps
       }) do
    name = Atom.to_string(name)

    pkg_deps =
      case deps do
        :unfetched ->
          ""

        _ ->
          Stream.map(deps, &Map.get(&1, :name))
          |> Stream.map(&Atom.to_string/1)
          |> Enum.join(" ")
      end

    ~s(
    #{name} = buildMix rec {
			name = "#{name}";
			version = "#{version}";
			src = fetchHex {
				pkg = "${name}";
        # TODO: Handle versions correctly
				version = "${version}";
				sha256 = "#{sha}";
			};
			beamDeps = [ #{pkg_deps} ];
		};)
  end

  defp build_package(%Package{
         kind: :git,
         dependencies: deps,
         name: name,
         rev: rev,
         sha256: sha,
         git_url: url
       }) do
    name = Atom.to_string(name)

    deps =
      Stream.map(deps, &Map.get(&1, :name))
      |> Stream.map(&Atom.to_string/1)
      |> Enum.join(" ")

    ~s(#{name} = buildMix rec {
			name = "#{name}";
			version = "#{rev}";

      # TODO: fetchgit not working
			src = lib.fetchgit {
        url = "#{url}";
        rev = "#{rev}";
				sha256 = "#{sha}";
			};

			beamDeps = [ #{deps} ];
		};)
  end
end

content = File.read!("/tmp/mix.lock")

# TODO: fetch unspecified package dependencies from hex,
# using local cache of versions
generated =
  Deps.build_import_structure(content)
  |> CodeGenerator.generate()

File.write!("/tmp/mix.nix", generated)
