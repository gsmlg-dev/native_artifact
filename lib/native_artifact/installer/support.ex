defmodule NativeArtifact.Installer.Support do
  @moduledoc false

  alias NativeArtifact.Error

  @chunk_size 65_536

  def fail(code, details), do: throw({:native_artifact_installer, Error.new(code, details)})
  def unwrap({:ok, value}), do: value
  def unwrap({:error, %Error{} = error}), do: throw({:native_artifact_installer, error})
  def io!(:ok, _stage), do: :ok
  def io!({:ok, value}, _stage), do: value
  def io!({:error, reason}, stage), do: fail(:unsafe_archive, %{stage: stage, reason: reason})

  def deadline!(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      fail(:unsafe_archive, %{stage: :installation, reason: :deadline_exceeded})
    end
  end

  def absolute!(path, field) do
    if not is_binary(path) or not String.valid?(path) or Path.type(path) != :absolute or
         Path.expand(path) != path or Regex.match?(~r/[\x00-\x1f\x7f]/, path) do
      fail(:invalid_configuration, %{stage: :installation, reason: field})
    end
  end

  def physical_directory!(path) do
    absolute!(path, :priv_dir)

    path
    |> Path.split()
    |> Enum.reduce("", fn component, parent ->
      current = if parent == "", do: component, else: Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %{type: :directory}} -> current
        _other -> fail(:invalid_configuration, %{stage: :installation, reason: :unsafe_priv_dir})
      end
    end)
  end

  def ensure_directory!(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok -> io!(File.chmod(path, 0o755), :directory_mode)
          {:error, :eexist} -> ensure_directory!(path)
          {:error, reason} -> fail(:unsafe_archive, %{stage: :directory_create, reason: reason})
        end

      _other ->
        fail(:invalid_configuration, %{stage: :installation, reason: :unsafe_install_parent})
    end
  end

  def with_file(path, modes, stage, fun) do
    file = io!(:file.open(path, modes), stage)

    try do
      fun.(file)
    after
      io!(:file.close(file), :file_close)
    end
  end

  def sync_directory(path, stage) do
    with_file(path, [:raw, :read, :directory], stage, &io!(:file.sync(&1), stage))
  end

  def sync_file(path) do
    with_file(path, [:raw, :binary, :read], :file_sync, &io!(:file.sync(&1), :file_sync))
  end

  def hash_file(path, expected_size, deadline) do
    with_file(path, [:raw, :binary, :read], :installed_read, fn input ->
      hash_chunks(input, expected_size, deadline, 0, :crypto.hash_init(:sha256))
    end)
  end

  defp hash_chunks(input, expected_size, deadline, total, hash) do
    deadline!(deadline)

    case :file.read(input, min(@chunk_size, expected_size - total + 1)) do
      {:ok, bytes} ->
        total = total + byte_size(bytes)

        if total > expected_size do
          fail(:checksum_mismatch, %{stage: :installed_file, reason: :size_mismatch})
        end

        hash_chunks(input, expected_size, deadline, total, :crypto.hash_update(hash, bytes))

      :eof ->
        if total != expected_size do
          fail(:checksum_mismatch, %{stage: :installed_file, reason: :size_mismatch})
        end

        hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

      {:error, reason} ->
        fail(:unsafe_archive, %{stage: :installed_read, reason: reason})
    end
  end

  def read_bounded(path, maximum, deadline) do
    with_file(path, [:raw, :binary, :read], :receipt_read, fn input ->
      read_chunks(input, maximum, deadline, 0, [])
    end)
  end

  defp read_chunks(input, maximum, deadline, total, chunks) do
    deadline!(deadline)

    case :file.read(input, min(@chunk_size, maximum - total + 1)) do
      {:ok, bytes} ->
        total = total + byte_size(bytes)

        if total > maximum do
          fail(:checksum_mismatch, %{stage: :installed_receipt, reason: :size_limit})
        end

        read_chunks(input, maximum, deadline, total, [bytes | chunks])

      :eof ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()

      {:error, reason} ->
        fail(:unsafe_archive, %{stage: :receipt_read, reason: reason})
    end
  end

  def remove_stage!(stage) do
    case File.rm_rf(stage) do
      {:ok, _removed} ->
        :ok

      {:error, reason, _path} ->
        fail(:unsafe_archive, %{stage: :installation_cleanup, reason: reason})
    end
  end
end
