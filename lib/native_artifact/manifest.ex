defmodule NativeArtifact.Manifest do
  @moduledoc """
  Bounded, fail-closed validation of pinned Manifest v1 metadata.

  `decode/2` rejects duplicate JSON object keys before validating the schema and
  cross-references. `validate/2` accepts already-decoded string-keyed JSON data.
  Both return `%Manifest{data: original_data}` without creating atoms from input.
  Validation performs no I/O and does not prove that an archive exists, its bytes
  match, or its native code is compatible with a running system.

  Options are positive integer limits: `:max_manifest_bytes` (4 MiB),
  `:max_depth` (64 container levels), `:max_nodes` (100,000 values/object keys),
  `:max_artifacts` (128), `:max_files` (4,096 across the manifest),
  `:max_archive_bytes` (256 MiB per archive), and `:max_unpacked_bytes`
  (1 GiB across the manifest). For `validate/2`, the byte limit applies to the
  compact JSON representation; `decode/2` also bounds the original input bytes.
  """

  alias NativeArtifact.Error
  alias NativeArtifact.Manifest.JSON, as: ManifestJSON

  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: %{required(String.t()) => term()}}

  @defaults %{
    max_manifest_bytes: 4 * 1024 * 1024,
    max_depth: 64,
    max_nodes: 100_000,
    max_artifacts: 128,
    max_files: 4_096,
    max_archive_bytes: 256 * 1024 * 1024,
    max_unpacked_bytes: 1024 * 1024 * 1024
  }

  @sha256 ~r/\A[0-9a-f]{64}\z/
  @version ~r/\A[0-9]+(?:\.[0-9]+){1,3}\z/
  @https ~r/\Ahttps:\/\/[^\/?#@\s]+(?:\/[^?#\s]*)?\z/u
  @module ~r/\A(?:Elixir\.[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*|[a-z][A-Za-z0-9_@]*)\z/

  @doc "Decodes bounded UTF-8 JSON, rejecting duplicate object keys and invalid v1 metadata."
  @spec decode(binary(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def decode(json, opts \\ []) do
    with {:ok, limits} <- limits(opts),
         {:ok, data} <- ManifestJSON.decode(json, limits),
         :ok <- validate_data(data, limits) do
      {:ok, %__MODULE__{data: data}}
    end
  end

  @doc "Validates string-keyed JSON data without normalizing it or performing I/O."
  @spec validate(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def validate(data, opts \\ []) do
    with {:ok, limits} <- limits(opts),
         :ok <- validate_data(data, limits) do
      {:ok, %__MODULE__{data: data}}
    end
  end

  defp validate_data(data, limits) do
    with :ok <- ManifestJSON.validate(data, limits),
         :ok <- root(data, limits),
         do: semantics(data, limits)
  end

  defp root(data, limits) do
    with :ok <-
           object(
             data,
             ~w(schema_version package package_version required_features artifacts),
             ~w(extensions),
             []
           ),
         :ok <- constant(data["schema_version"], 1, ["schema_version"], :unsupported_schema),
         :ok <- text(data["package"], ["package"], ~r/\A[a-z][a-z0-9_]*\z/),
         :ok <-
           text(
             data["package_version"],
             ["package_version"],
             ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/
           ),
         :ok <- required_features(data["required_features"]),
         :ok <- list(data["artifacts"], ["artifacts"], &artifact(&1, &2, limits), 1),
         :ok <- quota(length(data["artifacts"]), :max_artifacts, limits, ["artifacts"]),
         do: optional_extensions(data, [])
  end

  defp artifact(value, path, limits) do
    required =
      ~w(id kind native_version build_revision target compatibility binding sources archive entrypoint private_libraries files licenses provenance)

    with :ok <- object(value, required, ~w(extensions), path),
         :ok <- text(value["id"], path ++ ["id"], ~r/\A[a-z][a-z0-9_.-]*\z/),
         :ok <- constant(value["kind"], "nif", path ++ ["kind"], :unsupported_artifact_kind),
         :ok <- text(value["native_version"], path ++ ["native_version"]),
         :ok <- integer(value["build_revision"], 1, path ++ ["build_revision"]),
         :ok <- target(value["target"], path ++ ["target"]),
         :ok <- compatibility(value["compatibility"], path ++ ["compatibility"]),
         :ok <- platform_minimums(value, path),
         :ok <- binding(value["binding"], path ++ ["binding"]),
         :ok <- list(value["sources"], path ++ ["sources"], &source/2, 1, true),
         :ok <- archive(value["archive"], path ++ ["archive"], limits),
         :ok <- relative_path(value["entrypoint"], path ++ ["entrypoint"]),
         :ok <-
           list(
             value["private_libraries"],
             path ++ ["private_libraries"],
             &relative_path/2,
             0,
             true
           ),
         :ok <- list(value["files"], path ++ ["files"], &file/2, 1, true),
         :ok <- list(value["licenses"], path ++ ["licenses"], &license/2, 1, true),
         :ok <- provenance(value["provenance"], path ++ ["provenance"]),
         do: optional_extensions(value, path)
  end

  defp target(value, path) do
    required = ~w(os arch libc object_format pointer_width endianness cpu_baseline)

    with :ok <- object(value, required, [], path),
         :ok <- member(value["os"], ~w(linux macos), path ++ ["os"]),
         :ok <- member(value["arch"], ~w(x86_64 aarch64), path ++ ["arch"]),
         :ok <- member(value["libc"], ~w(glibc musl none), path ++ ["libc"]),
         :ok <- member(value["object_format"], ~w(elf mach-o), path ++ ["object_format"]),
         :ok <- constant(value["pointer_width"], 64, path ++ ["pointer_width"]),
         :ok <- constant(value["endianness"], "little", path ++ ["endianness"]),
         :ok <- member(value["cpu_baseline"], ~w(x86-64 armv8-a), path ++ ["cpu_baseline"]),
         :ok <- target_os(value, path) do
      baseline = if value["arch"] == "x86_64", do: "x86-64", else: "armv8-a"
      constant(value["cpu_baseline"], baseline, path ++ ["cpu_baseline"])
    end
  end

  defp target_os(%{"os" => "linux"} = value, path) do
    with :ok <- member(value["libc"], ~w(glibc musl), path ++ ["libc"]),
         do: constant(value["object_format"], "elf", path ++ ["object_format"])
  end

  defp target_os(value, path) do
    with :ok <- constant(value["libc"], "none", path ++ ["libc"]),
         do: constant(value["object_format"], "mach-o", path ++ ["object_format"])
  end

  defp compatibility(value, path) do
    required = ~w(nif min_erts min_os_version min_libc_version vm_variant system_libraries)

    with :ok <- object(value, required, [], path),
         :ok <- nif(value["nif"], path ++ ["nif"]),
         :ok <- text(value["min_erts"], path ++ ["min_erts"], @version),
         :ok <- nullable_text(value["min_os_version"], path ++ ["min_os_version"], @version),
         :ok <- nullable_text(value["min_libc_version"], path ++ ["min_libc_version"], @version),
         :ok <- constant(value["vm_variant"], "beam", path ++ ["vm_variant"]),
         do:
           list(
             value["system_libraries"],
             path ++ ["system_libraries"],
             &system_library/2,
             0,
             true
           )
  end

  defp platform_minimums(%{"target" => %{"os" => "linux"}} = value, path),
    do:
      text(
        value["compatibility"]["min_libc_version"],
        path ++ ["compatibility", "min_libc_version"],
        @version
      )

  defp platform_minimums(value, path) do
    with :ok <-
           constant(
             value["compatibility"]["min_libc_version"],
             nil,
             path ++ ["compatibility", "min_libc_version"]
           ),
         do:
           text(
             value["compatibility"]["min_os_version"],
             path ++ ["compatibility", "min_os_version"],
             @version
           )
  end

  defp nif(value, path) do
    with :ok <- object(value, ~w(major minor), [], path),
         :ok <- integer(value["major"], 1, path ++ ["major"]),
         do: integer(value["minor"], 0, path ++ ["minor"])
  end

  defp system_library(value, path) do
    with :ok <- object(value, ~w(name required_symbols symbol_versions), [], path),
         :ok <- text(value["name"], path ++ ["name"]),
         :ok <- list(value["required_symbols"], path ++ ["required_symbols"], &text/2, 0, true),
         do: list(value["symbol_versions"], path ++ ["symbol_versions"], &text/2, 0, true)
  end

  defp binding(value, path) do
    with :ok <- object(value, ~w(module interface_version fingerprint), [], path),
         :ok <- text(value["module"], path ++ ["module"], @module),
         :ok <- text(value["interface_version"], path ++ ["interface_version"]),
         do: text(value["fingerprint"], path ++ ["fingerprint"], @sha256)
  end

  defp source(value, path) do
    with :ok <- object(value, ~w(type), ~w(url path), path) do
      case value["type"] do
        "https" ->
          with :ok <- object(value, ~w(type url), [], path),
               do: text(value["url"], path ++ ["url"], @https)

        "local" ->
          with :ok <- object(value, ~w(type path), [], path),
               do: relative_path(value["path"], path ++ ["path"])

        _other ->
          failure(path ++ ["type"], :unsupported_source_type)
      end
    end
  end

  defp archive(value, path, limits) do
    with :ok <- object(value, ~w(filename format size sha256), [], path),
         :ok <-
           text(
             value["filename"],
             path ++ ["filename"],
             ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\.tar\.gz\z/
           ),
         :ok <- constant(value["format"], "tar.gz", path ++ ["format"]),
         :ok <- integer(value["size"], 1, path ++ ["size"]),
         :ok <- quota(value["size"], :max_archive_bytes, limits, path ++ ["size"]),
         do: text(value["sha256"], path ++ ["sha256"], @sha256)
  end

  defp file(value, path) do
    with :ok <- object(value, ~w(path type role size sha256 mode), [], path),
         :ok <- relative_path(value["path"], path ++ ["path"]),
         :ok <- constant(value["type"], "regular", path ++ ["type"]),
         :ok <-
           member(value["role"], ~w(nif private_library data license metadata), path ++ ["role"]),
         :ok <- integer(value["size"], 0, path ++ ["size"]),
         :ok <- text(value["sha256"], path ++ ["sha256"], @sha256),
         do: member(value["mode"], ~w(0644 0755), path ++ ["mode"])
  end

  defp license(value, path) do
    with :ok <- object(value, ~w(spdx file), [], path),
         :ok <- text(value["spdx"], path ++ ["spdx"]),
         do: relative_path(value["file"], path ++ ["file"])
  end

  defp provenance(value, path) do
    required =
      ~w(source_repository source_commit toolchains parameters nif_headers_version lockfile_sha256 sysroot_sha256 container_sha256)

    with :ok <- object(value, required, [], path),
         :ok <- text(value["source_repository"], path ++ ["source_repository"], @https),
         :ok <-
           text(
             value["source_commit"],
             path ++ ["source_commit"],
             ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
           ),
         :ok <- list(value["toolchains"], path ++ ["toolchains"], &toolchain/2, 1),
         :ok <- list(value["parameters"], path ++ ["parameters"], &parameter/2),
         :ok <- nif(value["nif_headers_version"], path ++ ["nif_headers_version"]),
         :ok <- nullable_text(value["lockfile_sha256"], path ++ ["lockfile_sha256"], @sha256),
         :ok <- nullable_text(value["sysroot_sha256"], path ++ ["sysroot_sha256"], @sha256),
         do: nullable_text(value["container_sha256"], path ++ ["container_sha256"], @sha256)
  end

  defp toolchain(value, path) do
    with :ok <- object(value, ~w(name version), [], path),
         :ok <- text(value["name"], path ++ ["name"]),
         do: text(value["version"], path ++ ["version"])
  end

  # Parameters may be empty strings; the other string fields above require data.
  defp parameter(value, _path) when is_binary(value), do: :ok
  defp parameter(_value, path), do: failure(path, :expected_string)

  defp required_features([]), do: :ok

  defp required_features([_ | _]),
    do: failure(["required_features"], :unsupported_required_features, :unsupported_schema)

  defp required_features(_other), do: failure(["required_features"], :expected_array)

  defp optional_extensions(value, path) do
    case Map.fetch(value, "extensions") do
      :error ->
        :ok

      {:ok, extensions} when is_map(extensions) ->
        if Enum.all?(
             Map.keys(extensions),
             &Regex.match?(~r/\A[a-z][a-z0-9_.-]*:[a-z][a-z0-9_.-]*\z/, &1)
           ),
           do: :ok,
           else: failure(path ++ ["extensions"], :invalid_extension_name)

      {:ok, _other} ->
        failure(path ++ ["extensions"], :expected_object)
    end
  end

  defp semantics(data, limits) do
    artifacts = data["artifacts"]
    ids = Enum.map(artifacts, & &1["id"])
    files = Enum.flat_map(artifacts, & &1["files"])

    with :ok <- unique(ids, ["artifacts"], :duplicate_artifact_id),
         :ok <- quota(length(files), :max_files, limits, ["artifacts"]),
         :ok <-
           quota(Enum.reduce(files, 0, &(trunc(&1["size"]) + &2)), :max_unpacked_bytes, limits, [
             "artifacts"
           ]) do
      artifacts
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {artifact, index}, :ok ->
        continue(artifact_semantics(artifact, ["artifacts", index]))
      end)
    end
  end

  defp artifact_semantics(artifact, path) do
    files = artifact["files"]
    paths = Enum.map(files, & &1["path"])
    nifs = for %{"role" => "nif", "path" => name} <- files, do: name
    private = for %{"role" => "private_library", "path" => name} <- files, do: name
    licenses = for %{"role" => "license", "path" => name} <- files, do: name
    license_refs = Enum.map(artifact["licenses"], & &1["file"])

    with :ok <- unique(paths, path ++ ["files"], :duplicate_file_path),
         :ok <- no_path_conflicts(paths, path ++ ["files"]),
         :ok <-
           check(
             nifs == [artifact["entrypoint"]],
             path ++ ["entrypoint"],
             :nif_entrypoint_mismatch
           ),
         :ok <-
           check(
             MapSet.new(private) == MapSet.new(artifact["private_libraries"]),
             path ++ ["private_libraries"],
             :private_library_mismatch
           ),
         do:
           check(
             MapSet.new(licenses) == MapSet.new(license_refs),
             path ++ ["licenses"],
             :license_file_mismatch
           )
  end

  defp no_path_conflicts(paths, path) do
    files = MapSet.new(paths)

    conflict? =
      Enum.any?(paths, fn name ->
        name
        |> String.split("/")
        |> Enum.drop(-1)
        |> Enum.scan(&(&2 <> "/" <> &1))
        |> Enum.any?(&MapSet.member?(files, &1))
      end)

    check(not conflict?, path, :file_directory_conflict)
  end

  defp relative_path(value, path) when is_binary(value) do
    length = for <<_codepoint::utf8 <- value>>, reduce: 0, do: (count -> count + 1)

    valid? =
      length in 1..4096 and
        not Regex.match?(~r/\A[A-Za-z]:/, value) and
        not String.contains?(value, "\\") and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, value) and
        Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", ".."]))

    check(valid?, path, :unsafe_relative_path)
  end

  defp relative_path(_other, path), do: failure(path, :expected_string)

  defp object(value, required, optional, path) when is_map(value) do
    case Enum.find(required, &(not Map.has_key?(value, &1))) do
      nil -> check(Map.keys(value) -- (required ++ optional) == [], path, :unknown_field)
      name -> failure(path ++ [name], :missing_field)
    end
  end

  defp object(_other, _required, _optional, path), do: failure(path, :expected_object)

  defp text(value, path, pattern \\ nil)

  defp text(value, path, pattern) when is_binary(value) do
    check(
      byte_size(value) > 0 and (is_nil(pattern) or Regex.match?(pattern, value)),
      path,
      :invalid_string
    )
  end

  defp text(_other, path, _pattern), do: failure(path, :expected_string)

  defp nullable_text(nil, _path, _pattern), do: :ok
  defp nullable_text(value, path, pattern), do: text(value, path, pattern)

  # JSON Schema's integer type also accepts numbers such as 1.0.
  defp integer(value, minimum, path) when is_number(value),
    do:
      check(
        value >= minimum and (is_integer(value) or trunc(value) == value),
        path,
        :invalid_integer
      )

  defp integer(_other, _minimum, path), do: failure(path, :expected_integer)

  defp constant(value, expected, path, code \\ :invalid_manifest),
    do: check(value == expected, path, :unexpected_value, code)

  defp member(value, values, path), do: check(value in values, path, :unexpected_value)

  defp list(value, path, validator, minimum \\ 0, unique? \\ false)

  defp list(value, path, validator, minimum, unique?) when is_list(value) do
    with :ok <- check(length(value) >= minimum, path, :too_few_items),
         :ok <- if(unique?, do: unique(value, path, :duplicate_item), else: :ok) do
      value
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
        continue(validator.(item, path ++ [index]))
      end)
    end
  end

  defp list(_value, path, _validator, _minimum, _unique?), do: failure(path, :expected_array)

  defp unique(values, path, reason),
    do:
      check(
        MapSet.size(MapSet.new(Enum.map(values, &canonical_number_values/1))) == length(values),
        path,
        reason
      )

  defp canonical_number_values(value) when is_float(value) and trunc(value) == value,
    do: trunc(value)

  defp canonical_number_values(value) when is_list(value),
    do: Enum.map(value, &canonical_number_values/1)

  defp canonical_number_values(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, canonical_number_values(item)} end)

  defp canonical_number_values(value), do: value

  defp quota(observed, name, limits, path) do
    if observed <= Map.fetch!(limits, name),
      do: :ok,
      else:
        {:error,
         Error.new(:invalid_manifest, %{
           path: path,
           reason: :limit_exceeded,
           limit: name,
           maximum: Map.fetch!(limits, name)
         })}
  end

  defp limits(opts), do: options(opts, %{}, 0)

  defp options([], overrides, _count), do: {:ok, Map.merge(@defaults, overrides)}

  defp options([{key, value} | rest], overrides, count) when count < map_size(@defaults) do
    cond do
      not Map.has_key?(@defaults, key) -> configuration(:unknown_limit)
      Map.has_key?(overrides, key) -> configuration(:duplicate_limit)
      not (is_integer(value) and value > 0) -> configuration(:invalid_limit)
      true -> options(rest, Map.put(overrides, key, value), count + 1)
    end
  end

  defp options(_other, _overrides, _count), do: configuration(:invalid_options)

  defp configuration(reason),
    do: {:error, Error.new(:invalid_configuration, %{field: :manifest_limits, reason: reason})}

  defp check(true, _path, _reason, _code), do: :ok
  defp check(false, path, reason, code), do: failure(path, reason, code)
  defp check(condition, path, reason), do: check(condition, path, reason, :invalid_manifest)

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}

  defp failure(path, reason, code \\ :invalid_manifest),
    do: {:error, Error.new(code, %{path: path, reason: reason})}
end
