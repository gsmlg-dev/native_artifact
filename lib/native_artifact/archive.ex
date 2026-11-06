defmodule NativeArtifact.Archive do
  @moduledoc """
  Bounded verification and staging extraction of one Manifest v1 NIF bundle.

  This internal boundary takes an artifact's string-keyed metadata. The caller
  remains responsible for complete manifest validation and target resolution.
  `extract/4` creates a new absolute staging directory below existing real
  directories; it refuses symlink components and pre-existing destinations.
  It neither installs/promotes files nor accesses a network or compiler.

  Only strict USTAR regular files and necessary parent directories are accepted.
  Gzip framing uses two bounded public-OTP inflation passes, including a
  size-minus-one prefix check to reject ignored suffixes or additional members.
  The complete tar spool is verified before any payload file is extracted.
  """

  alias NativeArtifact.Archive.{Gzip, Support, Ustar}
  alias NativeArtifact.Error

  @defaults %{
    max_archive_bytes: 256 * 1024 * 1024,
    max_unpacked_bytes: 1024 * 1024 * 1024,
    max_files: 4096,
    max_headers: 8192,
    max_directories: 4096,
    max_tar_overhead_bytes: 16 * 1024 * 1024,
    timeout: 180_000
  }
  @roles ~w(nif private_library data license metadata)
  @chunk_size 65_536

  @doc """
  Verifies a local `.tar.gz` and extracts its exact files into a new staging path.

  Returns directory, sorted relative files, entrypoint and pinned archive digest.
  Positive integer options are the keys returned by `default_limits/0`.
  Defaults cap compressed bytes at 256 MiB, payload at 1 GiB, tar overhead at
  16 MiB, files at 4096, headers at 8192, directories at 4096 and work at 180 s.
  Limits apply before writes; each inflation pass checks its output/deadline.
  Failure removes only the staging tree created by this invocation.
  """
  @spec extract(binary(), map(), binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def extract(archive_path, artifact, staging_path, opts \\ []) do
    try do
      limits = limits(opts)
      {archive, files, directories, entrypoint, payload_size} = metadata(artifact, limits)
      absolute_path!(archive_path, :archive_path)
      staging!(staging_path)
      deadline = System.monotonic_time(:millisecond) + limits.timeout
      Support.io!(File.mkdir(staging_path), :staging_create)

      result =
        try do
          Support.io!(File.chmod(staging_path, 0o700), :staging_mode)
          work = work_directory(staging_path, files)
          copy = Path.join(work, "archive.tar.gz")
          spool = Path.join(work, "archive.tar")
          copy_archive(archive_path, copy, archive, deadline)

          tar_size =
            Gzip.inflate(
              copy,
              spool,
              archive["size"],
              payload_size + limits.max_tar_overhead_bytes,
              deadline
            )

          entries = Ustar.verify(spool, tar_size, files, directories, limits, deadline)
          extract_files(spool, entries, directories, staging_path, deadline)
          remove!(work)

          {:ok,
           %{
             directory: staging_path,
             files: Enum.map(entries, & &1.path),
             entrypoint: entrypoint,
             archive_sha256: archive["sha256"]
           }}
        catch
          {:native_artifact_archive, error} ->
            {:error, error}

          kind, reason ->
            stacktrace = __STACKTRACE__
            remove!(staging_path)
            :erlang.raise(kind, reason, stacktrace)
        end

      case result do
        {:ok, _receipt} ->
          result

        {:error, _error} ->
          remove!(staging_path)
          result
      end
    catch
      {:native_artifact_archive, error} -> {:error, error}
    end
  end

  @doc "Finite default resource limits for local archive verification."
  def default_limits, do: @defaults

  defp limits(opts), do: limits(opts, @defaults, MapSet.new())
  defp limits([], limits, _seen), do: limits

  defp limits([{key, value} | rest], limits, seen) do
    if not Map.has_key?(@defaults, key) or MapSet.member?(seen, key) or
         not is_integer(value) or value <= 0 do
      configuration(:invalid_limit)
    end

    limits(rest, Map.put(limits, key, value), MapSet.put(seen, key))
  end

  defp limits(_opts, _limits, _seen), do: configuration(:invalid_options)

  defp metadata(artifact, limits) when is_map(artifact) and not is_struct(artifact) do
    archive = Map.get(artifact, "archive")

    if not is_map(archive) or is_struct(archive) or archive["format"] != "tar.gz" or
         not whole_number?(archive["size"]) or archive["size"] <= 0 or
         not digest?(archive["sha256"]) do
      manifest(:archive)
    end

    archive = Map.update!(archive, "size", &trunc/1)
    if archive["size"] > limits.max_archive_bytes, do: manifest(:archive_size_limit)
    source_files = Map.get(artifact, "files")
    bounded_files!(source_files, limits.max_files, 0)

    {files, total, nifs} =
      Enum.reduce(source_files, {%{}, 0, []}, fn file, {files, total, nifs} ->
        if not is_map(file) or is_struct(file) or not Support.safe_path?(file["path"]) or
             file["type"] != "regular" or file["role"] not in @roles or
             not whole_number?(file["size"]) or file["size"] < 0 or
             file["mode"] not in ["0644", "0755"] or not digest?(file["sha256"]) do
          manifest(:file)
        end

        file = Map.update!(file, "size", &trunc/1)
        path = file["path"]
        if Map.has_key?(files, path), do: manifest(:duplicate_file)
        total = total + file["size"]
        if total > limits.max_unpacked_bytes, do: manifest(:unpacked_size_limit)
        nifs = if file["role"] == "nif", do: [path | nifs], else: nifs
        {Map.put(files, path, file), total, nifs}
      end)

    entrypoint = Map.get(artifact, "entrypoint")
    if nifs != [entrypoint], do: manifest(:entrypoint)
    directories = parent_directories(files, limits.max_directories)
    {archive, files, directories, entrypoint, total}
  end

  defp metadata(_artifact, _limits), do: manifest(:expected_artifact)

  defp whole_number?(value) when is_integer(value), do: true
  defp whole_number?(value) when is_float(value), do: trunc(value) == value
  defp whole_number?(_value), do: false

  defp bounded_files!([], _maximum, count) when count > 0, do: :ok

  defp bounded_files!([_file | rest], maximum, count) when count < maximum do
    bounded_files!(rest, maximum, count + 1)
  end

  defp bounded_files!(_files, _maximum, _count), do: manifest(:file_count_limit)

  defp parent_directories(files, maximum) do
    Enum.reduce(files, MapSet.new(), fn {path, _file}, directories ->
      path
      |> String.split("/")
      |> Enum.drop(-1)
      |> Enum.reduce({"", directories}, fn component, {parent, directories} ->
        parent = if parent == "", do: component, else: parent <> "/" <> component
        if Map.has_key?(files, parent), do: manifest(:file_directory_conflict)
        directories = MapSet.put(directories, parent)
        if MapSet.size(directories) > maximum, do: manifest(:directory_count_limit)
        {parent, directories}
      end)
      |> elem(1)
    end)
  end

  defp digest?(value) do
    is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  end

  defp absolute_path!(path, field) do
    if not is_binary(path) or not String.valid?(path) or Path.type(path) != :absolute or
         Path.expand(path) != path or Regex.match?(~r/[\x00-\x1f\x7f]/, path) do
      configuration(field)
    end
  end

  defp staging!(path) do
    absolute_path!(path, :staging_path)

    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _other -> configuration(:staging_exists)
    end

    Path.dirname(path)
    |> Path.split()
    |> Enum.reduce("", fn component, parent ->
      current = if parent == "", do: component, else: Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %{type: :directory}} -> current
        _other -> configuration(:unsafe_staging_parent)
      end
    end)
  end

  defp work_directory(staging, files) do
    name =
      ".native-artifact-archive-" <>
        Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    if Enum.any?(files, fn {path, _file} -> hd(String.split(path, "/")) == name end) do
      configuration(:temporary_name_collision)
    end

    directory = Path.join(staging, name)
    Support.io!(File.mkdir(directory), :work_create)
    Support.io!(File.chmod(directory, 0o700), :work_mode)
    directory
  end

  defp copy_archive(source, copy, archive, deadline) do
    case File.lstat(source) do
      {:ok, %{type: :regular}} ->
        :ok

      {:error, :enoent} ->
        Support.fail(:artifact_not_found, %{stage: :archive_read, reason: :enoent})

      _other ->
        Support.fail(:unsafe_archive, %{stage: :archive_read, reason: :not_regular})
    end

    Support.with_file(source, [:raw, :binary, :read], :archive_read, fn input ->
      Support.with_file(copy, [:raw, :binary, :write, :exclusive], :copy_create, fn output ->
        digest =
          copy_chunks(input, output, archive["size"], deadline, 0, :crypto.hash_init(:sha256))

        if digest != archive["sha256"],
          do: Support.fail(:checksum_mismatch, %{stage: :archive, field: :sha256})

        Support.io!(:file.sync(output), :copy_sync)
      end)
    end)
  end

  defp copy_chunks(input, output, expected, deadline, total, hash) do
    Support.deadline!(deadline)

    case :file.read(input, min(@chunk_size, expected - total + 1)) do
      {:ok, bytes} ->
        total = total + byte_size(bytes)

        if total > expected,
          do: Support.fail(:checksum_mismatch, %{stage: :archive, field: :size})

        Support.io!(:file.write(output, bytes), :copy_write)
        copy_chunks(input, output, expected, deadline, total, :crypto.hash_update(hash, bytes))

      :eof ->
        if total != expected,
          do: Support.fail(:checksum_mismatch, %{stage: :archive, field: :size})

        hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

      {:error, reason} ->
        Support.fail(:unsafe_archive, %{stage: :archive_read, reason: reason})
    end
  end

  defp extract_files(spool, entries, directories, staging, deadline) do
    directories
    |> Enum.sort_by(&{length(String.split(&1, "/")), &1})
    |> Enum.each(fn path ->
      Support.deadline!(deadline)
      directory = Path.join(staging, path)
      Support.io!(File.mkdir(directory), :directory_create)
      Support.io!(File.chmod(directory, 0o700), :directory_mode)
    end)

    Support.with_file(spool, [:raw, :binary, :read], :spool_read, fn input ->
      Enum.each(entries, fn entry ->
        Support.deadline!(deadline)
        destination = Path.join(staging, entry.path)

        Support.with_file(
          destination,
          [:raw, :binary, :write, :exclusive],
          :file_create,
          fn output ->
            digest = Support.copy_region(input, output, entry.offset, entry.size, deadline)

            if digest != entry.sha256,
              do: Support.fail(:checksum_mismatch, %{stage: :extraction, path: entry.path})

            Support.io!(:file.sync(output), :file_sync)
          end
        )

        Support.io!(File.chmod(destination, entry.mode), :file_mode)
      end)
    end)

    Enum.each(directories, fn path ->
      Support.io!(File.chmod(Path.join(staging, path), 0o755), :directory_mode)
    end)
  end

  defp remove!(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> Support.fail(:unsafe_archive, %{stage: :cleanup, reason: reason})
    end
  end

  defp configuration(reason),
    do: Support.fail(:invalid_configuration, %{stage: :archive, reason: reason})

  defp manifest(reason), do: Support.fail(:invalid_manifest, %{stage: :archive, reason: reason})
end
