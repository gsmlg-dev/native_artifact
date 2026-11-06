defmodule NativeArtifact.Archive.Support do
  @moduledoc false

  alias NativeArtifact.Error

  @chunk_size 65_536

  def fail(code, details), do: throw({:native_artifact_archive, Error.new(code, details)})

  def io!(:ok, _stage), do: :ok
  def io!({:ok, value}, _stage), do: value

  def io!({:error, reason}, stage) do
    fail(:unsafe_archive, %{stage: stage, reason: reason})
  end

  def deadline!(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      fail(:unsafe_archive, %{stage: :archive, reason: :deadline_exceeded})
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

  def read_exact!(file, offset, size, stage) when size > 0 do
    case :file.pread(file, offset, size) do
      {:ok, bytes} when byte_size(bytes) == size -> bytes
      {:ok, _bytes} -> fail(:unsafe_archive, %{stage: stage, reason: :truncated_tar})
      :eof -> fail(:unsafe_archive, %{stage: stage, reason: :truncated_tar})
      {:error, reason} -> fail(:unsafe_archive, %{stage: stage, reason: reason})
    end
  end

  def read_exact!(_file, _offset, 0, _stage), do: <<>>

  def hash_region(file, offset, size, deadline) do
    hash_region(file, offset, size, deadline, :crypto.hash_init(:sha256))
  end

  defp hash_region(_file, _offset, 0, _deadline, hash) do
    hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
  end

  defp hash_region(file, offset, remaining, deadline, hash) do
    deadline!(deadline)
    size = min(@chunk_size, remaining)
    bytes = read_exact!(file, offset, size, :file_hash)
    hash_region(file, offset + size, remaining - size, deadline, :crypto.hash_update(hash, bytes))
  end

  def copy_region(source, destination, offset, size, deadline) do
    copy_region(source, destination, offset, size, deadline, :crypto.hash_init(:sha256))
  end

  defp copy_region(_source, _destination, _offset, 0, _deadline, hash) do
    hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
  end

  defp copy_region(source, destination, offset, remaining, deadline, hash) do
    deadline!(deadline)
    size = min(@chunk_size, remaining)
    bytes = read_exact!(source, offset, size, :file_extract)
    io!(:file.write(destination, bytes), :file_extract)

    copy_region(
      source,
      destination,
      offset + size,
      remaining - size,
      deadline,
      :crypto.hash_update(hash, bytes)
    )
  end

  def safe_path?(path) when is_binary(path) do
    byte_size(path) in 1..4096 and String.valid?(path) and
      not String.starts_with?(path, "/") and
      not Regex.match?(~r/\A[A-Za-z]:/, path) and
      not Regex.match?(~r/[\x00-\x1f\x7f\\]/, path) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  def safe_path?(_path), do: false

  def zero?(binary), do: binary == :binary.copy(<<0>>, byte_size(binary))
end
